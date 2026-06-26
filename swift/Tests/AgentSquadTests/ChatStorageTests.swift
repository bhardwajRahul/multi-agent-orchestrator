import Foundation
import Testing

@testable import AgentSquad

@Suite struct ChatStorageTests {
    // Minimal conformer so the protocol-extension defaults can be exercised without a backend.
    private struct StubStore: ChatStorage {
        func fetch(userId: String, sessionId: String, agentId: String, maxMessages: Int?) async throws -> [ConversationMessage] { [] }
        func save(_ message: ConversationMessage, userId: String, sessionId: String, agentId: String, maxMessages: Int?) async throws {}
        func saveMessages(_ messages: [ConversationMessage], userId: String, sessionId: String, agentId: String, maxMessages: Int?) async throws {}
        func fetchAllChats(userId: String, sessionId: String) async throws -> [ConversationMessage] { [] }
    }

    private let store = StubStore()

    /// `n` messages alternating user/assistant, text "0"…"n-1".
    private func messages(_ n: Int) -> [ConversationMessage] {
        (0..<n).map { ConversationMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "\($0)") }
    }

    @Test func trimNilKeepsEverything() {
        #expect(store.trimToEvenPairs(messages(5), maxMessages: nil).count == 5)
    }

    @Test func trimRoundsOddDownToEven() {
        #expect(store.trimToEvenPairs(messages(10), maxMessages: 5).count == 4)
    }

    @Test func trimKeepsMostRecent() {
        let kept = store.trimToEvenPairs(messages(10), maxMessages: 4)
        #expect(kept.count == 4)
        #expect(kept.first?.parts == [.text("6")])
        #expect(kept.last?.parts == [.text("9")])
    }

    @Test func trimOddOneYieldsEmpty() {
        #expect(store.trimToEvenPairs(messages(5), maxMessages: 1).isEmpty)
    }

    @Test func trimZeroYieldsEmpty() {
        #expect(store.trimToEvenPairs(messages(5), maxMessages: 0).isEmpty)
    }

    @Test func trimNegativeYieldsEmpty() {
        #expect(store.trimToEvenPairs(messages(5), maxMessages: -2).isEmpty)
    }

    @Test func trimTwoKeepsLastPair() {
        let kept = store.trimToEvenPairs(messages(10), maxMessages: 2)
        #expect(kept.map(\.parts) == [[.text("8")], [.text("9")]])
        #expect(kept.first?.role == .user)
        #expect(kept.last?.role == .assistant)
    }

    @Test func trimLargerThanCountKeepsAll() {
        #expect(store.trimToEvenPairs(messages(3), maxMessages: 100).count == 3)
    }

    @Test func consecutiveSameRoleDetection() {
        let history = [ConversationMessage(role: .user, text: "hi")]
        #expect(store.isConsecutiveSameRole(history, ConversationMessage(role: .user, text: "again")))
        #expect(store.isConsecutiveSameRole(history, ConversationMessage(role: .assistant, text: "hello")) == false)
        #expect(store.isConsecutiveSameRole([], ConversationMessage(role: .user, text: "x")) == false)
    }
}
