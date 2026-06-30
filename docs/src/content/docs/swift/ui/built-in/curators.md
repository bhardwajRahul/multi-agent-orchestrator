---
title: Built-in Curators
description: DataBlockCurator, PerToolCurator, and PresenterPrompt — the built-in ToolOutputCurator implementations that ship with AgentSquad.
---

`ToolOutputCurator` is `GroundedAgent`'s extension point for turning raw tool results into the text the presenter LLM receives. It is a pure synchronous transform — no I/O.

See [UI Overview](/agent-squad/swift/ui/overview/) for the UIPolicy/UIPayload model, or [Custom Curator](/agent-squad/swift/ui/custom/) for writing your own.

---

## ToolOutputCurator protocol

```swift
public protocol ToolOutputCurator: Sendable {
    func curate(_ results: [CapturedTool]) -> String
}
```

Called synchronously on the agent's task. Any data the curator needs must be pre-fetched and stored as immutable properties — no async work inside `curate(_:)`.

### CapturedTool

What the curator receives for each result:

```swift
public struct CapturedTool: Sendable, Equatable {
    public let name: String
    public let ui: String?                  // the ui:// resource URI, if any
    public let structuredContent: JSONValue
    public let content: [ContentPart]?
}
```

---

## DataBlockCurator

The default curator. Emits one `### <toolName>` section per result — model-facing text content when present, otherwise the structured data pretty-printed as JSON. Sections are concatenated with a blank line between them.

```swift
public struct DataBlockCurator: ToolOutputCurator {
    public init()
    public func curate(_ results: [CapturedTool]) -> String
    public static func section(_ tool: CapturedTool) -> String
}
```

`DataBlockCurator.section(_:)` is `public` so `PerToolCurator` formatters can fall back to it for any unmapped tool.

**Usage** — `DataBlockCurator` is the default; no `curator:` argument required:

```swift
let agent = GroundedAgent(
    name: "Fixtures",
    gatherer: fastModel,
    presenter: preciseModel,
    tools: fixtureTools
    // curator: .dataBlock is the implicit default
)
```

Or pass it explicitly:

```swift
let agent = GroundedAgent(
    name: "Fixtures",
    gatherer: fastModel,
    presenter: preciseModel,
    tools: fixtureTools,
    curator: .dataBlock
)
```

---

## PerToolCurator

Routes each tool to its own formatter, keyed by tool name. Use this to trim or reformat oversized payloads before they reach the presenter. Unmapped tools fall back to `DataBlockCurator.section(_:)` by default.

```swift
public struct PerToolCurator: ToolOutputCurator {
    public typealias Formatter = @Sendable (CapturedTool) -> String

    public init(
        _ formatters: [String: Formatter],
        default fallback: @escaping Formatter
    )

    public func curate(_ results: [CapturedTool]) -> String
}
```

**Static constructor** (preferred):

```swift
extension ToolOutputCurator where Self == PerToolCurator {
    public static func perTool(
        _ formatters: [String: PerToolCurator.Formatter],
        default fallback: @escaping PerToolCurator.Formatter = { DataBlockCurator.section($0) }
    ) -> PerToolCurator
}
```

**Usage:**

```swift
let agent = GroundedAgent(
    name: "Fixtures",
    gatherer: fastModel,
    presenter: preciseModel,
    tools: fixtureTools,
    curator: .perTool([
        "liveScores": { tool in
            // compact the payload — only emit the fields the presenter needs
            let scores = tool.structuredContent["scores"]
            return "### liveScores\n\(scores)"
        }
        // unmapped tools fall back to DataBlockCurator.section(_:)
    ])
)
```

To override the fallback:

```swift
curator: .perTool(
    ["liveScores": myFormatter],
    default: { tool in "### \(tool.name)\n(omitted)" }
)
```

:::caution
Keep formatters fast and side-effect-free. `ToolOutputCurator.curate(_:)` is called synchronously on the agent's task; any blocking or async work must be done ahead of time and captured in the curator's stored state.
:::

---

## PresenterPrompt

Selects the presenter's system prompt for a given turn, optionally keyed by the turn's primary tool.

```swift
public struct PresenterPrompt: Sendable {
    public init(default defaultPrompt: String, perTool: [String: String] = [:])
    public func resolve(primaryTool: String?) -> String
    public static let `default`: PresenterPrompt
}
```

`resolve(primaryTool:)` returns the per-tool prompt when `primaryTool` matches an entry in the map, and falls back to `defaultPrompt` otherwise (including when `primaryTool` is `nil` — no tools were called that turn).

`PresenterPrompt.default` instructs the presenter to use only provided data and never invent values. Override it when the presenter needs domain-specific framing:

```swift
let prompt = PresenterPrompt(
    default: "Present the data clearly. Never invent scores or team names.",
    perTool: [
        "standings": "You are presenting a league table. Preserve ordering exactly."
    ]
)

let agent = GroundedAgent(
    name: "League",
    gatherer: fastModel,
    presenter: preciseModel,
    tools: leagueTools,
    presenterPrompt: prompt
)
```

:::note
`PresenterPrompt.default` is the built-in fallback. Pass a custom `PresenterPrompt` whenever the default grounding instruction is too generic for your domain.
:::

---

## Related

- [UI Overview](/agent-squad/swift/ui/overview/) — UIPolicy, UIPayload, UITemplate, UISecurity, ToolVisibility
- [Custom Curator](/agent-squad/swift/ui/custom/) — implementing `ToolOutputCurator` for domain-specific layouts
- [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/) — the two-LLM gatherer/presenter pattern that uses `ToolOutputCurator` and `PresenterPrompt`
- [Messages & Events](/agent-squad/swift/reference/messages-and-events/) — `AgentEvent` and the full event stream shape
