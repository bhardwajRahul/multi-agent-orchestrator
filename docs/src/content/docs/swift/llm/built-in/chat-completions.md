---
title: ChatCompletionsClient
description: The built-in LLMClient for OpenAI and any OpenAI-compatible chat-completions endpoint, with streaming, structured output, and retry support.
---

`ChatCompletionsClient` implements [`LLMClient`](/agent-squad/swift/llm/overview/) for any provider that speaks the OpenAI chat-completions SSE format: OpenAI, Azure OpenAI, OpenRouter, Together AI, Groq, Fireworks, Ollama, llama.cpp, LiteLLM, and others. Switch providers by changing `baseURL`.

## Initialiser

```swift
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
)
```

The client appends `/chat/completions` to `baseURL` automatically.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `baseURL` | `https://api.openai.com/v1` | Override for any compatible provider |
| `model` | — | Required; provider model identifier |
| `apiKey` | `nil` | Sent as `Authorization: Bearer <key>` |
| `headers` | `[:]` | Merged after the built-in headers; use for provider-specific auth (e.g. `api-key` on Azure) |
| `responseFormat` | `.text` | See [ResponseFormat](/agent-squad/swift/llm/overview/#responseformat) |
| `extraBody` | `[:]` | Arbitrary top-level body keys (`temperature`, `max_tokens`, `seed`, …); applied last, can override defaults |
| `maxRetries` | `2` | Retries only before the first streamed event, and only for `URLError`, `429`, or `5xx` |
| `retryDelay` | `250 ms` | Linear backoff — delay × attempt number |
| `transport` | `URLSessionEventStream()` | See [Custom transport](/agent-squad/swift/llm/custom/#custom-transport) |

## Quick start

```swift
let llm = ChatCompletionsClient(
    model: "gpt-4o-mini",
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
)
```

## Switching providers

Change `baseURL` to point at any OpenAI-compatible endpoint:

```swift
// Groq
let groq = ChatCompletionsClient(
    baseURL: URL(string: "https://api.groq.com/openai/v1")!,
    model: "llama3-8b-8192",
    apiKey: groqKey
)

// Local Ollama
let local = ChatCompletionsClient(
    baseURL: URL(string: "http://localhost:11434/v1")!,
    model: "llama3.2"
    // no apiKey needed
)
```

## Extra body parameters

Pass provider-specific or model-tuning parameters through `extraBody`:

```swift
let llm = ChatCompletionsClient(
    model: "gpt-4o",
    apiKey: key,
    extraBody: [
        "temperature": .number(0.2),
        "max_tokens": .number(1024),
        "seed": .number(42),
    ]
)
```

`extraBody` keys are applied after the built-in keys, so they can override anything — including `stream_options` if a provider rejects it.

## Structured output

Set `responseFormat` to request JSON or schema-constrained output:

```swift
let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "answer": .object(["type": .string("string")]),
        "confidence": .object(["type": .string("number")]),
    ]),
    "required": .array([.string("answer"), .string("confidence")]),
])

let llm = ChatCompletionsClient(
    model: "gpt-4o-mini",
    apiKey: key,
    responseFormat: .jsonSchema(name: "answer_with_confidence", schema: schema)
)
```

See [`ResponseFormat`](/agent-squad/swift/llm/overview/#responseformat) on the overview page for the full enum definition.

:::caution
Not all providers support `.jsonSchema`. Fall back to `.json` and parse manually when targeting Ollama or older API gateways.
:::

## ChatCompletionsError

```swift
public enum ChatCompletionsError: Error, Equatable {
    case httpStatus(Int, body: String?)
    case nonHTTPResponse
    case emptyStream
}
```

- `.httpStatus` — the provider returned a non-2xx status. `body` contains up to 2 048 bytes of the response for diagnostics.
- `.nonHTTPResponse` — `URLSession` returned a non-HTTP response (should not occur in practice).
- `.emptyStream` — a `200` whose SSE stream carried nothing parseable; typically a provider error envelope or an HTML gateway page. Not retried.

:::note
The retry policy (`maxRetries`, `retryDelay`) only fires before the first emitted event. Once the consumer has received a `.textDelta`, a failure surfaces immediately as a thrown error rather than being retried.
:::

## ChatCompletionsTransport

The `transport` parameter is the HTTP seam. The default `URLSessionEventStream` suffices for production use:

```swift
public struct URLSessionEventStream: ChatCompletionsTransport {
    public init(timeout: TimeInterval = 60)
}
```

`timeout` is the **idle timeout** — the maximum gap between incoming bytes. It is not a total-duration cap, so long responses are not cut off.

To replace the HTTP layer for test mocks, custom `URLSession` configurations, or an alternative networking stack, implement `ChatCompletionsTransport`. See [Custom transport](/agent-squad/swift/llm/custom/#custom-transport) for a worked example.

## Related

- [LLM clients overview](/agent-squad/swift/llm/overview/) — protocol, event types, and stream consumption
- [Custom LLM connector or transport](/agent-squad/swift/llm/custom/)
- [Agents overview](/agent-squad/swift/agents/overview/) — how `Agent` and `GroundedAgent` drive the tool loop
