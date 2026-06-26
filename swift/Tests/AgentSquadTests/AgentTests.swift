import Foundation
import Testing

@testable import AgentSquad

@Suite struct AgentTests {
    private func context() -> AgentContext { AgentContext(userId: "u", sessionId: "s") }

    /// One tool returning a fixed result.
    private func stub(_ name: String, _ result: ToolResult) -> StubToolProvider {
        StubToolProvider(tool: AgentTool(name: name, description: ""), result: result)
    }

    @Test func singlePassNoToolsStreamsTextThenFinal() async throws {
        let model = MockLLMClient([
            .textDelta("hel"), .textDelta("lo"),
            .done(reason: .stop, usage: LLMUsage(promptTokens: 5, completionTokens: 2)),
        ])
        let events = try await collect(Agent(name: "A", model: model).process(.text("hi"), history: [], context: context()))
        #expect(events.count == 3)
        guard case .final(let message) = events.last else { Issue.record("expected .final"); return }
        #expect(message.role == .assistant)
        #expect(message.parts == [.text("hello")])
    }

    @Test func noToolsMeansSingleRound() {
        #expect(Agent(name: "A", model: MockLLMClient([.done(reason: .stop, usage: nil)])).maxToolRounds == 1)
    }

    @Test func runsToolThenProducesGroundedFinal() async throws {
        let tools = stub("get_odds", ToolResult(content: [.text("1.26")], structuredContent: ["home": 1.26]))
        let model = MockLLMClient(turns: [
            [.toolCall(id: "c1", name: "get_odds", arguments: ["m": "PSG"]), .done(reason: .toolCalls, usage: nil)],
            [.textDelta("PSG at 1.26"), .done(reason: .stop, usage: nil)],
        ])
        let events = try await collect(Agent(name: "A", model: model, tools: tools).process(.text("odds?"), history: [], context: context()))
        #expect(events.contains { $0.isToolCall })
        #expect(tools.callCount == 1)
        guard case .final(let message) = events.last else { Issue.record("expected .final"); return }
        #expect(message.parts == [.text("PSG at 1.26")])
    }

    @Test func forwardPolicyEmitsWidget() async throws {
        let events = try await collect(uiAgent(.forward).process(.text("x"), history: [], context: context()))
        #expect(events.contains { $0.isWidget })
    }

    @Test func suppressPolicyEmitsNoWidget() async throws {
        let events = try await collect(uiAgent(.suppress).process(.text("x"), history: [], context: context()))
        #expect(!events.contains { $0.isWidget })
    }

    @Test func toolRoundCapTerminatesAndStillEmitsFinal() async throws {
        // The model asks for a tool on every turn; the cap must stop the loop with a final.
        let tools = stub("t", ToolResult(content: [.text("r")]))
        let model = MockLLMClient([.toolCall(id: "c", name: "t", arguments: .object([:])), .done(reason: .toolCalls, usage: nil)])
        let events = try await collect(Agent(name: "A", model: model, tools: tools, maxToolRounds: 2).process(.text("x"), history: [], context: context()))
        #expect(events.contains { $0.isFinal })
        #expect(tools.callCount <= 2)   // bounded, not infinite
    }

