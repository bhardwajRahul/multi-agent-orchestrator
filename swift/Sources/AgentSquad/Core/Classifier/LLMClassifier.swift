import Foundation

/// Routes a turn via an `LLMClient`, adapting Python agent-squad's `AgentMatcher` prompt. The model
/// calls a single `select_agent` tool whose `agent` arg is an enum of the candidate ids; an absent or
/// hallucinated choice resolves to `nil` → the Orchestrator falls back to the default agent.
public struct LLMClassifier: Classifier {
    private let model: any LLMClient
    private let instructions: String

    public init(model: any LLMClient, instructions: String = LLMClassifier.defaultInstructions) {
        self.model = model
        self.instructions = instructions
    }

    public func classify(
        _ input: String,
        history: [ConversationMessage],
        agents: [any AgentProtocol]
    ) async throws -> ClassifierResult {
        var messages = history
        messages.append(ConversationMessage(role: .user, text: input))
        let request = LLMRequest(system: systemPrompt(agents), messages: messages, tools: [selectAgentTool(agents)])

        var selectedId: String?
        var confidence = 0.0
        for try await event in model.complete(request) {
            guard case .toolCall(_, "select_agent", let arguments) = event,
                  case .object(let fields) = arguments else { continue }
            if case .string(let id)? = fields["agent"] { selectedId = id }
            confidence = number(fields["confidence"]) ?? 0
            break   // first selection wins
        }

        let agent = agents.first { $0.id == selectedId }   // nil on no match / no tool call
        return ClassifierResult(selectedAgent: agent, confidence: agent == nil ? 0 : confidence)
    }

    // MARK: - Prompt + tool

    private func systemPrompt(_ agents: [any AgentProtocol]) -> String {
        let roster = agents.map { "- \($0.id): \($0.name) — \($0.description)" }.joined(separator: "\n")
        // The default prompt carries an {{AGENT_DESCRIPTIONS}} placeholder (as in Python); custom
        // instructions without one get the roster appended.
        if instructions.contains("{{AGENT_DESCRIPTIONS}}") {
            return instructions.replacingOccurrences(of: "{{AGENT_DESCRIPTIONS}}", with: roster)
        }
        return "\(instructions)\n\nAgents:\n\(roster)"
    }

    private func selectAgentTool(_ agents: [any AgentProtocol]) -> AgentTool {
        AgentTool(
            name: "select_agent",
            description: "Select the agent best suited to handle the user's message.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "agent": .object([
                        "type": .string("string"),
                        "enum": .array(agents.map { .string($0.id) }),
                        "description": .string("The id of the chosen agent."),
                    ]),
                    "confidence": .object([
                        "type": .string("number"),
                        "description": .string("Confidence in the choice, 0 to 1."),
                    ]),
                ]),
                "required": .array([.string("agent"), .string("confidence")]),
            ])
        )
    }

    private func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    /// Adapted from Python agent-squad's `AgentMatcher` routing prompt.
    public static let defaultInstructions = """
        You are AgentMatcher, an intelligent assistant designed to analyze user queries and match them
        with the most suitable agent. Your task is to understand the user's request, identify key
        entities and intents, and determine which agent would be best equipped to handle the query.

        Important: The user's input may be a follow-up response to a previous interaction. The
        conversation history, including the previously selected agent, is provided as prior messages.
        If the user's input appears to be a continuation of the previous conversation (e.g., "yes",
        "ok", "I want to know more", "1"), select the same agent as before.

        Analyze the user's input and categorize it into one of the following agents:
        <agents>
        {{AGENT_DESCRIPTIONS}}
        </agents>

        Guidelines for classification:

        Agent Type: Choose the most appropriate agent based on the nature of the query. For follow-up
        responses, use the same agent as the previous interaction.
        Confidence: Indicate how confident you are in the classification.
            High: Clear, straightforward requests or clear follow-ups
            Medium: Requests with some ambiguity but likely classification
            Low: Vague or multi-faceted requests that could fit multiple agents
            Report this as a number from 0 to 1 (High ≈ 0.9+, Medium ≈ 0.6–0.8, Low ≈ below 0.6).

        Handle variations in user input, including different phrasings, synonyms, and potential
        spelling errors. For short responses like "yes", "ok", "I want to know more", or numerical
        answers, treat them as follow-ups and maintain the previous agent selection.

        Examples:

        1. Initial query with no context:
        User: "What are the symptoms of the flu?"
        → call select_agent with the health agent's id, confidence 0.95

        2. Context switch between agents:
        User: "How do I set up a wireless printer?"
        Assistant: [tech-agent]: To set up a wireless printer, follow these steps: ...
        User: "Actually, I need to know about my account balance"
        → call select_agent with the billing agent's id, confidence 0.9

        3. Follow-up for the same agent:
        User: "What's the best way to lose weight?"
        Assistant: [health-agent]: The best way to lose weight typically involves ...
        User: "Yes, please give me some diet tips"
        → call select_agent with the health agent's id, confidence 0.95

        4. Multiple context switches with a final follow-up:
        User: "How much does your premium plan cost?"
        Assistant: [sales-agent]: Our premium plan is priced at ...
        User: "I'm having trouble accessing my account"
        Assistant: [support-agent]: I'm sorry to hear you're having trouble accessing your account ...
        User: "It says my password is incorrect, but I'm sure it's right"
        → call select_agent with the support agent's id, confidence 0.9

        Always respond by calling `select_agent` with the chosen agent's id and a confidence from 0 to
        1. If no agent is a good fit, pick the closest match with low confidence.
        """
}
