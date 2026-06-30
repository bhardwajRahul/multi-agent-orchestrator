---
title: LLMClassifier
description: Built-in classifier that routes turns using an LLMClient and a select_agent tool call.
---

`LLMClassifier` is the default classifier. It builds a system prompt from all registered agents' `id`, `name`, and `description`, then calls your [LLM client](/agent-squad/swift/llm/overview/) with a `select_agent` tool. The model calls that tool with the chosen agent's `id` and a `confidence` value; an absent or hallucinated id resolves to `nil`, triggering the Orchestrator's default-agent fallback.

See the [Classifiers overview](/agent-squad/swift/classifiers/overview/) for how `ClassifierResult` and the routing dispatch work.

## Initializer

```swift
public struct LLMClassifier: Classifier {
    public init(model: any LLMClient, instructions: String = LLMClassifier.defaultInstructions)
}
```

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `model` | `any LLMClient` | — | The LLM backend used for routing calls. |
| `instructions` | `String` | `LLMClassifier.defaultInstructions` | System prompt governing routing behaviour. See [Custom instructions](#custom-instructions) below. |

## Basic usage

Pass any `LLMClient` and you're done:

```swift
let classifier = LLMClassifier(
    model: BedrockLLMClient(modelId: "us.anthropic.claude-3-5-haiku-20241022-v1:0")
)

let orchestrator = Orchestrator(classifier: classifier, storage: storage)
```

A lightweight model (Haiku, Flash, etc.) is usually sufficient — the task is structured tool-call routing, not open-ended generation.

## Conversation continuity

The history passed to `classify` is the merged, `[agentId]`-prefixed conversation fetched from [chat storage](/agent-squad/swift/storage/overview/). The default prompt instructs the model to use it for follow-up detection: short affirmations like "yes" or "ok" stay with the previously selected agent rather than triggering a fresh match.

## Custom instructions

`LLMClassifier.defaultInstructions` contains an `{{AGENT_DESCRIPTIONS}}` placeholder that is replaced at classify time with a roster built from all registered agents. When you supply your own `instructions` string:

- **With `{{AGENT_DESCRIPTIONS}}`** — the placeholder is replaced as usual.
- **Without `{{AGENT_DESCRIPTIONS}}`** — the agent roster is appended to the end of your instructions.

```swift
let classifier = LLMClassifier(
    model: myClient,
    instructions: """
    You are a strict router. Only route to agents explicitly listed below.
    If no agent matches, do not call select_agent.
    {{AGENT_DESCRIPTIONS}}
    """
)
```

:::note
Custom instructions must still guide the model to call the `select_agent` tool — the tool definition is injected automatically, but the model needs to be told to use it. The default prompt already covers this.
:::

## Default instructions reference

`LLMClassifier.defaultInstructions` is public so you can inspect or extend it:

```swift
public static let defaultInstructions: String
```

It encodes the AgentMatcher prompt ported from the Python agent-squad, including:

- Categorisation against the `{{AGENT_DESCRIPTIONS}}` roster.
- Confidence levels: High ≈ 0.9+, Medium ≈ 0.6–0.8, Low < 0.6.
- Follow-up continuation — short replies like "yes", "ok", or numeric answers route to the previously selected agent.
- Four worked examples covering initial queries, context switches, follow-ups, and multi-turn switches.

## Related pages

- [Classifiers overview](/agent-squad/swift/classifiers/overview/) — the `Classifier` protocol, `ClassifierResult`, and the nil-classifier path.
- [Custom classifiers](/agent-squad/swift/classifiers/custom/) — implement your own routing logic.
- [LLM clients](/agent-squad/swift/llm/overview/) — the `LLMClient` protocol and built-in implementations.
