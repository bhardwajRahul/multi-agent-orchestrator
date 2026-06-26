import Foundation
import Testing

@testable import AgentSquad

@Suite struct AgentContractsTests {
    // Minimal conformer to exercise the protocol's default implementations.
    private struct StubAgent: AgentProtocol {
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

    // Overrides the tool-loop cap, as a real tool-bearing agent will (S2).
    private struct ToolishAgent: AgentProtocol {
        let name = "Toolish"
        let description = ""
        var maxToolRounds: Int { 8 }
        func process(
            _ input: AgentInput,
            history: [ConversationMessage],
            context: AgentContext
        ) -> AsyncThrowingStream<AgentEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test func defaultIdIsSlugifiedName() {
        #expect(StubAgent(name: "Tech Agent").id == "tech-agent")
    }

    @Test func defaultMaxToolRoundsIsOne() {
        #expect(StubAgent(name: "X").maxToolRounds == 1)   // no tools → single model call
    }

    @Test func conformerCanOverrideMaxToolRounds() {
        #expect(ToolishAgent().maxToolRounds == 8)
    }

    @Test func contextDefaultsParamsAndSpan() {
        let context = AgentContext(userId: "u1", sessionId: "s1")
        #expect(context.params.isEmpty)
        #expect(context.span == nil)
    }

    @Test(arguments: [
        ("Tech Agent", "tech-agent"),
        ("Sports & Betting", "sports-betting"),
        ("PSG (live)", "psg-live"),
        ("already-slug", "already-slug"),
        ("  spaced  out ", "spaced-out"),   // trimmed/collapsed (intentional divergence from Python)
        ("Über Café", "über-café"),          // Unicode-aware (intentional divergence)
        ("", ""),                            // degenerate names yield "" by contract
        ("!!!", ""),
        ("   ", ""),
    ])
    func slugifyCases(_ pair: (input: String, expected: String)) {
        #expect(slugify(pair.input) == pair.expected)
    }
}
