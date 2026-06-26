import Foundation
import Testing

@testable import AgentSquad

@Suite struct DeviceChatStorageTests {
    @Test func savesAndFetchesAConversation() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        try await store.save(.init(role: .user, text: "hi"), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        try await store.save(.init(role: .assistant, text: "yo"), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)

        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        #expect(fetched.count == 2)
        #expect(fetched.first?.parts == [.text("hi")])
        #expect(fetched.last?.parts == [.text("yo")])
    }

    // A fresh store over the same on-disk location = a new process: history must still be there.
    @Test func survivesAcrossStoreInstances() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let first = try DeviceChatStorage(userId: "u", baseURL: dir)
            try await first.save(.init(role: .user, text: "persist me"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        }
        let second = try DeviceChatStorage(userId: "u", baseURL: dir)
        let fetched = try await second.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.map(\.parts) == [[.text("persist me")]])
    }

    @Test func dropsConsecutiveSameRole() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        try await store.save(.init(role: .user, text: "one"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        try await store.save(.init(role: .user, text: "two"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)  // dropped
        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.count == 1)
    }

    @Test func enforcesEvenCap() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        // alternate roles so nothing is dropped as same-role; cap of 3 rounds down to 2.
        for index in 0..<5 {
            let role: Role = index.isMultiple(of: 2) ? .user : .assistant
            try await store.save(.init(role: role, text: "\(index)"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 3)
        }
        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.map(\.parts) == [[.text("3")], [.text("4")]])   // last even-count, most recent
    }

    @Test func scopesByAgent() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        try await store.save(.init(role: .user, text: "sports msg"), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        try await store.save(.init(role: .user, text: "casino msg"), userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100)

        let sports = try await store.fetch(userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        #expect(sports.map(\.parts) == [[.text("sports msg")]])
    }

    @Test func fetchMissingReturnsEmpty() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        let fetched = try await store.fetch(userId: "u", sessionId: "none", agentId: "x", maxMessages: 100)
        #expect(fetched.isEmpty)
    }

    @Test func fetchAllChatsMergesSortsAndPrefixesAssistants() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        try await store.save(
            .init(role: .assistant, text: "from sports", timestamp: Date(timeIntervalSinceReferenceDate: 1)),
            userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100
        )
        try await store.save(
            .init(role: .assistant, text: "from casino", timestamp: Date(timeIntervalSinceReferenceDate: 2)),
            userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100
        )

        let merged = try await store.fetchAllChats(userId: "u", sessionId: "s")
        #expect(merged.count == 2)
        #expect(merged.first?.parts == [.text("[sports] from sports")])   // earlier timestamp first
        #expect(merged.last?.parts == [.text("[casino] from casino")])
    }

    // Equal timestamps across agents resolve deterministically by insertion order (seq).
    @Test func mergedViewBreaksTimestampTiesByInsertionOrder() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        let sameInstant = Date(timeIntervalSinceReferenceDate: 5)
        try await store.save(.init(role: .assistant, text: "first", timestamp: sameInstant), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        try await store.save(.init(role: .assistant, text: "second", timestamp: sameInstant), userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100)

        let merged = try await store.fetchAllChats(userId: "u", sessionId: "s")
        #expect(merged.first?.parts == [.text("[sports] first")])   // saved first → lower seq → first
        #expect(merged.last?.parts == [.text("[casino] second")])
    }

    @Test func clearRemovesHistory() async throws {
        let store = try DeviceChatStorage(userId: "u", inMemory: true)
        try await store.save(.init(role: .user, text: "hi"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        try await store.clear()
        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.isEmpty)
    }
}
