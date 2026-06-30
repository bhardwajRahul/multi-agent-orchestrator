---
title: LLM clients — Overview
description: The LLMClient protocol, LLMRequest, LLMStreamEvent, FinishReason, LLMUsage, and ResponseFormat that every agent and classifier builds on.
---

Every [Agent](/agent-squad/swift/agents/built-in/agent/), [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/), and [LLMClassifier](/agent-squad/swift/classifiers/built-in/llm-classifier/) accepts an `LLMClient`. The protocol is a single streaming method; swap the underlying model or provider without touching any orchestration code.

- Built-in: [ChatCompletionsClient](/agent-squad/swift/llm/built-in/chat-completions/) — works with OpenAI and any compatible endpoint.
- Custom: [Writing a custom LLM connector or transport](/agent-squad/swift/llm/custom/)

## LLMClient protocol

```swift
public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}
```

`complete` streams events for one turn. The caller iterates until `.done`, runs any requested tools, and re-invokes — the tool loop is handled for you inside `Agent` and `GroundedAgent`.

## LLMRequest

```swift
public struct LLMRequest: Sendable {
    public let system: String?
    public let messages: [ConversationMessage]
    public let tools: [AgentTool]

    public init(
        system: String? = nil,
        messages: [ConversationMessage],
        tools: [AgentTool] = []
    )
}
```

See [Messages & events](/agent-squad/swift/reference/messages-and-events/) for `ConversationMessage`, and [Tools](/agent-squad/swift/tools/overview/) for `AgentTool`.

## LLMStreamEvent

```swift
public enum LLMStreamEvent: Sendable {
    case textDelta(String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case done(reason: FinishReason, usage: LLMUsage?)
}
```

Events arrive in order: zero or more `.textDelta` and `.toolCall` events, then exactly one `.done`. Multiple `.toolCall` events may appear before `.done` when the model requests parallel calls.

### FinishReason

```swift
public enum FinishReason: Sendable, Equatable {
    case stop           // model finished its answer
    case toolCalls      // stopped to request tool calls
    case length         // truncated by token limit
    case contentFilter  // refused or filtered
    case other(String)  // provider-specific value
}
```

### LLMUsage

```swift
public struct LLMUsage: Sendable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
}
```

Usage is reported on `.done` when the provider includes it in the stream. See [Tracing](/agent-squad/swift/tracing/overview/) for how token counts surface in traces.

## ResponseFormat

`ResponseFormat` is defined alongside `ChatCompletionsClient` but applies to any client that supports structured output:

```swift
public enum ResponseFormat: Sendable, Equatable {
    case text
    case json
    case jsonSchema(name: String, schema: JSONValue, strict: Bool = true)
}
```

- `.text` — omits `response_format` from the request body (default prose output).
- `.json` — sends `{"type": "json_object"}`. The model returns valid JSON but no schema is enforced.
- `.jsonSchema(name:schema:strict:)` — sends `{"type": "json_schema", ...}` with your schema. `strict` defaults to `true`.

:::caution
Not all providers support `.jsonSchema`. Fall back to `.json` and parse manually when targeting Ollama or older API gateways.
:::

## Consuming the stream directly

If you need raw stream access outside an `Agent`, iterate `complete` yourself:

```swift
let request = LLMRequest(
    system: "You are a helpful assistant.",
    messages: [ConversationMessage(role: .user, parts: [.text("Hello")])]
)

for try await event in llm.complete(request) {
    switch event {
    case .textDelta(let text):
        print(text, terminator: "")
    case .toolCall(let id, let name, let arguments):
        print("\nTool call: \(name) [\(id)] args=\(arguments)")
    case .done(let reason, let usage):
        print("\nDone: \(reason), tokens: \(String(describing: usage))")
    }
}
```

## Next steps

- Use the built-in [ChatCompletionsClient](/agent-squad/swift/llm/built-in/chat-completions/) for OpenAI and compatible providers.
- [Write a custom connector or transport](/agent-squad/swift/llm/custom/) for non-OpenAI backends or test mocks.
