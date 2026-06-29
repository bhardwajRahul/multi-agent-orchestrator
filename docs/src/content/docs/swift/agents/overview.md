---
title: Agents Overview
description: The AgentProtocol contract, core types, and how the built-in agents relate.
---

Agents are the unit of work in AgentSquad. Each agent owns its LLM call and tool-use loop; the [Orchestrator](/agent-squad/swift/orchestrator/overview/) decides which agent handles a given turn and manages chat persistence.

## AgentProtocol

Every agent conforms to `AgentProtocol`:

```swift
public protocol AgentProtocol: Sendable {
    var id: String { get }           // storage namespace + classifier key; defaults to slugify(name)
    var name: String { get }
    var description: String { get }
    var saveChat: Bool { get }       // orchestrator persists turns; defaults to true
    var maxToolRounds: Int { get }   // tool-loop cap; defaults to 1

    func process(
        _ input: AgentInput,
        history: [ConversationMessage],
        context: AgentContext
    ) -> AsyncThrowingStream<AgentEvent, any Error>
}
```

The protocol extension provides default implementations for `id`, `saveChat`, and `maxToolRounds`, so a minimal custom agent only needs to implement `name`, `description`, and `process`.

| Property | Default | Notes |
|---|---|---|
| `id` | `slugify(name)` | Used as the storage namespace and classifier routing key. |
| `saveChat` | `true` | Set to `false` to opt the agent out of chat persistence. |
| `maxToolRounds` | `1` | Override to allow a tool-use loop. A tool-bearing agent that leaves this at `1` will never iterate past the first model call. |

## AgentInput

```swift
public enum AgentInput: Sendable {
    case text(String)
}
```

A convenience property surfaces the string without a pattern match:

```swift
let text = input.text   // "" when the case is not .text
```

:::note
`AgentInput` covers turn-based text only. Continuous audio is handled by `VoiceAssistant` and its `RealtimeEvent` stream — not by `AgentProtocol`.
:::

## AgentContext

Carries per-turn identity, arbitrary params, and the live trace span:

```swift
public struct AgentContext: Sendable {
    public let userId: String
    public let sessionId: String
    public let params: [String: JSONValue]
    public let span: (any SpanHandle)?

    public init(
        userId: String,
        sessionId: String,
        params: [String: JSONValue] = [:],
        span: (any SpanHandle)? = nil
    )
}
```

Child spans attached to `context.span` appear nested under the orchestrator's session span in your tracer. See [Tracing](/agent-squad/swift/tracing/overview/) for details.

## AgentEvent

The stream emitted by `process` yields these cases:

```swift
public enum AgentEvent: Sendable {
    case thinking(String)
    case textDelta(String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case widget(UIPayload)
    case final(ConversationMessage)
    case error(String)
}
```

| Case | Notes |
|---|---|
| `.textDelta` | Incremental text chunk; concatenate to build the full response. |
| `.toolCall` | Announced for observability; the tool result is recorded on the trace span, not re-emitted as an event. |
| `.widget` | A structured UI payload from a tool (see [UI](/agent-squad/swift/ui/overview/)). Only emitted when the agent's `UIPolicy` is `.forward`. |
| `.final` | The completed `ConversationMessage`; the orchestrator persists this when `saveChat` is `true`. |
| `.error` | A user-facing message (e.g. "network unavailable"). Real failures are thrown through the stream. |

:::caution
Do not conflate `.error` with thrown errors. `.error` is a displayable string for the chat UI; a thrown error terminates the stream and must be caught by the caller.
:::

## UIPolicy

Both built-in agents accept a `UIPolicy` parameter that controls whether tool-advertised UI payloads reach the caller:

```swift
public enum UIPolicy: Sendable {
    case forward    // emit .widget events (default)
    case suppress   // fold tool data into text; no .widget emitted
}
```

See [UI](/agent-squad/swift/ui/overview/) for how `UIPayload` is declared and consumed.

## Built-in agents

| Type | Description |
|---|---|
| [`Agent`](/agent-squad/swift/agents/built-in/agent/) | General-purpose: one `LLMClient` driving a tool-use loop. |
| [`GroundedAgent`](/agent-squad/swift/agents/built-in/grounded-agent/) | Two-LLM anti-hallucination pattern: a Brain gathers tool output; an isolated Presenter speaks only from that output. |

Both implement `AgentProtocol` and are interchangeable at the Orchestrator call site.

## Rolling your own

Conform to `AgentProtocol` and implement `process`. See [Custom Agents](/agent-squad/swift/agents/custom/) for a complete example and guidance on overriding `maxToolRounds`.

## Related pages

- [Orchestrator](/agent-squad/swift/orchestrator/overview/) — how agents are routed and chat is persisted.
- [Tools](/agent-squad/swift/tools/overview/) — building a `ToolProvider` and defining `AgentTool`s.
- [LLM clients](/agent-squad/swift/llm/overview/) — the `LLMClient` protocol and available implementations.
- [Messages & events](/agent-squad/swift/reference/messages-and-events/) — `ConversationMessage`, `ContentPart`, and the full event model.
- [Tracing](/agent-squad/swift/tracing/overview/) — attaching spans to `AgentContext`.
- [UI](/agent-squad/swift/ui/overview/) — `UIPayload` and how `.widget` events are consumed.
- [Voice](/agent-squad/swift/voice/overview/) — the voice path that sits outside `AgentProtocol`.
