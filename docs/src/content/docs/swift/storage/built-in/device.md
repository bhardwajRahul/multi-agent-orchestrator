---
title: DeviceChatStorage
description: SwiftData-backed persistent storage, iOS 17+ / macOS 14+.
---

`DeviceChatStorage` is the bundled on-device store for iOS 17+ and macOS 14+. It backs history with a SwiftData SQLite store under `Library/Caches/AgentSquad` — never backed up, reclaimable by the OS under disk pressure. Use [`FileChatStorage`](/agent-squad/swift/storage/built-in/file/) on iOS 16.

:::caution
`DeviceChatStorage` requires **iOS 17+ / macOS 14+** (SwiftData). On iOS 16, use [`FileChatStorage`](/agent-squad/swift/storage/built-in/file/), a [custom `ChatStorage`](/agent-squad/swift/storage/custom/), or `store: nil`.
:::

## Init

```swift
@available(iOS 17, macOS 14, *)
public actor DeviceChatStorage: ChatStorage, ModelActor {
    public init(userId: String, baseURL: URL? = nil, inMemory: Bool = false) throws
}
```

| Parameter | Default | Notes |
|---|---|---|
| `userId` | — | Required. Bound at init. The per-call `userId` on `fetch` / `save` / `saveMessages` / `fetchAllChats` is asserted to match. |
| `baseURL` | `Library/Caches/AgentSquad` | Override the SQLite store directory. |
| `inMemory` | `false` | `true` uses an ephemeral SwiftData store — for tests. |

## Usage

**Production:**

```swift
let store = try DeviceChatStorage(userId: currentUser.id)
let orchestrator = Orchestrator(agents: [agent], store: store)
```

**Tests — ephemeral, no disk I/O:**

```swift
let store = try DeviceChatStorage(userId: "test-user", inMemory: true)
```

## Clearing history on logout

```swift
public func clear() throws
```

`clear()` deletes all rows for the bound `userId`. Call it on logout or account switch so the next user cannot read the previous session's history.

```swift
try await store.clear()
```

## Behavior

- **Bound `userId`.** The store is created for one user. Passing a different `userId` at call time triggers an `assert` failure in debug builds and silently uses the bound id in release. Create a new instance when the user changes.
- **Self-healing.** A partial WAL/SHM purge (common when `Library/Caches` is evicted mid-write) would make `ModelContainer` throw forever. `DeviceChatStorage` detects this and deletes the corrupt store once, re-creating it from scratch. History is lost in that scenario, but the app recovers automatically.
- **Row-level writes.** Unlike `FileChatStorage`, each save inserts individual rows. This scales better with large message budgets.
- **`[agentId]` attribution.** `fetchAllChats` prefixes assistant messages with `[agentId]`, giving the Classifier correct routing attribution in multi-agent sessions.

:::caution
`DeviceChatStorage` is bound to a single `userId` at init. Passing a different `userId` to any method triggers an assertion failure in debug builds and silently uses the bound id in release. Create a new instance when the user changes.
:::

---

See also: [Storage overview](/agent-squad/swift/storage/overview/) · [InMemoryChatStorage](/agent-squad/swift/storage/built-in/in-memory/) · [FileChatStorage](/agent-squad/swift/storage/built-in/file/) · [Custom store](/agent-squad/swift/storage/custom/)
