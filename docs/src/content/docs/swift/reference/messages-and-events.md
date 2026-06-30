---
title: Messages & events
description: Complete reference for ConversationMessage, ContentPart, Role, AgentInput, AgentEvent, AgentContext, and JSONValue — the core value types that flow through every agent turn.
---

Every turn moves three kinds of data: what the user sent (`AgentInput`), the conversation history (`[ConversationMessage]`), and the stream of events an agent returns (`AsyncThrowingStream<AgentEvent, any Error>`). This page documents those types in full.

---

## Role

```swift
public enum Role: String, Sendable, Codable, Hashable {
    case user
    case assistant
    case system
    case tool
}
```

Used on every `ConversationMessage`. `.tool` marks messages that carry tool results back to the model.

---

## ContentPart

A message is a bag of heterogeneous parts rather than a plain string.

```swift
public enum ContentPart: Sendable, Codable, Hashable {
    case text(String)
    case toolCall(id: String, name: String, arguments: JSONValue)
    case toolResult(id: String, content: JSONValue)
    case audioTranscript(String)
    case widget(UIPayload)
}
```

| Case | When present |
|------|-------------|
| `.text` | Normal prose from user or assistant |
| `.toolCall` | The model requested a tool; `id` ties it to its result |
| `.toolResult` | Result returned to the model after execution |
| `.audioTranscript` | STT transcript attached to a voice turn |
| `.widget` | Structured UI payload — never forwarded to the model |

:::caution[Persistence stability]
The JSON keys are the case name plus its associated-value label names. Renaming a case or a labeled parameter breaks stored history. Reordering associated values is safe.
:::

---

## ConversationMessage

```swift
public struct ConversationMessage: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let role: Role
    public let parts: [ContentPart]
    public let timestamp: Date
}
```

**Initializers**

```swift
// Parts-based
ConversationMessage(
    id: String = UUID().uuidString,
    role: Role,
    parts: [ContentPart],
    timestamp: Date = Date()
)

// Convenience: single text part
ConversationMessage(
    id: String = UUID().uuidString,
    role: Role,
    text: String,
    timestamp: Date = Date()
)
```

**Computed property**

```swift
public var text: String
```

Joins all `.text` parts in order; returns `""` when none are present.

**Example**

```swift
let msg = ConversationMessage(role: .user, text: "What are the live odds?")
print(msg.text) // "What are the live odds?"

let mixed = ConversationMessage(role: .assistant, parts: [
    .text("The odds are "),
    .toolCall(id: "c1", name: "getOdds", arguments: ["eventId": 42]),
    .text(".")
])
print(mixed.text) // "The odds are ."  — only text parts
```

Messages are immutable. Streamed deltas are accumulated by the orchestrator and delivered as a single `.final(ConversationMessage)` event at the end of a turn.

---

## AgentInput

The input side of a turn. Currently text-only; continuous audio is handled by `VoiceAssistant`.

```swift
public enum AgentInput: Sendable {
    case text(String)

    public var text: String
}
```

```swift
let input = AgentInput.text("Show me today's matches")
print(input.text) // "Show me today's matches"
```

See [Agents](/agent-squad/swift/agents/overview/) for how `AgentProtocol.process(_:history:context:)` receives this.

---

## AgentEvent

The `AsyncThrowingStream` that `AgentProtocol.process` returns emits these cases:

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

| Case | Meaning |
|------|---------|
| `.thinking` | Extended-thinking scratchpad text (model reasoning, not shown to users by default) |
| `.textDelta` | Incremental text chunk — append to a string buffer to build the response |
| `.toolCall` | Observability notification that the agent is calling a tool; the result is recorded on the trace span, not re-emitted as an event |
| `.widget` | Structured UI payload forwarded from a tool when `UIPolicy` is `.forward` |
| `.final` | The fully-assembled `ConversationMessage` at the end of the turn, including all parts |
| `.error` | User-facing error string (e.g. "network unavailable"); hard failures are *thrown* through the stream instead |

**Consuming the stream**

```swift
let stream = agent.process(.text("Hello"), history: [], context: ctx)

var buffer = ""
for try await event in stream {
    switch event {
    case .textDelta(let chunk):
        buffer += chunk
    case .final(let message):
        print("Turn complete:", message.text)
    case .error(let msg):
        print("Agent error:", msg)
    default:
        break
    }
}
```

:::note[`.error` vs thrown errors]
`.error` carries soft, user-displayable messages. Network failures, decoding errors, and other hard faults are thrown as `Error` values through the `AsyncThrowingStream` — always wrap iteration in `do/catch`.
:::

For widget rendering, see [UI overview](/agent-squad/swift/ui/overview/). For tracing `.toolCall` spans, see [Tracing overview](/agent-squad/swift/tracing/overview/).

---

## AgentContext

Passed alongside every `process` call; carries per-turn identity and an optional live trace span.

```swift
public struct AgentContext: Sendable {
    public let userId: String
    public let sessionId: String
    public let params: [String: JSONValue]
    public let span: (any SpanHandle)?
}
```

```swift
AgentContext(
    userId: String,
    sessionId: String,
    params: [String: JSONValue] = [:],
    span: (any SpanHandle)? = nil
)
```

`params` is the escape hatch for request-scoped data (locale, feature flags, A/B variants) that agents need but that does not belong in the message history. See [Tracing overview](/agent-squad/swift/tracing/overview/) for `SpanHandle` usage.

---

## JSONValue

Schema-less JSON used for tool arguments, tool results, `AgentContext.params`, and trace payloads.

```swift
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```

`JSONValue` is `Codable` and conforms to all relevant `ExpressibleBy*Literal` protocols, so you can build values inline without explicit case syntax:

```swift
let args: JSONValue = [
    "eventId": 42,
    "live": true,
    "market": "1X2",
    "minOdds": 1.5
]
```

**Number gotchas**

- Whole-number doubles decode to `.int`: JSON `1.0` becomes `.int(1)`, not `.double(1.0)`.
- Integer IDs larger than `Int.max` lose precision as `.double`. Carry them as `.string` instead.
- `.double` values must be finite; `NaN` and `±Inf` are not valid JSON and will cause encoding to fail.

:::caution[Large IDs]
If a backend sends numeric IDs that exceed Swift's `Int` range (common with 64-bit identifiers on 32-bit targets), decode them as `.string` on the producing side or you will silently lose precision.
:::

---

## See also

- [Agents overview](/agent-squad/swift/agents/overview/) — how `AgentProtocol` consumes these types
- [Orchestrator overview](/agent-squad/swift/orchestrator/overview/) — how history is assembled and routed between agents
- [Storage overview](/agent-squad/swift/storage/overview/) — how `ConversationMessage` is persisted
- [UI overview](/agent-squad/swift/ui/overview/) — `UIPayload` and `UIPolicy`
- [Tracing overview](/agent-squad/swift/tracing/overview/) — attaching spans to `AgentContext`
