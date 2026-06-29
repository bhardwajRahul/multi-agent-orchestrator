---
title: Agent
description: The general-purpose built-in agent — one LLMClient driving an internal tool-use loop.
---

`Agent` is the framework's general-purpose implementation of [`AgentProtocol`](/agent-squad/swift/agents/overview/): one `LLMClient` calls the model, runs tool calls through a `ToolProvider`, and streams `AgentEvent`s back to the caller. Storage is the orchestrator's concern — `Agent` takes `history` in and streams events out.

## Initializers

### Default system prompt

Generated from `name` and `description` using `Agent.defaultSystemPrompt(name:description:)`:

```swift
public init(
    name: String,
    description: String = "",
    model: any LLMClient,
    tools: (any ToolProvider)? = nil,
    ui: UIPolicy = .forward,
    maxToolRounds: Int = 20,
    saveChat: Bool = true
)
```

### Custom or absent system prompt

```swift
public init(
    name: String,
    description: String = "",
    model: any LLMClient,
    tools: (any ToolProvider)? = nil,
    systemPrompt: String?,           // your own string, or nil for no system message
    ui: UIPolicy = .forward,
    maxToolRounds: Int = 20,
    saveChat: Bool = true
)
```

Pass `systemPrompt: nil` to send no system message at all. This initializer never falls back to the default prompt.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `name` | — | Human-readable label; also drives the default system prompt and `id`. |
| `description` | `""` | Included in the default system prompt and the classifier's agent list. |
| `model` | — | Any [LLM client](/agent-squad/swift/llm/overview/). |
| `tools` | `nil` | Any `ToolProvider`: native Swift tools, [MCP](/agent-squad/swift/mcp/overview/), or a mix. |
| `systemPrompt` | *(generated)* | Override the auto-generated prompt or suppress it entirely with `nil`. |
| `ui` | `.forward` | `.forward` emits `.widget` events; `.suppress` folds UI data into text. |
| `maxToolRounds` | `20` | Cap on model calls per turn when tools are present. See below. |
| `saveChat` | `true` | When `false`, the orchestrator does not persist this agent's turns. |

## UIPolicy

```swift
public enum UIPolicy: Sendable {
    case forward    // emit .widget events (default)
    case suppress   // fold tool data into text; no .widget emitted
}
```

See [UI](/agent-squad/swift/ui/overview/) for how `UIPayload` is declared and consumed downstream.

## Tool-round cap

`maxToolRounds` caps model calls per turn. The effective cap is computed as:

```swift
public var maxToolRounds: Int { tools == nil ? 1 : toolRoundCap }
```

With no tools the cap is always `1`, regardless of what was passed at init. A turn that hits the cap leaves remaining tool requests un-run and may emit an empty `.final`.

:::caution
A turn that hits `maxToolRounds` silently drops any un-executed tool calls and emits whatever partial answer the model produced. If you observe truncated responses, raise the cap or reduce the number of tools the model tends to call in sequence.
:::

## Default system prompt

When you use the no-`systemPrompt` initializer, `Agent` inserts:

```swift
public static func defaultSystemPrompt(name: String, description: String) -> String
```

The generated prompt instructs the model to engage in open-ended multi-turn conversation using the agent's name and description. Supply your own `systemPrompt:` whenever you need task-specific instructions.

## Quick example

```swift
import AgentSquad

let agent = Agent(
    name: "Support Agent",
    description: "Handles customer support questions.",
    model: myLLMClient,
    tools: myToolProvider
)

let context = AgentContext(userId: "u1", sessionId: "s1")
let stream = agent.process(.text("What is my order status?"), history: [], context: context)

for try await event in stream {
    switch event {
    case .textDelta(let chunk): print(chunk, terminator: "")
    case .final(let msg):       print("\nDone: \(msg)")
    default: break
    }
}
```

## Related pages

- [Agents overview](/agent-squad/swift/agents/overview/) — `AgentProtocol`, `AgentInput`, `AgentContext`, and `AgentEvent`.
- [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/) — the two-LLM anti-hallucination variant.
- [Custom agents](/agent-squad/swift/agents/custom/) — roll your own `AgentProtocol` conformance.
- [Tools](/agent-squad/swift/tools/overview/) — building a `ToolProvider`.
- [LLM clients](/agent-squad/swift/llm/overview/) — available `LLMClient` implementations.
- [UI](/agent-squad/swift/ui/overview/) — `UIPayload` and `.widget` event consumption.
- [Tracing](/agent-squad/swift/tracing/overview/) — spans and `AgentContext`.
