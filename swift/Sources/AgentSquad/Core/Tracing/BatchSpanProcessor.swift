import Foundation

/// The production `SpanProcessor`: assembles one `TraceEvent` per span, batches finished events,
/// ships them to a `TraceExporter`.
///
/// All messages flow through one ordered channel drained by a single consumer, so a span's `onOpen`
/// → … → `onEnd` can't reorder — usage/input/metadata set just before the end always land first.
/// `flush`/`shutdown` ride the same channel as barriers: everything emitted before them exports
/// before they return (no spans lost on background/terminate). The consumer retains the processor
/// until the channel finishes, so `shutdown()` must be called to release it.
///
/// No scheduled-delay timer (a batch ships at `batchSize` or on `flush()`, never on a clock) and no
/// max-queue bound (the buffer is unbounded — events are small; silent drops would be worse).
public actor BatchSpanProcessor: SpanProcessor {
    private let exporter: any TraceExporter
    private let batchSize: Int
    private let redaction: any Redactor
    private nonisolated let continuation: AsyncStream<Event>.Continuation

    /// Spans seen but not yet ended, keyed by id.
    private var open: [String: Partial] = [:]
    /// Finalized events awaiting export.
    private var pending: [TraceEvent] = []

    public init(exporter: any TraceExporter, batchSize: Int = 64, redaction: any Redactor = Redaction.default) {
        precondition(batchSize >= 1, "batchSize must be >= 1")
        self.exporter = exporter
        self.batchSize = batchSize
        self.redaction = redaction
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation
        Task { await self.consume(stream) }
    }

    // MARK: - Span lifecycle (called synchronously from a span — ordered, non-blocking)
    //
    // After shutdown the channel is finished, so these yields return `.terminated` and the span is
    // dropped — nowhere left to export it.

    public nonisolated func onOpen(_ span: SpanData) {
        continuation.yield(.open(span))
    }

    public nonisolated func onUsage(id: String, promptTokens: Int?, completionTokens: Int?) {
        continuation.yield(.usage(id: id, promptTokens: promptTokens, completionTokens: completionTokens))
    }

    public nonisolated func onSetInput(id: String, input: JSONValue) {
        continuation.yield(.setInput(id: id, input: input))
    }

    public nonisolated func onSetMetadata(id: String, metadata: JSONValue) {
        continuation.yield(.setMetadata(id: id, metadata: metadata))
    }

    public nonisolated func onEnd(id: String, endedAt: Date, output: JSONValue?, error: String?) {
        continuation.yield(.close(id: id, endedAt: endedAt, output: output, error: error))
    }

    // MARK: - Draining (barriers — ride the same ordered channel)

    /// Export everything emitted so far, then flush the exporter. An explicit call surfaces failures
    /// (the app opted into handling them), unlike the automatic batch path.
    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if case .terminated = self.continuation.yield(.flush(continuation)) {
                continuation.resume()   // already shut down — nothing left to flush
            }
        }
    }

    /// Final drain + release the exporter, then end the channel (stops the consumer).
    public func shutdown() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if case .terminated = self.continuation.yield(.shutdown(continuation)) {
                continuation.resume()
            }
        }
    }

    // MARK: - The single ordered consumer

    // This loop is the only path to `continuation.finish()`, so it must process `.shutdown` without
    // throwing or early-exiting, else the channel never ends and a pending `shutdown()` hangs. Every
    // case is non-throwing.
    private func consume(_ stream: AsyncStream<Event>) async {
        for await event in stream {
            switch event {
            case .open(let span):
                open[span.id] = Partial(span: span)
            case .usage(let id, let promptTokens, let completionTokens):
                if let promptTokens { open[id]?.promptTokens = promptTokens }
                if let completionTokens { open[id]?.completionTokens = completionTokens }
            case .setInput(let id, let input):
                open[id]?.inputOverride = input
            case .setMetadata(let id, let metadata):
                open[id]?.metadataOverride = metadata
            case .close(let id, let endedAt, let output, let error):
                await finalize(id: id, endedAt: endedAt, output: output, error: error)
            case .flush(let reply):
                do {
                    try await export(surfaceErrors: true)
                    try await exporter.flush()
                    reply.resume()
                } catch {
                    reply.resume(throwing: error)
                }
            case .shutdown(let reply):
                try? await export(surfaceErrors: false)
                await exporter.shutdown()
                continuation.finish()
                reply.resume()
            }
        }
    }

    /// Finalize a span on end; a second end (or an unknown id) is ignored, so each span exports once.
    private func finalize(id: String, endedAt: Date, output: JSONValue?, error: String?) async {
        guard let partial = open.removeValue(forKey: id) else { return }
        let span = partial.span
        pending.append(redaction.redact(TraceEvent(
            traceId: span.traceId,
            id: span.id,
            parentId: span.parentId,
            kind: span.kind,
            name: span.name,
            status: error == nil ? .ok : .error,
            startedAt: span.startedAt,
            endedAt: endedAt,
            input: partial.inputOverride ?? span.input,
            output: output,
            error: error,
            model: span.model,
            promptTokens: partial.promptTokens,
            completionTokens: partial.completionTokens,
            userId: span.userId,
            sessionId: span.sessionId,
            metadata: partial.metadataOverride ?? span.metadata
        )))
        if pending.count >= batchSize { try? await export(surfaceErrors: false) }
    }

    private func export(surfaceErrors: Bool) async throws {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        // A tracer must never break the app: the automatic batch path swallows failures (dropped
        // batches are gone — retry/persistence belong to the exporter). An explicit flush() surfaces them.
        do { try await exporter.export(batch) }
        catch { if surfaceErrors { throw error } }
    }

    // MARK: - Messages

    private enum Event: Sendable {
        case open(SpanData)
        case usage(id: String, promptTokens: Int?, completionTokens: Int?)
        case setInput(id: String, input: JSONValue)
        case setMetadata(id: String, metadata: JSONValue)
        case close(id: String, endedAt: Date, output: JSONValue?, error: String?)
        case flush(CheckedContinuation<Void, any Error>)
        case shutdown(CheckedContinuation<Void, Never>)
    }

    /// A span between `onOpen` and `onEnd`; usage and late input/metadata fill in after creation.
    private struct Partial {
        let span: SpanData
        var promptTokens: Int?
        var completionTokens: Int?
        var inputOverride: JSONValue?
        var metadataOverride: JSONValue?
    }
}
