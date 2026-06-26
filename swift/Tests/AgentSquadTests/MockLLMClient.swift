import Foundation

@testable import AgentSquad

/// Scripted `LLMClient` for tests: returns one `[LLMStreamEvent]` "turn" per `complete` call,
/// advancing through `turns` (clamping at the last) so a multi-round tool loop can be scripted.
final class MockLLMClient: LLMClient, @unchecked Sendable {
    private let turns: [[LLMStreamEvent]]
    private let lock = NSLock()
    private var index = 0
    private var recorded: [LLMRequest] = []

    init(turns: [[LLMStreamEvent]]) { self.turns = turns }
    convenience init(_ single: [LLMStreamEvent]) { self.init(turns: [single]) }

    /// Requests seen so far, in order — for asserting what the agent sent the model.
    func capturedRequests() -> [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        lock.lock()
        recorded.append(request)
        let events = turns.isEmpty ? [] : turns[min(index, turns.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
