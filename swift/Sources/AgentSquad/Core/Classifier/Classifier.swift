import Foundation

/// The outcome of routing: which agent should handle the turn, and how confident the classifier is.
public struct ClassifierResult: Sendable {
    /// The chosen agent, or `nil` if none matched. When non-nil it is always one of the `agents`
    /// passed to `classify`, so the Orchestrator can dispatch it directly.
    public let selectedAgent: (any AgentProtocol)?
    /// Nominally 0...1, captured for observability only — the orchestrator never thresholds it (the
    /// default-agent fallback fires only on `selectedAgent == nil`); gate it yourself if you want.
    public let confidence: Double

    public init(selectedAgent: (any AgentProtocol)?, confidence: Double) {
        self.selectedAgent = selectedAgent
        self.confidence = confidence
    }
}

/// Picks the agent best suited to a turn. Optional — a single-agent run injects `nil`; `LLMClassifier`
/// is the default.
public protocol Classifier: Sendable {
    /// Resolves the answer against `agents` by `id`, returning `selectedAgent == nil` when nothing
    /// matches — never an agent outside `agents`.
    /// - Parameters:
    ///   - input: the user's message.
    ///   - history: the merged, `[agentId]`-prefixed conversation (from `ChatStorage.fetchAllChats`).
    ///   - agents: the agents to choose among.
    func classify(
        _ input: String,
        history: [ConversationMessage],
        agents: [any AgentProtocol]
    ) async throws -> ClassifierResult
}
