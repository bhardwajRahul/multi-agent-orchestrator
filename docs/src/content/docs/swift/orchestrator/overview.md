---
title: Orchestrator
description: The turn-based runtime that classifies input, fetches history, dispatches to an agent, and persists the result.
---

`Orchestrator` drives one complete turn: select an agent → fetch per-agent history → stream the agent's events → persist the exchange. It is a `Sendable` value type — create one at app start and share it freely.

## Initialiser

```swift
public init(
    agents: [any AgentProtocol],
    classifier: (any Classifier)? = nil,
    store: any ChatStorage,
    tracer: any Tracer = OSLogTracer(),
    maxMessages: Int? = ChatStorageDefaults.maxMessages   // 100
)
```

| Parameter | Notes |
|-----------|-------|
| `agents` | Non-empty list. **Unique `id`s required** — on a duplicate the first occurrence wins and the later agent is unroutable. Enforced with a `precondition`. |
| `classifier` | Optional. When `nil`, all turns route to the first agent with no extra model call. |
| `store` | Persistence for history. See [Storage](/agent-squad/swift/storage/overview/). |
| `tracer` | Defaults to `OSLogTracer`. Swap in any `Tracer` implementation. See [Tracing](/agent-squad/swift/tracing/overview/). |
| `maxMessages` | History window — counts individual messages, not pairs. Default `100` (≈ 50 user/assistant pairs). `nil` keeps everything. |

:::caution
`agents` must be non-empty. Passing an empty array triggers a `precondition` failure at runtime.
:::

The first agent in `agents` is the **default agent**. It is the sole target when `classifier == nil` and the fallback when the classifier returns no selection.

## Routing a turn

```swift
public func route(
    _ input: AgentInput,
    userId: String,
    sessionId: String
) -> AsyncThrowingStream<AgentEvent, any Error>
```

Returns an `AsyncThrowingStream` immediately; work starts when you iterate it. Cancelling the `for await` loop cancels the underlying `Task`.

```swift
let stream = orchestrator.route(.text("What is the weather in Paris?"),
                                userId: "u-42",
                                sessionId: "s-99")

for try await event in stream {
    switch event {
    case .textDelta(let chunk):  print(chunk, terminator: "")
    case .final(let message):    print("\nDone:", message.text)
    case .error(let msg):        print("Error:", msg)
    default: break
    }
}
```

See [Messages & events](/agent-squad/swift/reference/messages-and-events/) for the full `AgentEvent` enum.

## What happens inside a turn

```
route(_:userId:sessionId:)
  └─ selectAgent          → classifier?.classify or defaultAgent
  └─ store.fetch          → per-agent history (trimmed to maxMessages)
  └─ agent.process        → AsyncThrowingStream<AgentEvent>
       ├─ .thinking / .textDelta / .toolCall / .widget  (forwarded)
       └─ .final(message)
  └─ store.saveMessages   → [userMessage, finalMessage]  (only on .final)
```

Every turn is wrapped in a root trace span (`chat.turn`), with a child span per agent invocation. Persist failures after a successful `.final` are recorded on the trace but do **not** emit an additional `.error` to the caller — the user already received their answer.

### Single-agent mode

Pass one agent and omit `classifier`. No classifier model call is made; `store.fetchAllChats` is never called. All turns go to that agent.

```swift
let orchestrator = Orchestrator(
    agents: [myAgent],
    store: DeviceChatStorage()
)
```

### Multi-agent routing

Pass a `classifier` alongside two or more agents. Each turn calls `classifier.classify(_:history:agents:)` against the merged cross-agent history. The classifier returns a `selectedAgent` or `nil`; `nil` falls back to the first agent.

```swift
let orchestrator = Orchestrator(
    agents: [supportAgent, billingAgent, defaultAgent],
    classifier: AnthropicClassifier(client: client),
    store: DeviceChatStorage()
)
```

See [Classifiers](/agent-squad/swift/classifiers/overview/) for classifier options and custom implementations.

## History window

`maxMessages` is applied twice per turn:

1. **Fetch** — `store.fetch` returns at most `maxMessages` messages for the selected agent.
2. **Save** — `store.saveMessages` trims the stored history to `maxMessages` after appending.

The window counts messages (not pairs). The default of `100` means up to 50 user/assistant pairs. History trimming always rounds down to an even count so a pair is never split.

Pass `maxMessages: nil` to keep unbounded history.

:::note
The classifier always receives the **full** merged history (`store.fetchAllChats`) — the `maxMessages` window is intentionally not applied there. Classifiers need the cross-agent picture to route correctly.
:::

## Chat persistence and `saveChat`

Turns are persisted only when `agent.saveChat == true` (the default) and a `.final` event is received. If the agent stream ends without `.final` — for example, due to a mid-stream error — no messages are written, leaving no orphaned user message in storage.

Set `saveChat = false` on an agent to opt it out of persistence entirely (useful for ephemeral or stateless agents).

## Error handling

The stream never throws unexpectedly. Any error during agent execution is caught, recorded on the trace, and surfaced as a terminal `.error(String)` event with a user-facing message. Your `for try await` loop should still be wrapped in `do/catch` for transport-level failures, but application-layer errors always arrive as `.error`.

## Related

- [Agents](/agent-squad/swift/agents/overview/) — implement `AgentProtocol` to build a custom agent.
- [Classifiers](/agent-squad/swift/classifiers/overview/) — route across agents by intent.
- [Storage](/agent-squad/swift/storage/overview/) — `ChatStorage` protocol and built-in implementations.
- [Messages & events](/agent-squad/swift/reference/messages-and-events/) — `AgentInput`, `AgentEvent`, `ConversationMessage`.
- [Tracing](/agent-squad/swift/tracing/overview/) — span hierarchy and custom `Tracer` implementations.
