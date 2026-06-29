---
title: Custom Agents
description: How to implement AgentProtocol to build your own agent.
---

Any type that conforms to `AgentProtocol` is a first-class agent — the [Orchestrator](/agent-squad/swift/orchestrator/overview/) does not distinguish between custom and built-in agents. The protocol extension provides defaults for `id`, `saveChat`, and `maxToolRounds`, so a minimal implementation only needs `name`, `description`, and `process`.

For the full protocol definition and supporting types (`AgentInput`, `AgentContext`, `AgentEvent`) see the [Agents overview](/agent-squad/swift/agents/overview/).

## Minimal example: EchoAgent

```swift
struct EchoAgent: AgentProtocol {
    let name = "Echo"
    let description = "Repeats the input back."

    func process(
        _ input: AgentInput,
        history: [ConversationMessage],
        context: AgentContext
    ) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let text = input.text
            continuation.yield(.textDelta(text))
            continuation.yield(.final(ConversationMessage(role: .assistant, text: text)))
            continuation.finish()
        }
    }
}
```

Register it with the orchestrator exactly like a built-in [`Agent`](/agent-squad/swift/agents/built-in/agent/):

```swift
let orchestrator = Orchestrator(
    agents: [EchoAgent()],
    store: myChatStorage
)
```

## Overriding defaults

The protocol extension defaults are:

| Property | Default |
|---|---|
| `id` | `slugify(name)` |
| `saveChat` | `true` |
| `maxToolRounds` | `1` |

Override any of them by declaring the property on your type:

```swift
struct MyAgent: AgentProtocol {
    let name = "My Agent"
    let description = "Does something useful."
    let maxToolRounds = 10   // allow up to 10 tool-call iterations per turn
    let saveChat = false     // do not persist turns

    func process(/* … */) -> AsyncThrowingStream<AgentEvent, any Error> { /* … */ }
}
```

:::caution
A custom agent that uses tools **must** override `maxToolRounds` to a value greater than `1`; the default of `1` means the loop never iterates past the first model call. The built-in `Agent` already handles this — the caution applies only when you implement `AgentProtocol` directly.
:::

## Emitting events

Your `process` implementation should yield events in the order callers expect:

1. Zero or more `.thinking(String)` — extended reasoning tokens, if your model supports them.
2. One or more `.textDelta(String)` — incremental text chunks.
3. Zero or more `.toolCall(id:name:arguments:)` — tool announcements for observability.
4. Zero or more `.widget(UIPayload)` — structured UI payloads for the client.
5. Exactly one `.final(ConversationMessage)` — the completed turn; the orchestrator persists this when `saveChat` is `true`.

Throw an error into the stream to signal a hard failure. Yield `.error(String)` for a recoverable, user-visible message that should appear in the chat UI without terminating the stream.

## Using AgentContext

`AgentContext` carries `userId`, `sessionId`, arbitrary `params`, and an optional `span` for distributed tracing. Attach child spans to `context.span` so they appear nested under the orchestrator's session span:

```swift
func process(
    _ input: AgentInput,
    history: [ConversationMessage],
    context: AgentContext
) -> AsyncThrowingStream<AgentEvent, any Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let span = context.span?.span("my-agent.work", input: nil)
            // … do work …
            span?.end(output: nil, error: nil)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

See [Tracing](/agent-squad/swift/tracing/overview/) for the full span API.

## Related pages

- [Agents overview](/agent-squad/swift/agents/overview/) — protocol contract, `AgentInput`, `AgentContext`, `AgentEvent`.
- [Built-in Agent](/agent-squad/swift/agents/built-in/agent/) — the general-purpose `Agent` struct you can extend or delegate to.
- [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/) — the two-LLM anti-hallucination variant.
- [Tools](/agent-squad/swift/tools/overview/) — building a `ToolProvider` your custom agent can call.
- [Tracing](/agent-squad/swift/tracing/overview/) — attaching spans to `AgentContext`.
- [Guides: Extending AgentSquad](/agent-squad/swift/guides/extending/) — broader patterns for customisation.
