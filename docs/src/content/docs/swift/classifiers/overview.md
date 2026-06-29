---
title: Classifiers Overview
description: How AgentSquad routes each turn to the right agent via the Classifier protocol.
---

A **classifier** runs before each turn and decides which agent should handle it. The [Orchestrator](/agent-squad/swift/orchestrator/overview/) calls `classify(_:history:agents:)`, gets back a `ClassifierResult`, and dispatches to `selectedAgent` — or falls back to the default agent when `selectedAgent` is `nil`.

## Core types

```swift
public struct ClassifierResult: Sendable {
    public let selectedAgent: (any AgentProtocol)?
    public let confidence: Double

    public init(selectedAgent: (any AgentProtocol)?, confidence: Double)
}

public protocol Classifier: Sendable {
    func classify(
        _ input: String,
        history: [ConversationMessage],
        agents: [any AgentProtocol]
    ) async throws -> ClassifierResult
}
```

### ClassifierResult fields

| Field | Type | Notes |
|---|---|---|
| `selectedAgent` | `(any AgentProtocol)?` | The chosen agent, or `nil` when nothing matched. Always one of the `agents` passed to `classify`. |
| `confidence` | `Double` | Nominally `0...1`. Captured for [tracing](/agent-squad/swift/tracing/overview/) only. |

:::note
`confidence` is observability data, not a routing threshold. The Orchestrator only inspects `selectedAgent`; it falls back to the default agent when that is `nil`. If you want confidence-gated routing, implement the threshold inside your `Classifier`.
:::

## How routing works

1. The Orchestrator fetches merged conversation history from [storage](/agent-squad/swift/storage/overview/).
2. It calls `classifier.classify(_:history:agents:)` with the user input, that history, and all registered agents.
3. `selectedAgent` from the returned `ClassifierResult` is dispatched directly. No second lookup is performed — the agent instance must come from the `agents` parameter.
4. When `selectedAgent` is `nil`, the Orchestrator routes to the first registered agent (the default).

## Skipping the classifier (nil path)

Pass `nil` as the classifier when constructing the Orchestrator. Every turn goes straight to the first registered agent with no LLM call for routing.

```swift
let orchestrator = Orchestrator(classifier: nil, storage: storage)
```

:::note
`nil` classifier is the right default for single-agent setups. Adding `LLMClassifier` to a single-agent orchestrator costs a full LLM round-trip per turn with no benefit.
:::

## Built-in classifiers

| Classifier | Description |
|---|---|
| [`LLMClassifier`](/agent-squad/swift/classifiers/built-in/llm-classifier/) | Uses an `LLMClient` and a `select_agent` tool call to pick the best agent. The default when a classifier is needed. |

## Next steps

- **[LLMClassifier](/agent-squad/swift/classifiers/built-in/llm-classifier/)** — built-in LLM-based routing, init options, and custom instructions.
- **[Custom classifiers](/agent-squad/swift/classifiers/custom/)** — implement the `Classifier` protocol to write your own routing logic.
