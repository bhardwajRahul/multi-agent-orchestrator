import Foundation
import Testing

@testable import AgentSquad

@Suite struct FileChatStorageTests {
    private func tempDir() -> URL { tempDirectory(prefix: "filechatstorage-tests") }

    @Test func savesAndFetchesAConversation() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        try await store.save(.init(role: .user, text: "hi"), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        try await store.save(.init(role: .assistant, text: "yo"), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)

        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        #expect(fetched.map(\.parts) == [[.text("hi")], [.text("yo")]])
    }

    // A fresh store over the same on-disk location = a new process: history must still be there.
    @Test func survivesAcrossStoreInstances() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = FileChatStorage(baseURL: dir)
        try await first.save(.init(role: .user, text: "persist me"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)

        let second = FileChatStorage(baseURL: dir)
        let fetched = try await second.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.map(\.parts) == [[.text("persist me")]])
    }

    @Test func dropsConsecutiveSameRole() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        try await store.save(.init(role: .user, text: "one"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        try await store.save(.init(role: .user, text: "two"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)  // dropped
        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.count == 1)
    }

    @Test func enforcesEvenCap() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        // Alternate roles so nothing is dropped as same-role; cap of 3 rounds down to 2.
        for index in 0..<5 {
            let role: Role = index.isMultiple(of: 2) ? .user : .assistant
            try await store.save(.init(role: role, text: "\(index)"), userId: "u", sessionId: "s", agentId: "a", maxMessages: 3)
        }
        let fetched = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 100)
        #expect(fetched.map(\.parts) == [[.text("3")], [.text("4")]])   // last even-count, most recent
    }

    @Test func scopesByAgent() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        try await store.save(.init(role: .user, text: "sports msg"), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        try await store.save(.init(role: .user, text: "casino msg"), userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100)

        let sports = try await store.fetch(userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        #expect(sports.map(\.parts) == [[.text("sports msg")]])
    }

    // The per-match isolation the app relies on (sessionId = matchId): sessions never overlap.
    @Test func scopesBySession() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        try await store.save(.init(role: .user, text: "match A"), userId: "u", sessionId: "matchA", agentId: "companion", maxMessages: 100)
        try await store.save(.init(role: .user, text: "match B"), userId: "u", sessionId: "matchB", agentId: "companion", maxMessages: 100)

        let a = try await store.fetch(userId: "u", sessionId: "matchA", agentId: "companion", maxMessages: 100)
        let b = try await store.fetch(userId: "u", sessionId: "matchB", agentId: "companion", maxMessages: 100)
        #expect(a.map(\.parts) == [[.text("match A")]])
        #expect(b.map(\.parts) == [[.text("match B")]])
    }

    @Test func fetchMissingReturnsEmpty() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        let fetched = try await store.fetch(userId: "u", sessionId: "none", agentId: "x", maxMessages: 100)
        #expect(fetched.isEmpty)
    }

    // Ids with filesystem-unsafe characters (e.g. "/") are percent-encoded, so they round-trip.
    @Test func handlesUnsafeScopeIds() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        try await store.save(.init(role: .user, text: "ok"), userId: "a/b", sessionId: "x/y", agentId: "c d", maxMessages: 100)
        let fetched = try await store.fetch(userId: "a/b", sessionId: "x/y", agentId: "c d", maxMessages: 100)
        #expect(fetched.map(\.parts) == [[.text("ok")]])
    }

    @Test func fetchAllChatsMergesSortsAndPrefixesAssistants() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        try await store.save(
            .init(role: .assistant, text: "from sports", timestamp: Date(timeIntervalSinceReferenceDate: 1)),
            userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100
        )
        try await store.save(
            .init(role: .assistant, text: "from casino", timestamp: Date(timeIntervalSinceReferenceDate: 2)),
            userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100
        )

        let merged = try await store.fetchAllChats(userId: "u", sessionId: "s")
        #expect(merged.map(\.parts) == [
            [.text("[sports] from sports")],   // earlier timestamp first
            [.text("[casino] from casino")]
        ])
    }

    // Sub-second timestamps must survive the round-trip so the merge stays chronological even when
    // the later message lives in the alphabetically-earlier agent file. (Guards against a
    // whole-second date strategy, which would collapse these to a tie and misorder them.)
    @Test func mergedViewOrdersSubSecondAcrossAgents() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        // "casino" sorts before "sports" by filename, but its message is LATER in time.
        try await store.save(
            .init(role: .assistant, text: "later", timestamp: Date(timeIntervalSinceReferenceDate: 1.8)),
            userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100
        )
        try await store.save(
            .init(role: .assistant, text: "earlier", timestamp: Date(timeIntervalSinceReferenceDate: 1.2)),
            userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100
        )

        let merged = try await store.fetchAllChats(userId: "u", sessionId: "s")
        #expect(merged.map(\.parts) == [
            [.text("[sports] earlier")],   // 1.2 before 1.8 — chronological, not filename order
            [.text("[casino] later")]
        ])
    }

    // Exact-equal timestamps across agents resolve deterministically by agent-filename order.
    @Test func mergedViewBreaksTimestampTiesByAgentName() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileChatStorage(baseURL: dir)

        let sameInstant = Date(timeIntervalSinceReferenceDate: 5)
        try await store.save(.init(role: .assistant, text: "s-msg", timestamp: sameInstant), userId: "u", sessionId: "s", agentId: "sports", maxMessages: 100)
        try await store.save(.init(role: .assistant, text: "c-msg", timestamp: sameInstant), userId: "u", sessionId: "s", agentId: "casino", maxMessages: 100)

        let merged = try await store.fetchAllChats(userId: "u", sessionId: "s")
        #expect(merged.map(\.parts) == [
            [.text("[casino] c-msg")],   // "casino" < "sports" by filename
            [.text("[sports] s-msg")]
        ])
    }
}