    @Test func transportErrorPropagates() async {
        let agent = Agent(name: "A", model: FailingLLMClient())
        await #expect(throws: FailingLLMClient.Boom.self) {
            for try await _ in agent.process(.text("x"), history: [], context: context()) {}
        }
    }

    // A tool-level error is fed back to the model (not thrown) and the loop continues to recover.
    @Test func toolErrorIsFedBackAndLoopContinues() async throws {
        let tools = stub("t", .failure("nope"))
        let model = MockLLMClient(turns: [
            [.toolCall(id: "c", name: "t", arguments: .object([:])), .done(reason: .toolCalls, usage: nil)],
            [.textDelta("recovered"), .done(reason: .stop, usage: nil)],
        ])
        let events = try await collect(Agent(name: "A", model: model, tools: tools).process(.text("x"), history: [], context: context()))
        #expect(tools.callCount == 1)
        guard case .final(let message) = events.last else { Issue.record("expected .final"); return }
        #expect(message.parts == [.text("recovered")])
    }

    @Test func runsParallelToolCallsInOneTurn() async throws {
        let result = ToolResult(content: [.text("r")])
        let tools = StubToolProvider(
            tools: [AgentTool(name: "a", description: ""), AgentTool(name: "b", description: "")],
            results: ["a": result, "b": result]
        )
        let model = MockLLMClient(turns: [
            [.toolCall(id: "c1", name: "a", arguments: .object([:])),
             .toolCall(id: "c2", name: "b", arguments: .object([:])),
             .done(reason: .toolCalls, usage: nil)],
            [.textDelta("done"), .done(reason: .stop, usage: nil)],
        ])
        let events = try await collect(Agent(name: "A", model: model, tools: tools).process(.text("x"), history: [], context: context()))
        #expect(tools.callCount == 2)
        #expect(events.count { $0.isToolCall } == 2)
    }

    @Test func threadsHistoryThenUserMessageIntoRequest() async throws {
        let model = MockLLMClient([.textDelta("ok"), .done(reason: .stop, usage: nil)])
        let history = [
            ConversationMessage(role: .user, text: "prev"),
            ConversationMessage(role: .assistant, text: "prevA"),
        ]
        _ = try await collect(Agent(name: "A", model: model).process(.text("now"), history: history, context: context()))
        let sent = model.capturedRequests().first
        #expect(sent?.messages.count == 3)
        #expect(sent?.messages.first?.parts == [.text("prev")])
        #expect(sent?.messages.last?.role == .user)
        #expect(sent?.messages.last?.parts == [.text("now")])
    }

    // The grounding boundary: only the model's text reaches the final; structuredContent does not.
    @Test func structuredContentDoesNotLeakIntoFinal() async throws {
        let tools = stub("t", ToolResult(content: [.text("text-for-model")], structuredContent: ["secret": "data"]))
        let model = MockLLMClient(turns: [
            [.toolCall(id: "c", name: "t", arguments: .object([:])), .done(reason: .toolCalls, usage: nil)],
            [.textDelta("answer"), .done(reason: .stop, usage: nil)],
        ])
        let events = try await collect(Agent(name: "A", model: model, tools: tools).process(.text("x"), history: [], context: context()))
        guard case .final(let message) = events.last else { Issue.record("expected .final"); return }
        #expect(message.parts == [.text("answer")])
        #expect(message.parts.allSatisfy { if case .toolResult = $0 { return false } else { return true } })
    }

    // MARK: - Default system prompt

    @Test func omittingSystemPromptUsesTheDefaultFilledWithNameAndDescription() async throws {
        let model = MockLLMClient([.textDelta("hi"), .done(reason: .stop, usage: nil)])
        let agent = Agent(name: "Shop", description: "Shopping assistant", model: model)   // no systemPrompt
        _ = try await collect(agent.process(.text("q"), history: [], context: context()))

        let system = try #require(model.capturedRequests().first?.system)
        #expect(system.contains("You are a Shop."))            // name filled in
        #expect(system.contains("Shopping assistant"))         // description filled in
        #expect(system == Agent.defaultSystemPrompt(name: "Shop", description: "Shopping assistant"))
    }

    @Test func explicitNilSystemPromptRunsWithNoSystemPrompt() async throws {
        let model = MockLLMClient([.textDelta("hi"), .done(reason: .stop, usage: nil)])
        let agent = Agent(name: "A", model: model, systemPrompt: nil)   // explicit nil — opts out of the default
        _ = try await collect(agent.process(.text("q"), history: [], context: context()))
        #expect(model.capturedRequests().first?.system == nil)
    }

    @Test func explicitSystemPromptIsUsedVerbatim() async throws {
        let model = MockLLMClient([.textDelta("hi"), .done(reason: .stop, usage: nil)])
        let agent = Agent(name: "A", model: model, systemPrompt: "Be terse.")
        _ = try await collect(agent.process(.text("q"), history: [], context: context()))
        #expect(model.capturedRequests().first?.system == "Be terse.")
    }

    // MARK: - Helpers

    private func uiAgent(_ policy: UIPolicy) -> Agent {
        let payload = UIPayload(resourceURI: "ui://m", mimeType: "text/html;profile=mcp-app")
        let tools = StubToolProvider(
            tool: AgentTool(name: "t", description: "", ui: "ui://m"),
            result: ToolResult(structuredContent: .object([:]), ui: payload)
        )
        let model = MockLLMClient(turns: [
            [.toolCall(id: "c1", name: "t", arguments: .object([:])), .done(reason: .toolCalls, usage: nil)],
            [.textDelta("done"), .done(reason: .stop, usage: nil)],
        ])
        return Agent(name: "A", model: model, tools: tools, ui: policy)
    }
}
