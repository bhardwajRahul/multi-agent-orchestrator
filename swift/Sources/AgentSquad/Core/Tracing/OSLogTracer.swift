import Foundation
import os

/// The default dev `Tracer`: logs span lifecycle via `os.Logger`, no batching or export (the
/// production path is `ProcessingTracer` + `BatchSpanProcessor` + a network exporter).
///
/// Input/output payloads are not logged (they may contain user data) — only names, ids, model, and
/// usage — so it's safe-by-default without `Redaction`.
public struct OSLogTracer: Tracer {
    private let logger: Logger

    public init(subsystem: String = "AgentSquad", category: String = "trace") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func startTrace(
        name: String, userId: String?, sessionId: String?, metadata: JSONValue?
    ) -> any SpanHandle {
        let id = UUID().uuidString
        logger.debug("▶︎ trace \"\(name, privacy: .public)\" [\(id, privacy: .public)] user=\(userId ?? "-", privacy: .public) session=\(sessionId ?? "-", privacy: .public)")
        return OSLogSpan(id: id, name: name, logger: logger)
    }
}

/// One node in an `OSLogTracer` tree — span, generation, and trace root. Stateless beyond its id and
/// start instant, so it's a `Sendable` value.
struct OSLogSpan: GenerationHandle {
    let id: String
    let name: String
    let logger: Logger
    let start = ContinuousClock().now   // for duration on end()

    func span(_ name: String, input: JSONValue?) -> any SpanHandle {
        let childId = UUID().uuidString
        logger.debug("  ↳ span \"\(name, privacy: .public)\" [\(childId, privacy: .public)] parent=[\(id, privacy: .public)]")
        return OSLogSpan(id: childId, name: name, logger: logger)
    }

    func generation(_ name: String, model: String, input: JSONValue?) -> any GenerationHandle {
        let childId = UUID().uuidString
        logger.debug("  ↳ gen \"\(name, privacy: .public)\" model=\(model, privacy: .public) [\(childId, privacy: .public)] parent=[\(id, privacy: .public)]")
        return OSLogSpan(id: childId, name: name, logger: logger)
    }

    func end(output: JSONValue?, error: (any Error)?) {
        let elapsed = start.duration(to: ContinuousClock().now)
        if let error {
            // String(reflecting:) surfaces the concrete error type/payload, not localizedDescription.
            logger.error("  ✗ end \"\(name, privacy: .public)\" [\(id, privacy: .public)] \(elapsed, privacy: .public) error=\(String(reflecting: error), privacy: .public)")
        } else {
            logger.debug("  ✓ end \"\(name, privacy: .public)\" [\(id, privacy: .public)] \(elapsed, privacy: .public)")
        }
    }

    func usage(promptTokens: Int?, completionTokens: Int?) {
        logger.debug("  · usage [\(id, privacy: .public)] prompt=\(promptTokens ?? 0) completion=\(completionTokens ?? 0)")
    }
}
