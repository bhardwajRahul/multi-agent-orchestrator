#if os(iOS)
import AVFoundation

/// Shared `AVAudioSession` setup for the voice profile — one place so `MicCapture` and
/// `AudioPlayback` can't drift to conflicting categories. Idempotent (re-activating an
/// already-active session is a no-op).
enum VoiceAudioSession {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }
}
#endif
