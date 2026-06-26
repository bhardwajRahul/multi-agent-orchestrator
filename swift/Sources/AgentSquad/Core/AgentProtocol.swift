import Foundation

/// Whether an advertised tool UI is shown, decided per agent at construction.
public enum UIPolicy: Sendable {
    /// Forward an advertised tool UI to the caller as `AgentEvent.widget`.
    case forward
    /// Fold the tool's data into the text answer instead.
    case suppress
}

/// What the user sent this turn. Turn-based only; continuous audio is the `VoiceAssistant`'s concern.
public enum AgentInput: Sendable {
    case text(String)

    public var text: String {
        if case .text(let value) = self { return value }
        return ""
    }
}

/// One streamed event from an agent turn.
///
/// `.error` is a user-facing chat message (e.g. "network unavailable"); real failures are thrown through the stream instead. Audio cases live on `RealtimeEvent`.
public enum AgentEvent: Sendable {
    case thinking(String)
    case textDelta(String)
    /// Tool call announced for observability; the result is recorded on the trace span, not re-emitted.
    case toolCall(id: String, name: String, arguments: JSONValue)
    case widget(UIPayload)                                          // never sent to the model
    case final(ConversationMessage)
    case error(String)
}

/// Per-turn context: identity, free-form params, and the live trace span to hang child spans on.
public struct AgentContext: Sendable {
    public let userId: String
    public let sessionId: String
    public let params: [String: JSONValue]
    public let span: (any SpanHandle)?

    public init(
        userId: String,
        sessionId: String,
        params: [String: JSONValue] = [:],
        span: (any SpanHandle)? = nil
    ) {
        self.userId = userId
        self.sessionId = sessionId
        self.params = params
        self.span = span
    }
}

/// The turn-based "brain" contract; the Realtime voice session does not conform. An agent owns its tool-use loop.
public protocol AgentProtocol: Sendable {
    /// Storage namespace + classifier routing key. Defaults to `slugify(name)`.
    var id: String { get }
    var name: String { get }
    var description: String { get }
    /// Whether the orchestrator persists this agent's turns. Defaults to `true`.
    var saveChat: Bool { get }
    /// Tool-loop cap; 1 when the agent has no tools.
    var maxToolRounds: Int { get }

    func process(
        _ input: AgentInput,
        history: [ConversationMessage],
        context: AgentContext
    ) -> AsyncThrowingStream<AgentEvent, any Error>
}

extension AgentProtocol {
    public var id: String { slugify(name) }
    public var saveChat: Bool { true }
    // Single round by default; a tool-bearing agent must override or its loop never runs.
    public var maxToolRounds: Int { 1 }
}
