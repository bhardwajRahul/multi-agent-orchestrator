import Foundation

/// Pure wire mapping for the OpenAI chat-completions API: `LLMRequest` → request JSON, SSE chunks → the pieces the client emits. Kept separate so it's unit-testable.
enum ChatCompletionsWire {
    // MARK: - Request

    /// Build the body as a `JSONValue` object so `extraBody`/`response_format` merge in as plain keys without modelling the whole schema.
    static func requestBody(
        for request: LLMRequest,
        model: String,
        responseFormat: ResponseFormat,
        extraBody: [String: JSONValue]
    ) -> JSONValue {
        var messages: [JSONValue] = []
        if let system = request.system {
            messages.append(.object(["role": .string("system"), "content": .string(system)]))
        }
        for message in request.messages {
            messages.append(contentsOf: openAIMessages(message))
        }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(messages),
            "stream": .bool(true),
            // Usage reporting rides this; a few providers (some Ollama/llama.cpp builds) reject unknown body keys. `extraBody` can override but not remove it.
            "stream_options": .object(["include_usage": .bool(true)]),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(toolSchema))
        }
        if let format = responseFormat.payload {
            body["response_format"] = format
        }
        // applied last so callers can override defaults
        for (key, value) in extraBody { body[key] = value }
        return .object(body)
    }

    /// One of our messages to OpenAI messages: a tool-result message becomes one `role:"tool"` per result, else a single text/`tool_calls` message.
    private static func openAIMessages(_ message: ConversationMessage) -> [JSONValue] {
        var text = ""
        var toolCalls: [JSONValue] = []
        var toolResults: [JSONValue] = []
        for part in message.parts {
            switch part {
            case .text(let value):
                text += value
            case .toolCall(let id, let name, let arguments):
                toolCalls.append(.object([
                    "id": .string(id),
                    "type": .string("function"),
                    "function": .object(["name": .string(name), "arguments": .string(jsonString(arguments))]),
                ]))
            case .toolResult(let id, let content):
                toolResults.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(id),
                    "content": .string(toolContent(content)),
                ]))
            case .audioTranscript, .widget:
                break   // not model-facing
            }
        }
        // Tool results get their own `role:"tool"` messages; the `Agent` never co-locates text/tool_calls on a result message.
        if !toolResults.isEmpty { return toolResults }

        var openAI: [String: JSONValue] = ["role": .string(message.role.rawValue)]
        if toolCalls.isEmpty {
            openAI["content"] = .string(text)
        } else {
            openAI["tool_calls"] = .array(toolCalls)
            openAI["content"] = text.isEmpty ? .null : .string(text)   // content may be null alongside tool_calls
        }
        return [.object(openAI)]
    }

    private static func toolSchema(_ tool: AgentTool) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
            ]),
        ])
    }

    /// `JSONValue` as a compact JSON string; OpenAI carries `function.arguments` as a string.
    static func jsonString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func toolContent(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return jsonString(value)
    }

    // MARK: - Streamed response

    /// One SSE chunk. Only the fields we consume are decoded.
    struct Chunk: Decodable {
        let choices: [Choice]?
        let usage: Usage?

        struct Choice: Decodable {
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
        }
        struct Delta: Decodable {
            let content: String?
            let toolCalls: [ToolCallDelta]?
            enum CodingKeys: String, CodingKey { case content; case toolCalls = "tool_calls" }
        }
        struct ToolCallDelta: Decodable {
            // Some providers (Gemini-compat, a few gateways) omit it; a missing index means a single call (→ 0).
            let index: Int?
            let id: String?
            let function: Function?
            struct Function: Decodable { let name: String?; let arguments: String? }
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            enum CodingKeys: String, CodingKey { case promptTokens = "prompt_tokens"; case completionTokens = "completion_tokens" }
        }
    }

    /// JSON payload of an SSE `data:` line, else `nil`. Trims whitespace/newlines so a CRLF stream's trailing `\r` doesn't hide `[DONE]` or ride inside the JSON.
    static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func finishReason(_ raw: String?) -> FinishReason? {
        switch raw {
        case nil: return nil
        case "stop": return .stop
        case "tool_calls": return .toolCalls
        case "length": return .length
        case "content_filter": return .contentFilter
        case let other?: return .other(other)
        }
    }

    /// Parse an accumulated `function.arguments` string into a `JSONValue` (empty → `{}`).
    static func parseArguments(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return .object([:])
        }
        return value
    }
}
