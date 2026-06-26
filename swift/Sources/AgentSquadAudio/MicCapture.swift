import AVFoundation
import AgentSquad

/// `AudioInput` over `AVAudioEngine`: taps the mic, converts to PCM16 @ 24 kHz mono, and yields
/// frames into a **bounded, drop-oldest** `AsyncStream` (the real-time tap thread must never block).
///
/// `@unchecked Sendable`: `start`/`stop` are not safe to call concurrently (callers must serialize;
/// `RealtimeRuntime` does). The converter lives in the tap closure and is touched only on the audio
/// thread; the stream `continuation` is itself Sendable.
public final class MicCapture: AudioInput, @unchecked Sendable {
    public let frames: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var isStarted = false

    /// `maxBufferedFrames` bounds the queue — under back-pressure the oldest frames are dropped.
    public init(sampleRate: Double = 24_000, maxBufferedFrames: Int = 16) {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        (self.frames, self.continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(maxBufferedFrames))
    }

    public func start() async throws {
        guard !isStarted else { return }   // start-once: a second installTap/engine.start would crash
        #if os(iOS)
        try VoiceAudioSession.activate()
        let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            // `AVAudioApplication.requestRecordPermission` is iOS 17+; fall back to the (now-deprecated)
            // `AVAudioSession` call on iOS 16. No deprecation warning fires at the iOS-16 floor.
            if #available(iOS 17, *) {
                AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
        }
        guard granted else { throw MicCaptureError.permissionDenied }
        #endif

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicCaptureError.converterUnavailable
        }
        // Capture the converter into the tap closure, not a shared field: the tap runs on the
        // real-time audio thread (a stored `var` would be a cross-thread read), and the closure
        // being its sole owner means it can't be freed under an in-flight `process` (no UAF on teardown).
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, with: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)   // roll back so a retry's installTap doesn't hit a live tap
            throw error
        }
        isStarted = true
    }

    public func stop() async {
        // Halt the render thread BEFORE removing the tap so no tap block starts mid-teardown. The
        // converter is owned by the tap closure, not a shared field, so removing the tap can't race
        // a `process` call — an in-flight one holds the converter on its stack.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        continuation.finish()
        isStarted = false
    }

    /// Runs on the real-time audio thread: convert one captured buffer to PCM16/24k and yield it.
    private func process(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The block form is REQUIRED for sample-rate conversion (48k→24k) — `convert(to:from:)`
        // throws on differing sample rates. Feeding one input buffer per call with the converter
        // reused across taps is the correct *streaming* idiom: it carries resampler filter state
        // between calls for continuity. The input block is `@Sendable` but called synchronously on
        // this thread, so single-threaded access to these captures is safe.
        nonisolated(unsafe) let source = buffer
        nonisolated(unsafe) var provided = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return source
        }
        guard conversionError == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return }
        continuation.yield(Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }
}

public enum MicCaptureError: Error, Equatable {
    case permissionDenied
    case converterUnavailable
}
