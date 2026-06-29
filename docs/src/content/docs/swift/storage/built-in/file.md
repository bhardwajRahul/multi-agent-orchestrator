---
title: FileChatStorage
description: JSON-file-backed persistent storage, compatible with iOS 16+.
---

`FileChatStorage` persists each `(userId, sessionId, agentId)` scope as a JSON file under `Library/Caches/AgentSquadChats` by default. It is the recommended persistent store when you need iOS 16 compatibility or prefer a dependency-free implementation.

## Init

```swift
public actor FileChatStorage: ChatStorage {
    public init(baseURL: URL? = nil, fileManager: FileManager = .default)
}
```

| Parameter | Default | Notes |
|---|---|---|
| `baseURL` | `Library/Caches/AgentSquadChats` | Override for a custom path or test isolation. |
| `fileManager` | `.default` | Injectable for unit tests. |

## Usage

**Default path:**

```swift
let store = FileChatStorage()
let orchestrator = Orchestrator(agents: [agent], store: store)
```

**Custom directory** (e.g. a shared app-group container):

```swift
let store = FileChatStorage(
    baseURL: FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.app")!
        .appendingPathComponent("Chats")
)
```

**Test isolation** (deterministic directory, no cross-test pollution):

```swift
let store = FileChatStorage(
    baseURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
    fileManager: .default
)
```

## Behavior

- **One file per scope.** Each `(userId, sessionId, agentId)` triple maps to a separate JSON file. Scope ids are percent-encoded so any string is a valid filename component, and the encoding is reversible.
- **Corrupt or missing file reads as empty.** A purged Caches directory or a corrupt file returns `[]` rather than throwing.
- **Millisecond timestamp precision.** Dates are encoded with `.millisecondsSince1970` so the merged `fetchAllChats` view orders correctly when multiple messages share the same second.
- **`[agentId]` attribution.** `fetchAllChats` prefixes assistant messages with `[agentId]`, giving the Classifier correct routing attribution in multi-agent sessions.
- **Survives app restarts.** History is written to `Library/Caches` — it persists across launches but is reclaimable by the OS under disk pressure.

:::caution
Each `save` / `saveMessages` call reads and rewrites the entire scope file. Keep `maxMessages` capped — use `ChatStorageDefaults.maxMessages` (100) or lower — for large conversation volumes. If you need row-level writes, use [`DeviceChatStorage`](/agent-squad/swift/storage/built-in/device/) (iOS 17+ / macOS 14+).
:::

---

See also: [Storage overview](/agent-squad/swift/storage/overview/) · [InMemoryChatStorage](/agent-squad/swift/storage/built-in/in-memory/) · [DeviceChatStorage](/agent-squad/swift/storage/built-in/device/) · [Custom store](/agent-squad/swift/storage/custom/)
