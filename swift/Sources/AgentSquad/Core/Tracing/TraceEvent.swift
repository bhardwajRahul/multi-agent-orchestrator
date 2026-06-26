import Foundation

/// A flattened record of one span's lifecycle, handed to a `TraceExporter` in batches. Maps onto
/// Langfuse observations / Langsmith runs without exporter-specific coupling.
public struct TraceEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case trace        // the root span
        case span         // a step / tool call
        case generation   // an LLM call (carries model + token usage)
    }

    /// Open / finished / failed — `endedAt` alone can't tell "in progress" from "failed".
    public enum Status: String, Sendable, Codable {
        case running
        case ok
        case error
    }

    public let traceId: String
    public let id: String
    public let parentId: String?
    public let kind: Kind
    public let name: String
    public let status: Status
    public let startedAt: Date
    public let endedAt: Date?
    public let input: JSONValue?
    public let output: JSONValue?
    public let error: String?
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let userId: String?
    public let sessionId: String?
    public let metadata: JSONValue?

    // Wire keys pinned (snake_case) so a property rename can't change the serialized form.
    enum CodingKeys: String, CodingKey {
        case traceId = "trace_id"
        case id
        case parentId = "parent_id"
        case kind
        case name
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case input
        case output
        case error
        case model
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case userId = "user_id"
        case sessionId = "session_id"
        case metadata
    }

    public init(
        traceId: String,
        id: String,
        parentId: String? = nil,
        kind: Kind,
        name: String,
        status: Status = .ok,
        startedAt: Date,
        endedAt: Date? = nil,
        input: JSONValue? = nil,
        output: JSONValue? = nil,
        error: String? = nil,
        model: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        userId: String? = nil,
        sessionId: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.traceId = traceId
        self.id = id
        self.parentId = parentId
        self.kind = kind
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.input = input
        self.output = output
        self.error = error
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.userId = userId
        self.sessionId = sessionId
        self.metadata = metadata
    }
}
