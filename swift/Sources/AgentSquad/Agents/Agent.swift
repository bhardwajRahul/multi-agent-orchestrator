import Foundation

/// The base agent: one `LLMClient` driving an internal tool-use loop. Storage-agnostic — takes
/// `history` in, streams events out; the `Orchestrator` fetches history and persists the `.final`.
/// Tracing flows via `AgentContext.span`; tools are an injected `ToolProvider`.
public struct Agent: AgentProtocol {
    public let name: String
    public let description: String
    /// Whether the orchestrator should persist this agent's turns.
    public let saveChat: Bool

    private let model: any LLMClient
    private let tools: (any ToolProvider)?
    private let systemPrompt: String?
    private let uiPolicy: UIPolicy
    private let toolRoundCap: Int

    /// Caps model calls per turn: 1 with no tools, else `toolRoundCap` (default 20). A turn that hits the cap leaves tool requests un-run and may emit an empty `.final`.
    public var maxToolRounds: Int { tools == nil ? 1 : toolRoundCap }

    /// Uses the default prompt filled with this agent's `name`/`description`. For a custom or no prompt, use the `systemPrompt:` initializer.
    public init(
        name: String,
        description: String = "",
        model: any LLMClient,
        tools: (any ToolProvider)? = nil,
        ui: UIPolicy = .forward,
        maxToolRounds: Int = 20,
        saveChat: Bool = true
    ) {
        self.init(
            name: name, description: description, model: model, tools: tools,
            systemPrompt: Agent.defaultSystemPrompt(name: name, description: description),
            ui: ui, maxToolRounds: maxToolRounds, saveChat: saveChat
        )
    }

    /// Supply the system prompt explicitly — your own string, or `nil` for none. Never picks up the default above.
    public init(
        name: String,
        description: String = "",
        model: any LLMClient,
        tools: (any ToolProvider)? = nil,
        systemPrompt: String?,
        ui: UIPolicy = .forward,
        maxToolRounds: Int = 20,
        saveChat: Bool = true
    ) {
        self.name = name
        self.description = description
        self.model = model
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.uiPolicy = ui
        self.toolRoundCap = maxToolRounds
        self.saveChat = saveChat
    }

    /// The base agent's default system prompt when none is supplied — ported from Python
    /// agent-squad's `BedrockLLMAgent`, with the agent's `name` and `description` filled in.
    public static func defaultSystemPrompt(name: String, description: String) -> String {
        """
        You are a \(name).
        \(description)
        You will engage in an open-ended conversation, providing helpful and accurate information \
        based on your expertise.
        The conversation will proceed as follows:
        - The human may ask an initial question or provide a prompt on any topic.
        - You will provide a relevant and informative response.
        - The human may then follow up with additional questions or prompts related to your previous \
        response, allowing for a multi-turn dialogue on that topic.
        - Or, the human may switch to a completely new and unrelated topic at any point.
        - You will seamlessly shift your focus to the new topic, providing thoughtful and coherent \
        responses based on your broad knowledge base.
        Throughout the conversation, you should aim to:
        - Understand the context and intent behind each new question or prompt.
        - Provide substantive and well-reasoned responses that directly address the query.
        - Draw insights and connections from your extensive knowledge when appropriate.
        - Ask for clarification if any part of the question or prompt is ambiguous.
        - Maintain a consistent, respectful, and engaging tone tailored to the human's communication \
        style.
        - Seamlessly transition between topics as the human introduces new subjects.
        """
    }

    public func process(
        _ input: AgentInput,
        history: [ConversationMessage],
        context: AgentContext
    ) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runTurn(input, history: history, context: context) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Turn

