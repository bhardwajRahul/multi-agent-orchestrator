import Foundation

/// One tool-aware streaming completion turn. The seam `Agent`, `GroundedAgent`, and `LLMClassifier` build on.
public protocol LLMClient: Sendable {
    /// Streams text deltas and tool-call requests, then `.done`. On `.done` the caller runs any requested tools and re-invokes (the tool loop), else stops.
    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}

/// One turn's input: optional system prompt, conversation so far (incl. prior tool calls/results), and callable tools.
public struct LLMRequest: Sendable {
    public let system: String?
    public let messages: [ConversationMessage]
    public let tools: [AgentTool]

    public init(system: String? = nil, messages: [ConversationMessage], tools: [AgentTool] = []) {
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

public enum LLMStreamEvent: Sendable {
    case textDelta(String)
    /// One complete tool call; several may precede `.done` (parallel calls).
    case toolCall(id: String, name: String, arguments: JSONValue)
    /// Terminal event: why the model stopped, plus token usage if known.
    case done(reason: FinishReason, usage: LLMUsage?)
}

/// Why a turn ended. Maps onto OpenAI `finish_reason` / Anthropic `stop_reason`.
public enum FinishReason: Sendable, Equatable {
    case stop           // finished its answer
    case toolCalls      // stopped to call tools
    case length         // truncated by the token cap
    case contentFilter  // refused / filtered
    case other(String)
}

public struct LLMUsage: Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}
