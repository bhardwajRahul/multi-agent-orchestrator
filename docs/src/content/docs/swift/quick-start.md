---
title: Quick start
description: Build and run a minimal AgentSquad CLI in Swift — one agent, then two with classifier routing.
---

Everything below compiles and runs from the command line. You need Swift 6.2+ (Xcode 26+) and an OpenAI API key.

## Single-agent CLI

### 1. Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "quickstart",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/2FastLabs/agent-squad", branch: "main")
    ],
    targets: [
        .executableTarget(name: "quickstart", dependencies: [
            .product(name: "AgentSquad", package: "agent-squad")
        ])
    ]
)
```

### 2. Sources/quickstart/main.swift

```swift
import AgentSquad
import Foundation

guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
    fatalError("set OPENAI_API_KEY")
}

// LLM client — any OpenAI-compatible endpoint
let model = ChatCompletionsClient(model: "gpt-4o-mini", apiKey: apiKey)

// One agent: name + description drive the default system prompt
let agent = Agent(name: "Shop", description: "Shopping assistant", model: model)

// Orchestrator with no classifier — the single agent always handles every turn
let orchestrator = Orchestrator(
    agents: [agent],
    store: try DeviceChatStorage(userId: "u1", inMemory: true)
)

// route(_:userId:sessionId:) returns an AsyncThrowingStream<AgentEvent, any Error>
for try await event in orchestrator.route(
    .text("wireless headphones under €100?"),
    userId: "u1",
    sessionId: "s1"
) {
    if case .textDelta(let token) = event { print(token, terminator: "") }
}
print()
```

### 3. Run

```bash
OPENAI_API_KEY=sk-… swift run
```

:::note
`DeviceChatStorage` (SwiftData) requires iOS 17+ / macOS 14+. For iOS 16 targets use `FileChatStorage` or `InMemoryChatStorage` instead.
:::

## Routing between agents

Add a second agent and an `LLMClassifier` — the call site is identical:

```swift
let shop    = Agent(name: "Shop",    description: "Product search, prices, recommendations.", model: model)
let support = Agent(name: "Support", description: "Orders, returns, and account help.",        model: model)

let orchestrator = Orchestrator(
    agents: [shop, support],                 // first agent is the default / fallback
    classifier: LLMClassifier(model: model), // picks the agent for each turn
    store: try DeviceChatStorage(userId: "u1", inMemory: true)
)

for try await event in orchestrator.route(
    .text("where is my order #1234?"),
    userId: "u1",
    sessionId: "s1"
) {
    if case .textDelta(let token) = event { print(token, terminator: "") }
}
```

`LLMClassifier` uses the same `LLMClient` type as the agents. You can pass a separate, cheaper model for routing if you like:

```swift
let router = ChatCompletionsClient(model: "gpt-4o-mini", apiKey: apiKey)
LLMClassifier(model: router)
```

:::note
When `classifier` is `nil`, only the first agent in the `agents` array is ever called — no extra model call occurs. Any additional agents in the list are unreachable until you supply a classifier.
:::

## Key types at a glance

| Type | Role |
|---|---|
| `ChatCompletionsClient` | `LLMClient` for any OpenAI-compatible endpoint (OpenAI, Azure, Groq, OpenRouter, Ollama, …) |
| `Agent` | Single-LLM agent; accepts optional `tools:` and a custom `systemPrompt:` |
| `Orchestrator` | Drives a turn end-to-end: classify → run agent → stream events → persist |
| `LLMClassifier` | Routes turns to agents via a `select_agent` tool call |
| `AgentEvent.textDelta` | Token-by-token text streamed from the agent |

## What to do next

- Add tools to an agent — see [Agents](/agent-squad/swift/agents/overview/) and [Tools](/agent-squad/swift/tools/overview/).
- Swap `Agent` for `GroundedAgent` for hallucination-resistant answers — see [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/).
- Understand every event the stream can emit — see [Messages & events](/agent-squad/swift/reference/messages-and-events/).
- Point `ChatCompletionsClient` at a different provider — see [LLM clients](/agent-squad/swift/llm/overview/).
- Persist chat history across sessions — see [Chat history](/agent-squad/swift/storage/overview/).
- Observe what happens inside a turn — see [Tracing](/agent-squad/swift/tracing/overview/).
