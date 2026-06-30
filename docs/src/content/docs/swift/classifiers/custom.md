---
title: Custom Classifiers
description: Implement the Classifier protocol to plug in your own agent-routing logic.
---

Any type that conforms to `Classifier` can be passed to the Orchestrator in place of [`LLMClassifier`](/agent-squad/swift/classifiers/built-in/llm-classifier/). This is the right choice when you need deterministic routing (keyword rules, regex, external service calls, ML models) without an LLM round-trip.

See the [Classifiers overview](/agent-squad/swift/classifiers/overview/) for how `ClassifierResult` drives the dispatch.

## Protocol

```swift
public protocol Classifier: Sendable {
    func classify(
        _ input: String,
        history: [ConversationMessage],
        agents: [any AgentProtocol]
    ) async throws -> ClassifierResult
}
```

Your implementation receives:

| Parameter | Type | Notes |
|---|---|---|
| `input` | `String` | The user's current message. |
| `history` | `[ConversationMessage]` | Merged, `[agentId]`-prefixed conversation from [chat storage](/agent-squad/swift/storage/overview/). |
| `agents` | `[any AgentProtocol]` | The full set of agents registered with the Orchestrator. |

It must return a `ClassifierResult`:

```swift
public struct ClassifierResult: Sendable {
    public let selectedAgent: (any AgentProtocol)?
    public let confidence: Double

    public init(selectedAgent: (any AgentProtocol)?, confidence: Double)
}
```

## Example: KeywordClassifier

A simple classifier that matches agent names against words in the user's input:

```swift
struct KeywordClassifier: Classifier {
    func classify(
        _ input: String,
        history: [ConversationMessage],
        agents: [any AgentProtocol]
    ) async throws -> ClassifierResult {
        let lower = input.lowercased()
        let match = agents.first { agent in
            lower.contains(agent.name.lowercased())
        }
        return ClassifierResult(
            selectedAgent: match,
            confidence: match != nil ? 1.0 : 0.0
        )
    }
}
```

Pass it to the Orchestrator exactly like the built-in one:

```swift
let orchestrator = Orchestrator(classifier: KeywordClassifier(), storage: storage)
```

:::caution
Always resolve `selectedAgent` from the `agents` array passed into `classify`. Never return an agent instance you constructed yourself — the Orchestrator dispatches the returned object directly, and it expects the exact instance it registered.
:::

## Tips

- Return `ClassifierResult(selectedAgent: nil, confidence: 0.0)` when no agent matches; the Orchestrator falls back to the first registered agent.
- `confidence` is captured for [tracing](/agent-squad/swift/tracing/overview/) only and does not affect dispatch. Use it to record routing certainty without building threshold logic into the Orchestrator.
- `classify` is `async throws`, so you can call remote services, run Core ML inference, or await any other async work.
- Because `Classifier` inherits `Sendable`, all stored state must be `Sendable`-safe (value types or actors).

## Related pages

- [Classifiers overview](/agent-squad/swift/classifiers/overview/) — the `Classifier` protocol, `ClassifierResult`, and the nil-classifier path.
- [LLMClassifier](/agent-squad/swift/classifiers/built-in/llm-classifier/) — built-in LLM-based routing.
- [Agents overview](/agent-squad/swift/agents/overview/) — `AgentProtocol` and the agents you route to.
