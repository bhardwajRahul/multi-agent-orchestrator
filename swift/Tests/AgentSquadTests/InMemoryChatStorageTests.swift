import Foundation
import Testing

@testable import AgentSquad

@Suite struct InMemoryChatStorageTests {
    private func user(_ t: String) -> ConversationMessage { ConversationMessage(role: .user, text: t) }
    private func assistant(_ t: String) -> ConversationMessage { ConversationMessage(role: .assistant, text: t) }
    private func texts(_ messages: [ConversationMessage]) -> [String] {
        messages.map { $0.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined() }
    }

    @Test func emptyByDefault() async throws {
        let store = InMemoryChatStorage()
        #expect(try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: nil).isEmpty)
    }

    @Test func seedIsReturnedAsHistory() async throws {
        // The point of the type: hand it a conversation at init and a consumer fetches it as history.
        let store = InMemoryChatStorage([user("what are the odds?"), assistant("PSG 2.5")])
        let history = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: nil)
        #expect(texts(history) == ["what are the odds?", "PSG 2.5"])
    }

    @Test func isScopeAgnostic() async throws {
        // Seed is returned regardless of (userId/sessionId/agentId) — that's what lets seeding work
        // without knowing the consumer's agentId.
        let store = InMemoryChatStorage([user("hi"), assistant("hello")])
        let a = try await store.fetch(userId: "u1", sessionId: "s1", agentId: "agent-x", maxMessages: nil)
        let b = try await store.fetch(userId: "u2", sessionId: "s2", agentId: "agent-y", maxMessages: nil)
        #expect(texts(a) == texts(b))
    }

    @Test func savesAppendToTheConversation() async throws {
        let store = InMemoryChatStorage([user("q1"), assistant("a1")])
        try await store.saveMessages([user("q2"), assistant("a2")], userId: "u", sessionId: "s", agentId: "a", maxMessages: nil)
        #expect(texts(try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: nil)) == ["q1", "a1", "q2", "a2"])
    }

    @Test func dropsConsecutiveSameRole() async throws {
        let store = InMemoryChatStorage([user("q1"), assistant("a1")])
        // Last stored is .assistant; a second .assistant save is dropped to keep roles alternating.
        try await store.save(assistant("a1-dup"), userId: "u", sessionId: "s", agentId: "a", maxMessages: nil)
        #expect(texts(try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: nil)) == ["q1", "a1"])
    }

    @Test func fetchTrimsToEvenPairs() async throws {
        let store = InMemoryChatStorage([user("q1"), assistant("a1"), user("q2"), assistant("a2")])
        // maxMessages counts messages, rounding down to an even pair — keep the most recent 2.
        let history = try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 2)
        #expect(texts(history) == ["q2", "a2"])
    }

    @Test func seedIsPreservedOnWriteAndTrimmedOnlyOnRead() async throws {
        // A loaded conversation larger than the budget is NOT clipped on save (unlike the persistent
        // stores) — the budget applies to the fetched view, so the full conversation is preserved.
        let seed = (1...3).flatMap { [user("q\($0)"), assistant("a\($0)")] }   // 6 messages
        let store = InMemoryChatStorage(seed)
        try await store.saveMessages([user("q4"), assistant("a4")], userId: "u", sessionId: "s", agentId: "a", maxMessages: 4)
        #expect((try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: 4)).count == 4)    // view is trimmed…
        #expect((try await store.fetch(userId: "u", sessionId: "s", agentId: "a", maxMessages: nil)).count == 8)  // …but all 8 are kept
    }

    @Test func loadsAPriorConversationIntoTheOrchestrator() async throws {
        // End to end: a seeded store handed to the Orchestrator surfaces as the agent's history.
        let store = InMemoryChatStorage([user("my name is Sam"), assistant("Nice to meet you, Sam.")])
        let agent = HistoryEchoAgent()
        let orchestrator = Orchestrator(agents: [agent], store: store)
        for try await _ in orchestrator.route(.text("what's my name?"), userId: "u", sessionId: "s") {}
        #expect(texts(await agent.seenHistory) == ["my name is Sam", "Nice to meet you, Sam."])
    }

    /// A minimal agent that records the history it was handed and emits a fixed reply.
    private actor HistoryEchoAgent: AgentProtocol {
        nonisolated let name = "echo"
        nonisolated let description = "records the history it receives"
        private(set) var seenHistory: [ConversationMessage] = []
        private func record(_ h: [ConversationMessage]) { seenHistory = h }
        nonisolated func process(
            _ input: AgentInput, history: [ConversationMessage], context: AgentContext
        ) -> AsyncThrowingStream<AgentEvent, any Error> {
            AsyncThrowingStream { continuation in
                Task {
                    await self.record(history)
                    continuation.yield(.final(ConversationMessage(role: .assistant, text: "ok")))
                    continuation.finish()
                }
            }
        }
    }
}
