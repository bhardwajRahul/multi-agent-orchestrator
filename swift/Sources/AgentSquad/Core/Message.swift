import Foundation

public enum Role: String, Sendable, Codable, Hashable {
    case user
    case assistant
    case system
    case tool
}

/// One piece of a message; a message mixes prose, tool calls/results, a widget, and an audio transcript.
///
/// Persisted JSON keys are the case + associated-value label names, so renaming a case or labeled param breaks stored history (reordering is safe).
public enum ContentPart: Sendable, Codable, Hashable {
    case text(String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, content: JSONValue)
    case audioTranscript(String)
    case widget(UIPayload)
}

/// A single message in a conversation. Immutable; streamed deltas are accumulated elsewhere.
public struct ConversationMessage: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let role: Role
    public let parts: [ContentPart]
    /// Encoded per the store's `dateEncodingStrategy`; `ChatStorage` pins a stable one.
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: Role,
        parts: [ContentPart],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.parts = parts
        self.timestamp = timestamp
    }

    public init(
        id: String = UUID().uuidString,
        role: Role,
        text: String,
        timestamp: Date = Date()
    ) {
        self.init(id: id, role: role, parts: [.text(text)], timestamp: timestamp)
    }

    /// The text parts joined; empty if there are none.
    public var text: String {
        parts.compactMap { if case .text(let value) = $0 { return value } else { return nil } }.joined()
    }
}
