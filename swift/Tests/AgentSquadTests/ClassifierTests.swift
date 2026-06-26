import Foundation
import Testing

@testable import AgentSquad

@Suite struct ClassifierTests {
    private struct TinyAgent: AgentProtocol {
        let name: String
        let description = ""
        func process(
            _ input: AgentInput,
            history: [ConversationMessage],
            context: AgentContext
        ) -> AsyncThrowingStream<AgentEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    // Matches the picked id against the available agents, mirroring how LLMClassifier will resolve.
    private struct StubClassifier: Classifier {
        let pick: String?
        func classify(
            _ input: String,
            history: [ConversationMessage],
            agents: [any AgentProtocol]
        ) async throws -> ClassifierResult {
            guard let pick, let agent = agents.first(where: { $0.id == pick }) else {
                return ClassifierResult(selectedAgent: nil, confidence: 0)
            }
            return ClassifierResult(selectedAgent: agent, confidence: 0.9)
        }
    }

    @Test func selectsMatchingAgent() async throws {
        let agents: [any AgentProtocol] = [TinyAgent(name: "Sports"), TinyAgent(name: "Casino")]
        let result = try await StubClassifier(pick: "sports").classify("odds?", history: [], agents: agents)
        #expect(result.selectedAgent?.id == "sports")
        #expect(result.confidence == 0.9)
    }

    @Test func nilSelectionWhenNoMatch() async throws {
        let result = try await StubClassifier(pick: nil).classify("x", history: [], agents: [])
        #expect(result.selectedAgent == nil)
        #expect(result.confidence == 0)
    }

    // Invariant: a pick that resolves to no agent in the list yields nil, never a fabricated agent.
    @Test func unknownPickYieldsNilNotAFabricatedAgent() async throws {
        let agents: [any AgentProtocol] = [TinyAgent(name: "Sports")]
        let result = try await StubClassifier(pick: "casino").classify("x", history: [], agents: agents)
        #expect(result.selectedAgent == nil)
    }
}
