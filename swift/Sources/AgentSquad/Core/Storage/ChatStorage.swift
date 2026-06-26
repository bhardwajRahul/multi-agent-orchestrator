import Foundation

/// Persists conversation history. Bundled store: `DeviceChatStorage`.
///
/// Two scopes: per-agent (`fetch`/`save`/`saveMessages`, keyed by `agentId`) feeds the selected
/// agent; merged (`fetchAllChats`, across agents, assistant messages `[agentId]`-prefixed) feeds
/// the Classifier. `maxMessages` counts messages, not pairs (default `ChatStorageDefaults.maxMessages`).
/// A persistent store must pin a stable `JSONEncoder.dateEncodingStrategy` (see `ConversationMessage.timestamp`).
public protocol ChatStorage: Sendable {
    func fetch(
        userId: String,
        sessionId: String,
        agentId: String,
        maxMessages: Int?
    ) async throws -> [ConversationMessage]

    func save(
        _ message: ConversationMessage,
        userId: String,
        sessionId: String,
        agentId: String,
        maxMessages: Int?
    ) async throws

    func saveMessages(
        _ messages: [ConversationMessage],
        userId: String,
        sessionId: String,
        agentId: String,
        maxMessages: Int?
    ) async throws

    /// Merged, timestamp-ordered history across all agents; assistant messages `[agentId]`-prefixed.
    /// Untrimmed — the Classifier wants the full cross-agent picture and windows it itself.
    func fetchAllChats(userId: String, sessionId: String) async throws -> [ConversationMessage]
}

/// Framework-wide storage defaults, named so concrete stores don't invent their own literals.
public enum ChatStorageDefaults {
    /// Default message budget per agent (≈ 50 user/assistant pairs). Counts messages, not pairs.
    public static let maxMessages = 100
}

extension ChatStorage {
    /// Keep the most recent messages, rounding `maxMessages` down to even so a pair is never split.
    /// `nil` keeps everything; a non-positive (or odd `1`, rounding to `0`) budget yields `[]`.
    public func trimToEvenPairs(
        _ messages: [ConversationMessage],
        maxMessages: Int?
    ) -> [ConversationMessage] {
        guard let maxMessages else { return messages }
        let adjusted = maxMessages.isMultiple(of: 2) ? maxMessages : maxMessages - 1
        guard adjusted > 0 else { return [] }
        return Array(messages.suffix(adjusted))
    }

    /// True when `newMessage` repeats the last stored message's role; stores drop such a save.
    public func isConsecutiveSameRole(
        _ conversation: [ConversationMessage],
        _ newMessage: ConversationMessage
    ) -> Bool {
        conversation.last?.role == newMessage.role
    }
}

extension ConversationMessage {
    /// Prefix an assistant message's first text part with `[agentId]` for the merged classifier view.
    func attributed(agentId: String) -> ConversationMessage {
        guard role == .assistant else { return self }
        let tag = "[\(agentId)]"
        var parts = parts
        let textIndex = parts.firstIndex { part in
            if case .text = part { return true } else { return false }
        }
        if let textIndex, case .text(let text) = parts[textIndex] {
            parts[textIndex] = .text("\(tag) \(text)")
        } else {
            parts.insert(.text(tag), at: 0)
        }
        return ConversationMessage(id: id, role: role, parts: parts, timestamp: timestamp)
    }
}
