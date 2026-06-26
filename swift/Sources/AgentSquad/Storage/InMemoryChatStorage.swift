import Foundation

/// A non-persistent, in-memory `ChatStorage` for **one** conversation — construct it empty for a
/// fresh chat, or seeded with a prior conversation to load one into a session. Drop it into an
/// `Orchestrator` or a voice assistant's `store:` exactly like the persistent stores:
///
/// ```swift
/// let store = InMemoryChatStorage(priorConversation)   // or InMemoryChatStorage() for a new chat
/// let orchestrator = Orchestrator(agents: [agent], store: store)
/// ```
///
/// Scope-agnostic: ignores `userId` / `sessionId` / `agentId`, so every read/write targets the same
/// history — which is what lets you seed a conversation without knowing the consumer's `agentId`.
/// Trade-off: one instance models one conversation. For multi-session or multi-agent histories (and
/// `fetchAllChats`' `[agentId]` attribution) use a persistent store.
public actor InMemoryChatStorage: ChatStorage {
    private var messages: [ConversationMessage]

    /// - Parameter messages: the starting conversation; empty (default) for a fresh chat. Preserved
    ///   in full — `fetch` trims only the returned view, so a loaded conversation is never clipped.
    public init(_ messages: [ConversationMessage] = []) {
        self.messages = messages
    }

    // MARK: - ChatStorage

    public func fetch(
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws -> [ConversationMessage] {
        trimToEvenPairs(messages, maxMessages: maxMessages)
    }

    public func save(
        _ message: ConversationMessage,
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws {
        try await saveMessages([message], userId: userId, sessionId: sessionId, agentId: agentId, maxMessages: maxMessages)
    }

    public func saveMessages(
        _ messages: [ConversationMessage],
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws {
        // Append-only: drop a consecutive same-role message; never trim (the budget applies to `fetch`).
        for message in messages where !isConsecutiveSameRole(self.messages, message) {
            self.messages.append(message)
        }
    }

    /// The whole conversation, in order. Returned unattributed (no `[agentId]` prefix) — fine for a
    /// single agent; in a multi-agent `Orchestrator` the Classifier loses its routing signal, so use
    /// a persistent store there.
    public func fetchAllChats(userId: String, sessionId: String) async throws -> [ConversationMessage] {
        messages
    }
}
