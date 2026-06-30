---
title: InMemoryChatStorage
description: Non-persistent, seedable in-memory store for a single conversation.
---

`InMemoryChatStorage` holds a single conversation for the lifetime of the instance. It is the right choice when you do not need persistence across app restarts, or when you want to inject a prior conversation into a session at construction time.

## Init

```swift
public actor InMemoryChatStorage: ChatStorage {
    public init(_ messages: [ConversationMessage] = [])
}
```

| Parameter | Default | Notes |
|---|---|---|
| `messages` | `[]` | Starting conversation. Preserved in full — `fetch` trims only the returned view, so a loaded conversation is never clipped at construction time. |

## Usage

**Fresh session:**

```swift
let store = InMemoryChatStorage()
let orchestrator = Orchestrator(agents: [agent], store: store)
```

**Seeding a prior conversation** — hand the Orchestrator an existing exchange so the agent has context from the start:

```swift
let prior: [ConversationMessage] = loadPriorConversation()   // your retrieval logic
let store = InMemoryChatStorage(prior)
let orchestrator = Orchestrator(agents: [agent], store: store)
```

The seeded messages are stored in full; `fetch` trims only the returned view via `trimToEvenPairs`, so the loaded conversation is never clipped at construction time.

## Behavior

- **Scope-agnostic.** `userId`, `sessionId`, and `agentId` are ignored — every read and write targets the same history. This is what allows seeding without knowing the consumer's `agentId`.
- **No `[agentId]` attribution.** `fetchAllChats` returns the whole conversation unattributed.
- **No persistence.** History is lost when the instance is deallocated.

:::note
Because `InMemoryChatStorage` returns no `[agentId]` prefix from `fetchAllChats`, the Classifier loses routing attribution in a multi-agent Orchestrator. For multi-agent setups, use [`FileChatStorage`](/agent-squad/swift/storage/built-in/file/) or [`DeviceChatStorage`](/agent-squad/swift/storage/built-in/device/).
:::

---

See also: [Storage overview](/agent-squad/swift/storage/overview/) · [FileChatStorage](/agent-squad/swift/storage/built-in/file/) · [DeviceChatStorage](/agent-squad/swift/storage/built-in/device/) · [Custom store](/agent-squad/swift/storage/custom/)
