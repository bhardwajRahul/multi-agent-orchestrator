import Foundation

/// An `LLMClient` for the OpenAI chat-completions wire format (OpenAI, Azure, OpenRouter, Together, Groq, Fireworks, Ollama/llama.cpp, LiteLLM); pick a provider via `baseURL`.
///
/// `responseFormat` is first-class; other body params (`temperature`, `max_tokens`, `seed`, extras) ride `extraBody`. Retries fire only before the first streamed event, and only for connection failures/timeouts/`429`/`5xx`.
public struct ChatCompletionsClient: LLMClient {
    private let endpoint: URL
    private let model: String
    private let apiKey: String?
    private let headers: [String: String]
    private let responseFormat: ResponseFormat
    private let extraBody: [String: JSONValue]
    private let maxRetries: Int
    private let retryDelay: Duration
    private let transport: any ChatCompletionsTransport

    public init(
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        model: String,
        apiKey: String? = nil,
        headers: [String: String] = [:],
        responseFormat: ResponseFormat = .text,
        extraBody: [String: JSONValue] = [:],
        maxRetries: Int = 2,
        retryDelay: Duration = .milliseconds(250),
        transport: any ChatCompletionsTransport = URLSessionEventStream()
    ) {
        self.endpoint = baseURL.appending(path: "chat/completions")
        self.model = model
        self.apiKey = apiKey
        self.headers = headers
        self.responseFormat = responseFormat
        self.extraBody = extraBody
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.transport = transport
    }

    public func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await run(request, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Turn

    private func run(_ request: LLMRequest, into continuation: AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation) async {
        let urlRequest: URLRequest
        do { urlRequest = try buildRequest(request) }
        catch { continuation.finish(throwing: error); return }

        var attempt = 0
        while true {
            var emittedAny = false
            do {
                try await streamOnce(urlRequest, emit: { event in
                    emittedAny = true
                    continuation.yield(event)
                })
                continuation.finish()
                return
            } catch {
                // Retry only before anything reached the consumer (can't un-emit).
                if !emittedAny, attempt < maxRetries, !Task.isCancelled, Self.isRetryable(error) {
                    attempt += 1
                    // linear backoff
                    do { try await Task.sleep(for: retryDelay * attempt) }
                    catch { continuation.finish(throwing: error); return }   // cancelled
                    continue
                }
                continuation.finish(throwing: error)
                return
            }
        }
    }

    /// One attempt: parse SSE chunks, emit text deltas live, accumulate tool calls by index, then emit them and `.done`.
    private func streamOnce(_ urlRequest: URLRequest, emit: (LLMStreamEvent) -> Void) async throws {
        let lines = try await transport.stream(urlRequest)
        let decoder = JSONDecoder()
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finish: FinishReason?
        var usage: LLMUsage?
        var sawContent = false

        for try await line in lines {
            guard let payload = ChatCompletionsWire.ssePayload(line) else { continue }
            if payload == "[DONE]" { break }
            guard let chunk = try? decoder.decode(ChatCompletionsWire.Chunk.self, from: Data(payload.utf8)) else { continue }

            if let choice = chunk.choices?.first {
                if let content = choice.delta?.content, !content.isEmpty {
                    sawContent = true
                    emit(.textDelta(content))
                }
                for delta in choice.delta?.toolCalls ?? [] {
                    let index = delta.index ?? 0   // a missing index means a single call
                    var call = toolCalls[index] ?? (id: "", name: "", arguments: "")
                    if let id = delta.id { call.id = id }
                    if let name = delta.function?.name { call.name = name }
                    if let arguments = delta.function?.arguments { call.arguments += arguments }
                    toolCalls[index] = call
                }
                if let reason = ChatCompletionsWire.finishReason(choice.finishReason) { finish = reason }
            }
            if let reported = chunk.usage {
                usage = LLMUsage(promptTokens: reported.promptTokens, completionTokens: reported.completionTokens)
            }
        }

        // A 200 that streamed nothing parseable (provider error envelope, HTML gateway page) would become a silent empty `.done`; surface it instead.
        if !sawContent, toolCalls.isEmpty, finish == nil, usage == nil {
            throw ChatCompletionsError.emptyStream
        }

        for index in toolCalls.keys.sorted() {
            let call = toolCalls[index]!
            emit(.toolCall(id: call.id, name: call.name, arguments: ChatCompletionsWire.parseArguments(call.arguments)))
        }
        // Always terminate, even if the stream ended without [DONE] or a finish_reason.
        emit(.done(reason: finish ?? (toolCalls.isEmpty ? .stop : .toolCalls), usage: usage))
    }

    private func buildRequest(_ request: LLMRequest) throws -> URLRequest {
        let body = ChatCompletionsWire.requestBody(for: request, model: model, responseFormat: responseFormat, extraBody: extraBody)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (field, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        return urlRequest
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if case ChatCompletionsError.httpStatus(let code, _) = error {
            return code == 429 || (500...599).contains(code)
        }
        return error is URLError   // connection refused, DNS, TLS, timeout, dropped mid-handshake
    }
}

/// Reply format. `.text` sends no `response_format` (prose); `.json`/`.jsonSchema` request structured output.
public enum ResponseFormat: Sendable, Equatable {
    case text
    case json
    case jsonSchema(name: String, schema: JSONValue, strict: Bool = true)

    /// The `response_format` body value, or `nil` to omit it.
    var payload: JSONValue? {
        switch self {
        case .text:
            return nil
        case .json:
            return .object(["type": .string("json_object")])
        case .jsonSchema(let name, let schema, let strict):
            return .object([
                "type": .string("json_schema"),
                "json_schema": .object(["name": .string(name), "schema": schema, "strict": .bool(strict)]),
            ])
        }
    }
}

public enum ChatCompletionsError: Error, Equatable {
    case httpStatus(Int, body: String?)
    case nonHTTPResponse
    /// A 200 whose stream carried nothing parseable; usually a provider error/HTML body. Not retried.
    case emptyStream
}
