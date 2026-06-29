---
title: Custom Curator
description: Conform any Sendable type to ToolOutputCurator to replace or augment the default data-block format with domain-specific output layouts.
---

Conform any `Sendable` struct (or actor) to `ToolOutputCurator` by implementing the single synchronous requirement. The curator receives all captured tool results for a turn and returns the string the presenter LLM is fed.

See [Built-in Curators](/agent-squad/swift/ui/built-in/curators/) for `DataBlockCurator` and `PerToolCurator`, or [UI Overview](/agent-squad/swift/ui/overview/) for the UIPolicy/UIPayload model.

---

## The protocol

```swift
public protocol ToolOutputCurator: Sendable {
    func curate(_ results: [CapturedTool]) -> String
}
```

`curate(_:)` is called synchronously on the agent's task. The return value becomes the data block the presenter sees. Any external data the curator needs — lookup tables, templates, thresholds — must be fetched ahead of time and stored as immutable properties.

---

## Example: compact newline-delimited JSON

The example below replaces the default markdown blocks with a compact NDJSON feed — one JSON object per tool — and supports an optional allowlist to drop unwanted results.

```swift
import Foundation

struct CompactJSONCurator: ToolOutputCurator {
    /// Optional allowlist — only these tools appear in the feed. nil means all.
    let include: Set<String>?

    init(include: Set<String>? = nil) {
        self.include = include
    }

    func curate(_ results: [CapturedTool]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        return results
            .filter { include == nil || include!.contains($0.name) }
            .compactMap { tool -> String? in
                // Build a minimal envelope; fall back to structuredContent when
                // no text content is present.
                let textBody = (tool.content ?? []).compactMap {
                    if case .text(let v) = $0 { return v } else { return nil }
                }.joined(separator: " ")

                let envelope: JSONValue = [
                    "tool": .string(tool.name),
                    "data": textBody.isEmpty ? tool.structuredContent : .string(textBody)
                ]

                guard let data = try? encoder.encode(envelope) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            .joined(separator: "\n")
    }
}
```

Pass it directly to `GroundedAgent` via the `curator:` parameter:

```swift
let agent = GroundedAgent(
    name: "Fixtures",
    gatherer: fastModel,
    presenter: preciseModel,
    tools: fixtureTools,
    curator: CompactJSONCurator(include: ["liveScores", "standings"])
)
```

:::note
Custom types are passed as values — not through the built-in `.dataBlock` / `.perTool` dot-syntax. If you want the same ergonomics, add a constrained extension on `ToolOutputCurator`:
:::

```swift
extension ToolOutputCurator where Self == CompactJSONCurator {
    static func compactJSON(include: Set<String>? = nil) -> CompactJSONCurator {
        CompactJSONCurator(include: include)
    }
}

// Usage
curator: .compactJSON(include: ["liveScores"])
```

---

## Design rules

| Rule | Why |
|------|-----|
| Keep `curate(_:)` CPU-bound and side-effect-free | It is called synchronously; blocking stalls the agent |
| Pre-fetch all external data before constructing the curator | No async calls are possible inside `curate(_:)` |
| Fall back to `DataBlockCurator.section(_:)` for tools you don't own | Preserves lossless output for unexpected tool names |
| Return an empty string only when all results are intentionally suppressed | An empty presenter feed produces a vacuous answer |

:::caution
`curate(_:)` is called on the agent's Swift concurrency task. Spawning child tasks, accessing `@MainActor` state, or performing I/O here will deadlock or produce data races. Do all preparation before the `GroundedAgent` is constructed.
:::

---

## Related

- [Built-in Curators](/agent-squad/swift/ui/built-in/curators/) — `DataBlockCurator`, `PerToolCurator`, `PresenterPrompt`
- [UI Overview](/agent-squad/swift/ui/overview/) — UIPolicy, UIPayload, UITemplate, UISecurity, ToolVisibility
- [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/) — the two-LLM gatherer/presenter pattern that accepts `curator:`
- [Messages & Events](/agent-squad/swift/reference/messages-and-events/) — `AgentEvent` and the full event stream shape
