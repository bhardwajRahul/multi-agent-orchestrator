import Foundation
import Testing

@testable import AgentSquad

@Suite struct LLMClassifierTests {
    private func agents() -> [any AgentProtocol] {
        [
            Agent(name: "sports", description: "Sports & betting", model: MockLLMClient([])),
            Agent(name: "casino", description: "Casino games", model: MockLLMClient([])),
        ]
    }

    @Test func selectsTheAgentTheModelChose() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("casino"), "confidence": .double(0.9)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let classifier = LLMClassifier(model: model)
        let result = try await classifier.classify("blackjack odds?", history: [], agents: agents())
        #expect(result.selectedAgent?.id == "casino")
        #expect(result.confidence == 0.9)
    }

    @Test func parsesIntegerConfidence() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("sports"), "confidence": .int(1)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("psg odds", history: [], agents: agents())
        #expect(result.selectedAgent?.id == "sports")
        #expect(result.confidence == 1.0)
    }

    @Test func noToolCallYieldsNilSelection() async throws {
        let model = MockLLMClient([.textDelta("I'm not sure"), .done(reason: .stop, usage: nil)])
        let result = try await LLMClassifier(model: model).classify("hmm", history: [], agents: agents())
        #expect(result.selectedAgent == nil)   // → Orchestrator falls back to default
        #expect(result.confidence == 0)
    }

    @Test func hallucinatedAgentIdYieldsNilSelection() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("poker"), "confidence": .double(0.8)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("x", history: [], agents: agents())
        #expect(result.selectedAgent == nil)   // "poker" isn't a candidate
    }

    @Test func ignoresOtherToolCalls() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "something_else", arguments: .object([:])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("x", history: [], agents: agents())
        #expect(result.selectedAgent == nil)
    }

    @Test func confidenceAsStringStillSelectsWithZeroConfidence() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("sports"), "confidence": .string("0.9")])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("x", history: [], agents: agents())
        #expect(result.selectedAgent?.id == "sports")
        #expect(result.confidence == 0)   // unparseable confidence → 0, selection still stands
    }

    @Test func nonObjectArgumentsYieldNilSelection() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .string("oops")),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("x", history: [], agents: agents())
        #expect(result.selectedAgent == nil)
    }

    @Test func textBeforeToolCallStillSelects() async throws {
        let model = MockLLMClient([
            .textDelta("thinking…"),
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("casino"), "confidence": .double(0.7)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("x", history: [], agents: agents())
        #expect(result.selectedAgent?.id == "casino")
    }

    @Test func emptyAgentsYieldNilSelection() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("sports"), "confidence": .double(1)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let result = try await LLMClassifier(model: model).classify("x", history: [], agents: [])
        #expect(result.selectedAgent == nil)
    }

    @Test func propagatesLLMErrors() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await LLMClassifier(model: FailingLLMClient()).classify("x", history: [], agents: agents())
        }
    }

    // MARK: - End-to-end through the Orchestrator

    @Test func routesThroughOrchestratorToTheChosenAgent() async throws {
        let classifier = LLMClassifier(model: MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("casino"), "confidence": .double(0.9)])),
            .done(reason: .toolCalls, usage: nil),
        ]))
        let orchestrator = Orchestrator(
            agents: [
                Agent(name: "sports", model: MockLLMClient([.textDelta("sports"), .done(reason: .stop, usage: nil)])),
                Agent(name: "casino", model: MockLLMClient([.textDelta("casino"), .done(reason: .stop, usage: nil)])),
            ],
            classifier: classifier,
            store: try DeviceChatStorage(userId: "u", inMemory: true)
        )
        let events = try await collect(orchestrator.route(.text("blackjack odds?"), userId: "u", sessionId: "s"))
        #expect(finalText(events) == "casino")
    }

    @Test func orchestratorFallsBackToDefaultWhenClassifierSelectsNothing() async throws {
        let classifier = LLMClassifier(model: MockLLMClient([.textDelta("not sure"), .done(reason: .stop, usage: nil)]))   // no tool call
        let orchestrator = Orchestrator(
            agents: [
                Agent(name: "sports", model: MockLLMClient([.textDelta("sports"), .done(reason: .stop, usage: nil)])),
                Agent(name: "casino", model: MockLLMClient([.textDelta("casino"), .done(reason: .stop, usage: nil)])),
            ],
            classifier: classifier,
            store: try DeviceChatStorage(userId: "u", inMemory: true)
        )
        let events = try await collect(orchestrator.route(.text("hello"), userId: "u", sessionId: "s"))
        #expect(finalText(events) == "sports")   // null selection → first agent (the default)
    }

    @Test func requestListsAgentsAndConstrainsTheToolEnum() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("sports"), "confidence": .double(1)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let history = [ConversationMessage(role: .user, text: "earlier")]
        _ = try await LLMClassifier(model: model).classify("now", history: history, agents: agents())

        let request = try #require(model.capturedRequests().first)
        #expect(request.system?.contains("sports: sports — Sports & betting") == true)   // roster listed
        #expect(request.system?.contains("casino: casino — Casino games") == true)
        // history + the new input are forwarded.
        let texts = request.messages.flatMap(\.parts).compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        #expect(texts == ["earlier", "now"])
        // the tool constrains `agent` to the candidate ids.
        let tool = try #require(request.tools.first)
        #expect(tool.name == "select_agent")
        guard case .object(let schema) = tool.inputSchema,
              case .object(let props)? = schema["properties"],
              case .object(let agentProp)? = props["agent"],
              case .array(let enumValues)? = agentProp["enum"]
        else { Issue.record("expected agent enum in schema"); return }
        #expect(enumValues == [.string("sports"), .string("casino")])
    }

    @Test func defaultPromptCarriesTheAgentMatcherGuidance() async throws {
        // The ported AgentMatcher prompt must keep the parts that earn their keep: persona,
        // the follow-up rule, confidence levels, and worked examples.
        let prompt = LLMClassifier.defaultInstructions
        #expect(prompt.contains("AgentMatcher"))
        #expect(prompt.contains("\"yes\""))            // follow-up handling
        #expect(prompt.contains("Confidence:"))
        #expect(prompt.contains("Examples:"))
        #expect(prompt.contains("{{AGENT_DESCRIPTIONS}}"))   // filled in at classify time
    }

    @Test func rosterReplacesThePlaceholderWithNoLeftoverToken() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("sports"), "confidence": .double(1)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        _ = try await LLMClassifier(model: model).classify("now", history: [], agents: agents())
        let system = try #require(model.capturedRequests().first?.system)
        #expect(!system.contains("{{AGENT_DESCRIPTIONS}}"))                 // placeholder substituted
        #expect(system.contains("- sports: sports — Sports & betting"))    // roster spliced in
        #expect(system.contains("AgentMatcher"))                           // around the real prompt
    }

    @Test func customInstructionsWithoutPlaceholderGetRosterAppended() async throws {
        let model = MockLLMClient([
            .toolCall(id: "c1", name: "select_agent", arguments: .object(["agent": .string("sports"), "confidence": .double(1)])),
            .done(reason: .toolCalls, usage: nil),
        ])
        let classifier = LLMClassifier(model: model, instructions: "Pick the best agent.")
        _ = try await classifier.classify("now", history: [], agents: agents())
        let system = try #require(model.capturedRequests().first?.system)
        #expect(system.contains("Pick the best agent."))                       // custom prompt kept
        #expect(system.contains("Agents:\n- sports: sports — Sports & betting"))   // roster appended
        #expect(!system.contains("{{AGENT_DESCRIPTIONS}}"))
    }
}