    private func runTurn(
        _ input: AgentInput,
        history: [ConversationMessage],
        context: AgentContext,
        emit: @Sendable (AgentEvent) -> Void
    ) async throws {
        guard case .text(let text) = input else { return }
        var messages = history
        messages.append(ConversationMessage(role: .user, text: text))

        let toolDefs = (try await tools?.listTools()) ?? []
        var roundsLeft = max(1, maxToolRounds)

        while true {
            let turn = try await complete(messages: messages, tools: toolDefs, context: context, emit: emit)
            roundsLeft -= 1

            // Stop and emit the final answer when the model wants no tools, the agent has none, or the cap is hit.
            guard let provider = tools, !turn.toolCalls.isEmpty, roundsLeft > 0 else {
                emit(.final(ConversationMessage(role: .assistant, parts: [.text(turn.text)])))
                return
            }

            // Record what the model asked for, then run each tool and feed the result back.
            messages.append(assistantToolCallMessage(text: turn.text, toolCalls: turn.toolCalls))
            for call in turn.toolCalls {
                let result = try await runTool(call, provider: provider, context: context, emit: emit)
                messages.append(ConversationMessage(role: .tool, parts: [.toolResult(id: call.id, content: toolResultContent(result))]))
            }
        }
    }

    private struct ToolCall: Sendable {
        let id: String
        let name: String
        let arguments: JSONValue
    }

    private struct ModelTurn {
        var text = ""
        var toolCalls: [ToolCall] = []
    }

    /// One model call: stream text deltas + tool-call requests, trace it as a generation.
    private func complete(
        messages: [ConversationMessage],
        tools toolDefs: [AgentTool],
        context: AgentContext,
        emit: @Sendable (AgentEvent) -> Void
    ) async throws -> ModelTurn {
        // LLMClient doesn't surface the model name, so the generation span records it empty.
        let span = context.span?.generation("llm.completion", model: "", input: nil)
        var turn = ModelTurn()
        var usage: LLMUsage?
        do {
            for try await event in model.complete(LLMRequest(system: systemPrompt, messages: messages, tools: toolDefs)) {
                switch event {
                case .textDelta(let delta):
                    turn.text += delta
                    emit(.textDelta(delta))
                case .toolCall(let id, let name, let arguments):
                    turn.toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                    emit(.toolCall(id: id, name: name, arguments: arguments))
                case .done(_, let reported):
                    usage = reported
                }
            }
        } catch {
            span?.end(output: nil, error: error)
            throw error
        }
        if let usage { span?.usage(promptTokens: usage.promptTokens, completionTokens: usage.completionTokens) }
        span?.end(output: .string(turn.text), error: nil)
        return turn
    }

    private func runTool(
        _ call: ToolCall,
        provider: any ToolProvider,
        context: AgentContext,
        emit: @Sendable (AgentEvent) -> Void
    ) async throws -> ToolResult {
        let span = context.span?.span("tool.\(call.name)", input: call.arguments)
        do {
            let result = try await provider.call(call.name, arguments: call.arguments)
            span?.end(output: result.structuredContent, error: nil)
            // Forward the advertised UI only when the policy allows; on `.suppress` the data still
            // rides back to the model via the tool-result message below.
            if uiPolicy == .forward, let payload = result.ui {
                emit(.widget(payload))
            }
            return result
        } catch {
            span?.end(output: nil, error: error)
            throw error
        }
    }

    private func assistantToolCallMessage(
        text: String,
        toolCalls: [ToolCall]
    ) -> ConversationMessage {
        var parts: [ContentPart] = text.isEmpty ? [] : [.text(text)]
        parts.append(contentsOf: toolCalls.map { .toolCall(id: $0.id, name: $0.name, arguments: $0.arguments) })
        return ConversationMessage(role: .assistant, parts: parts)
    }

    /// The tool result fed back to the model: its model-facing text, else its structured data so
    /// the model is never blind to what the tool returned.
    private func toolResultContent(_ result: ToolResult) -> JSONValue {
        let text = (result.content ?? []).compactMap { part -> String? in
            if case .text(let value) = part { return value } else { return nil }
        }.joined(separator: "\n")
        return text.isEmpty ? result.structuredContent : .string(text)
    }
}
