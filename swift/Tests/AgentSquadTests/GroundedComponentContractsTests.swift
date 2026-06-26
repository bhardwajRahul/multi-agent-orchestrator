import Foundation
import Testing

@testable import AgentSquad

@Suite struct PresenterPromptTests {
    @Test func defaultGroundsAndIgnoresTool() {
        let prompt = PresenterPrompt.default
        #expect(prompt.resolve(primaryTool: nil).isEmpty == false)
        #expect(prompt.resolve(primaryTool: "anything") == prompt.resolve(primaryTool: nil))
    }

    @Test func perToolPicksByPrimaryTool() {
        let prompt = PresenterPrompt(
            default: "DEFAULT",
            perTool: ["get_odds": "ODDS PROMPT", "get_lineup": "LINEUP PROMPT"]
        )
        #expect(prompt.resolve(primaryTool: "get_odds") == "ODDS PROMPT")
        #expect(prompt.resolve(primaryTool: "get_lineup") == "LINEUP PROMPT")
    }

    @Test func perToolFallsBackToDefault() {
        let prompt = PresenterPrompt(default: "DEFAULT", perTool: ["get_odds": "ODDS"])
        #expect(prompt.resolve(primaryTool: "unknown") == "DEFAULT")
        #expect(prompt.resolve(primaryTool: nil) == "DEFAULT")
    }
}

@Suite struct LLMClientContractTests {
    private struct StubLLM: LLMClient {
        let events: [LLMStreamEvent]
        func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    @Test func streamsDeltasThenToolCallThenDone() async throws {
        let stub = StubLLM(events: [
            .textDelta("hi"),
            .toolCall(id: "c1", name: "get_odds", arguments: ["match": "PSG"]),
            .done(reason: .toolCalls, usage: LLMUsage(promptTokens: 10, completionTokens: 2)),
        ])
        var text = ""
        var toolCalls = 0
        var reason: FinishReason?
        var usage: LLMUsage?
        for try await event in stub.complete(LLMRequest(messages: [])) {
            switch event {
            case .textDelta(let delta): text += delta
            case .toolCall: toolCalls += 1
            case .done(let stop, let reported): reason = stop; usage = reported
            }
        }
        #expect(text == "hi")
        #expect(toolCalls == 1)
        #expect(reason == .toolCalls)
        #expect(usage == LLMUsage(promptTokens: 10, completionTokens: 2))
    }

    @Test func collectsParallelToolCallsInOneTurn() async throws {
        let stub = StubLLM(events: [
            .toolCall(id: "c1", name: "get_odds", arguments: .object([:])),
            .toolCall(id: "c2", name: "get_lineup", arguments: .object([:])),
            .done(reason: .toolCalls, usage: nil),
        ])
        var ids: [String] = []
        for try await event in stub.complete(LLMRequest(messages: [])) {
            if case .toolCall(let id, _, _) = event { ids.append(id) }
        }
        #expect(ids == ["c1", "c2"])
    }

    @Test func rethrowsStreamFailure() async {
        let failing = FailingLLMClient(leadingDelta: "partial")
        await #expect(throws: FailingLLMClient.Boom.self) {
            for try await _ in failing.complete(LLMRequest(messages: [])) {}
        }
    }
}

@Suite struct ToolOutputCuratorContractTests {
    private struct NamesCurator: ToolOutputCurator {
        func curate(_ results: [CapturedTool]) -> String {
            results.map(\.name).joined(separator: "\n")
        }
    }

    @Test func curatorConsumesCapturedTools() {
        let captured = [
            CapturedTool(name: "get_odds", structuredContent: ["home": 1.26]),
            CapturedTool(name: "get_lineup", ui: "ui://sport/lineup", structuredContent: .object([:])),
        ]
        #expect(NamesCurator().curate(captured) == "get_odds\nget_lineup")
    }

    @Test func capturedToolHoldsFields() {
        let tool = CapturedTool(name: "x", ui: "ui://x", structuredContent: ["a": 1], content: [.text("hi")])
        #expect(tool.ui == "ui://x")
        #expect(tool.structuredContent == ["a": 1])
        #expect(tool.content == [.text("hi")])
    }

    // The no-tool / chit-chat boundary: curating nothing yields empty text.
    @Test func curatingEmptyYieldsEmptyString() {
        #expect(NamesCurator().curate([]).isEmpty)
    }
}

@Suite struct PerToolCuratorTests {
    private func bigMatches(_ count: Int) -> CapturedTool {
        let rows = (0..<count).map { JSONValue.object(["name": .string("Match \($0)")]) }
        return CapturedTool(name: "find_matches", ui: "ui://matches",
                            structuredContent: .object(["matches": .array(rows)]))
    }

    @Test func routesToTheMatchingFormatterByToolName() {
        let curator = PerToolCurator.perTool([
            "find_matches": { _ in "MATCHES" },
            "get_team_stats": { _ in "STATS" },
        ], default: { _ in "DEFAULT" })

        let feed = curator.curate([
            CapturedTool(name: "get_team_stats", structuredContent: .object([:])),
            CapturedTool(name: "find_matches", structuredContent: .object([:])),
        ])
        #expect(feed == "STATS\n\nMATCHES")   // routed per name, order preserved
    }

    @Test func unmappedToolFallsBackToTheDefault() {
        let curator = PerToolCurator.perTool(["find_matches": { _ in "MATCHES" }], default: { _ in "FALLBACK" })
        let feed = curator.curate([CapturedTool(name: "web_research", structuredContent: .object([:]))])
        #expect(feed == "FALLBACK")
    }

    @Test func defaultFallbackIsTheLosslessDataBlockSection() {
        // No `default:` given → unmapped tools render the faithful dataBlock section.
        let curator = PerToolCurator.perTool([:])
        let tool = CapturedTool(name: "get_odds", structuredContent: .object([:]), content: [.text("PSG 2.5")])
        #expect(curator.curate([tool]) == "### get_odds\nPSG 2.5")
    }

    @Test func aTrimmingFormatterShrinksAnOversizedPayload() {
        // The whole point: a formatter that caps rows produces a far smaller feed than dataBlock.
        let trimming = PerToolCurator.perTool([
            "find_matches": { tool in
                guard case .object(let obj) = tool.structuredContent,
                      case .array(let rows)? = obj["matches"] else { return "" }
                return "### find_matches (\(rows.count) matches, showing 3)"
            }
        ])
        let big = bigMatches(200)
        let trimmed = trimming.curate([big])
        let full = DataBlockCurator().curate([big])
        #expect(trimmed.count < full.count)
        #expect(trimmed == "### find_matches (200 matches, showing 3)")
    }
}
