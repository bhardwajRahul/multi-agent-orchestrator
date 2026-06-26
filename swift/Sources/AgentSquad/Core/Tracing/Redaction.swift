import Foundation
import CryptoKit

/// A policy for what may leave the device in traces — payloads may contain user data. A `Redactor`
/// transforms each `TraceEvent` before export; conform your own for full control. Applied by
/// `BatchSpanProcessor` before it hands a batch to the exporter.
public protocol Redactor: Sendable {
    func redact(_ event: TraceEvent) -> TraceEvent
}

/// The built-in default `Redactor`: hashes user ids and clips over-long strings.
public struct Redaction: Redactor, Sendable, Equatable {
    /// Hash user ids instead of sending them raw.
    public var hashUserIds: Bool
    /// Clip strings longer than this many characters; `nil` disables clipping.
    public var maxStringLength: Int?

    public init(
        hashUserIds: Bool = true,
        maxStringLength: Int? = 4096
    ) {
        self.hashUserIds = hashUserIds
        self.maxStringLength = maxStringLength
    }

    public static let `default` = Redaction()
}

extension Redaction {
    /// Hash the user id (if enabled) and clip over-long strings in `input` / `output` / `error` /
    /// `metadata`. The id wiring, model, and token counts pass through untouched.
    public func redact(_ event: TraceEvent) -> TraceEvent {
        TraceEvent(
            traceId: event.traceId,
            id: event.id,
            parentId: event.parentId,
            kind: event.kind,
            name: event.name,
            status: event.status,
            startedAt: event.startedAt,
            endedAt: event.endedAt,
            input: event.input.map(clip),
            output: event.output.map(clip),
            error: event.error.map(clip),
            model: event.model,
            promptTokens: event.promptTokens,
            completionTokens: event.completionTokens,
            userId: event.userId.map { hashUserIds ? Self.hash($0) : $0 },
            sessionId: event.sessionId,
            metadata: event.metadata.map(clip)
        )
    }

    private func clip(_ string: String) -> String {
        guard let max = maxStringLength, string.count > max else { return string }
        return String(string.prefix(max)) + "…"
    }

    private func clip(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(clip(s))
        case .array(let a): return .array(a.map(clip))
        case .object(let o): return .object(o.mapValues(clip))
        case .null, .bool, .int, .double: return value
        }
    }

    /// Non-reversible, stable id (SHA-256, 16 hex chars) — enough to correlate a user's traces
    /// without shipping the raw id.
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
