---
title: Custom storage
description: Implement ChatStorage to persist conversation history to any backend.
---

Conform to `ChatStorage` when the built-in stores don't fit — a remote database, an encrypted keychain bucket, a shared app-group container, etc. The protocol is `Sendable`; the idiomatic Swift implementation is an `actor`.

See the [Storage overview](/agent-squad/swift/storage/overview/) for the full protocol signature and the `maxMessages` / `store: nil` semantics before writing your own store.

## Example: `UserDefaultsChatStorage`

The example below persists each scope as a JSON blob in `UserDefaults`. It is intentionally minimal to show all four required methods without noise.

```swift
import Foundation
import AgentSquad

/// A UserDefaults-backed ChatStorage. Each (userId, sessionId, agentId) scope is
/// stored as a JSON-encoded array under a compound key.
/// Not recommended for large histories — swap the read/write body for your real backend.
public actor UserDefaultsChatStorage: ChatStorage {

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(suiteName: String? = nil) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.encoder = JSONEncoder()
        // Pin the date strategy — required for stable round-trips across versions.
        self.encoder.dateEncodingStrategy = .millisecondsSince1970
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    // MARK: - ChatStorage

    public func fetch(
        userId: String,
        sessionId: String,
        agentId: String,
        maxMessages: Int?
    ) async throws -> [ConversationMessage] {
        let all = try load(userId: userId, sessionId: sessionId, agentId: agentId)
        return trimToEvenPairs(all, maxMessages: maxMessages)
    }

    public func save(
        _ message: ConversationMessage,
        userId: String,
        sessionId: String,
        agentId: String,
        maxMessages: Int?
    ) async throws {
        try await saveMessages(
            [message],
            userId: userId, sessionId: sessionId, agentId: agentId,
            maxMessages: maxMessages
        )
    }

    public func saveMessages(
        _ messages: [ConversationMessage],
        userId: String,
        sessionId: String,
        agentId: String,
        maxMessages: Int?
    ) async throws {
        var stored = try load(userId: userId, sessionId: sessionId, agentId: agentId)
        for message in messages where !isConsecutiveSameRole(stored, message) {
            stored.append(message)
        }
        // Trim before persisting so the store never grows unbounded.
        stored = trimToEvenPairs(stored, maxMessages: maxMessages)
        try persist(stored, userId: userId, sessionId: sessionId, agentId: agentId)
    }

    /// Returns a merged, timestamp-ordered view across all scopes for the session,
    /// with assistant messages prefixed `[agentId]` for Classifier attribution.
    public func fetchAllChats(
        userId: String,
        sessionId: String
    ) async throws -> [ConversationMessage] {
        // Enumerate every stored key that belongs to this (userId, sessionId).
        let prefix = scopeKey(userId: userId, sessionId: sessionId, agentId: "")
        let agentIds: [String] = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }

        var all: [ConversationMessage] = []
        for agentId in agentIds {
            let messages = try load(userId: userId, sessionId: sessionId, agentId: agentId)
            all += messages.map { $0.attributed(agentId: agentId) }
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Private helpers

    private func scopeKey(userId: String, sessionId: String, agentId: String) -> String {
        "AgentSquad.\(userId).\(sessionId).\(agentId)"
    }

    private func load(userId: String, sessionId: String, agentId: String) throws -> [ConversationMessage] {
        let key = scopeKey(userId: userId, sessionId: sessionId, agentId: agentId)
        guard let data = defaults.data(forKey: key) else { return [] }
        return try decoder.decode([ConversationMessage].self, from: data)
    }

    private func persist(_ messages: [ConversationMessage], userId: String, sessionId: String, agentId: String) throws {
        let key = scopeKey(userId: userId, sessionId: sessionId, agentId: agentId)
        let data = try encoder.encode(messages)
        defaults.set(data, forKey: key)
    }
}
```

**Wire it up exactly like the built-in stores:**

```swift
let store = UserDefaultsChatStorage(suiteName: "group.com.example.app")
let orchestrator = Orchestrator(agents: [agent], store: store)
```

---

## Things to keep in mind

**Date encoding strategy.** Pin `encoder.dateEncodingStrategy` (the example uses `.millisecondsSince1970`) and never change it after shipping. `fetchAllChats` sorts by `timestamp`; a strategy mismatch silently scrambles the order.

**`trimToEvenPairs` / `isConsecutiveSameRole`.** Both are provided as default implementations on `ChatStorage`. Call them as shown; do not reimplement them.

**`fetchAllChats` attribution.** Call `.attributed(agentId:)` on each assistant message before returning the merged list. The Classifier relies on the `[agentId]` prefix to attribute turns correctly in multi-agent sessions.

**`actor` isolation.** The protocol requires `Sendable`. An `actor` is the cleanest way to satisfy this while keeping mutable state safe. If you use a `class` instead, protect all mutable state with a lock or a serialised queue and declare conformance to `@unchecked Sendable`.

---

See also: [Storage overview](/agent-squad/swift/storage/overview/) · [InMemoryChatStorage](/agent-squad/swift/storage/built-in/in-memory/) · [FileChatStorage](/agent-squad/swift/storage/built-in/file/) · [DeviceChatStorage](/agent-squad/swift/storage/built-in/device/)
