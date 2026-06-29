---
title: Custom LLM clients
description: Write a custom LLMClient for non-OpenAI backends, or a custom ChatCompletionsTransport for mocks and alternative HTTP layers.
---

Two extension points exist depending on how much you need to change:

| Scenario | Use |
|----------|-----|
| Non-OpenAI wire format (Anthropic Messages API, on-device Core ML, proprietary backend) | Implement `LLMClient` directly |
| OpenAI-compatible wire format, but custom HTTP (mTLS, proxy, test mock) | Implement `ChatCompletionsTransport` |

See [LLM clients overview](/agent-squad/swift/llm/overview/) for the protocol definitions, and [ChatCompletionsClient](/agent-squad/swift/llm/built-in/chat-completions/) for the built-in implementation.

## Writing a custom LLM connector

Use this when your backend does **not** speak the OpenAI chat-completions wire format. You implement `LLMClient` directly rather than plugging a `ChatCompletionsTransport` into `ChatCompletionsClient`.

The only requirement is the single streaming method:

```swift
public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}
```

### Anatomy of the conversion

Your implementation needs to do three things:

1. **Map `LLMRequest` → provider request** — convert `request.messages` (`[ConversationMessage]`), `request.system`, and `request.tools` into whatever your provider expects.
2. **Drive an `AsyncThrowingStream`** — open a connection, forward provider events as `.textDelta` / `.toolCall` / `.done`, and finish or fail the continuation.
3. **Translate `FinishReason`** — map the provider's stop-reason vocabulary onto `FinishReason`.

### Minimal skeleton

```swift
import Foundation
import AgentSquad

struct MyBackendClient: LLMClient {
    let session: URLSession
    let apiKey: String
    let model: String

    // LLMClient has a single requirement; return type is inferred.
    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1. Build your provider request body.
                    let body = try buildRequestBody(request)
                    var urlRequest = URLRequest(url: URL(string: "https://your.backend/v1/stream")!)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONEncoder().encode(body)

                    // 2. Stream bytes and parse provider events.
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }

                    var usage: LLMUsage? = nil
                    for try await line in bytes.lines {
                        guard let event = parseProviderLine(line) else { continue }
                        switch event {
                        case .text(let delta):
                            continuation.yield(.textDelta(delta))
                        case .toolCall(let id, let name, let args):
                            // args must be JSONValue — decode from the provider's JSON.
                            continuation.yield(.toolCall(id: id, name: name, arguments: args))
                        case .finished(let reason, let promptTokens, let completionTokens):
                            usage = LLMUsage(
                                promptTokens: promptTokens,
                                completionTokens: completionTokens
                            )
                            // 3. Translate provider stop-reason to FinishReason.
                            let finishReason: FinishReason
                            switch reason {
                            case "end_turn":    finishReason = .stop
                            case "tool_use":    finishReason = .toolCalls
                            case "max_tokens":  finishReason = .length
                            default:            finishReason = .other(reason)
                            }
                            continuation.yield(.done(reason: finishReason, usage: usage))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancel the in-flight request if the caller drops the stream.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

The stubs `buildRequestBody(_:)` and `parseProviderLine(_:)` are where you put provider-specific serialisation; they are intentionally omitted here because their shape depends entirely on your backend's schema.

### Mapping ConversationMessage to your provider's format

`ConversationMessage.parts` is `[ContentPart]`. Switch on each part to build the provider message array:

```swift
for message in request.messages {
    for part in message.parts {
        switch part {
        case .text(let string):
            // plain text turn
        case .toolCall(let id, let name, let arguments):
            // model requested a tool — forward as an assistant tool-use block
        case .toolResult(let id, let content):
            // result returned to the model — forward as a tool result block
        case .audioTranscript(let transcript):
            // treat as text or skip if your provider doesn't support audio
        case .widget:
            break  // UI-only; skip in the LLM request
        }
    }
}
```

### Using the connector with an Agent

```swift
let connector = MyBackendClient(
    session: .shared,
    apiKey: ProcessInfo.processInfo.environment["MY_BACKEND_KEY"] ?? "",
    model: "my-model-v1"
)

let agent = Agent(
    name: "assistant",
    description: "General assistant backed by MyBackend",
    llmClient: connector
)
```

The `Agent` tool loop, retry semantics, and tracing all work unchanged — they depend only on the `LLMClient` protocol, not on `ChatCompletionsClient`.

:::note
If your provider supports OpenAI-compatible `/chat/completions` but you need a non-standard HTTP layer (mutual TLS, custom proxy, test mocks), prefer implementing `ChatCompletionsTransport` instead — it is less code and you get retry logic for free. See [Custom transport](#custom-transport) below.
:::

## Custom transport

`ChatCompletionsTransport` lets you replace the HTTP layer inside `ChatCompletionsClient` — useful for test mocks, custom `URLSession` configurations, or an alternative networking stack. Use this when the wire format is fine but the network layer is not.

```swift
public protocol ChatCompletionsTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<String, any Error>
}
```

The transport receives a fully built `URLRequest` (headers, body, method already set) and must yield raw body lines. It should throw `ChatCompletionsError.httpStatus` on non-2xx to trigger the retry logic in `ChatCompletionsClient`.

### Example: mock transport for tests

```swift
struct MockTransport: ChatCompletionsTransport {
    let lines: [String]

    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

let mock = MockTransport(lines: [
    #"data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#,
    #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
    "data: [DONE]",
])

let client = ChatCompletionsClient(
    model: "gpt-4o-mini",
    transport: mock
)
```

:::note
The retry policy (`maxRetries`, `retryDelay`) only fires before the first emitted event. Once the consumer has received a `.textDelta`, a failure surfaces immediately as a thrown error rather than being retried.
:::

## Related

- [LLM clients overview](/agent-squad/swift/llm/overview/) — protocol, event types, and stream consumption
- [ChatCompletionsClient](/agent-squad/swift/llm/built-in/chat-completions/) — built-in implementation and all init parameters
- [Agents overview](/agent-squad/swift/agents/overview/) — how the tool loop uses `LLMClient`
- [Extending AgentSquad](/agent-squad/swift/guides/extending/)
