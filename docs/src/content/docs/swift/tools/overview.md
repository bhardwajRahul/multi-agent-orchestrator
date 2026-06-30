---
title: Tools Overview
description: AgentTool, ToolProvider, ToolResult, ToolVisibility, and JSONValue — the core primitives every tool integration builds on.
---

Tools are functions an agent can call during inference. AgentSquad is provider-agnostic: an agent receives a `ToolProvider` and never cares whether the tools behind it are native Swift closures, HTTP APIs, MCP servers, or a mix of all three.

This page covers the core primitives. The built-in providers each have their own page:

| Provider | Use it for |
|----------|------------|
| [Local & HTTP tools](/agent-squad/swift/tools/built-in/local-http/) | Local Swift closures (`Tool.local`) and declarative HTTP APIs (`Tool.http`, `HTTPToolGroup`) |
| [Composing providers](/agent-squad/swift/tools/built-in/composing/) | `AggregateToolProvider` — local + API + MCP behind one seam |
| [MCP servers](/agent-squad/swift/mcp/overview/) | `MCPServer(url:)` — connect a remote MCP server |

To build a provider from scratch, see [Custom Tools](/agent-squad/swift/tools/custom/).

## `AgentTool`

Describes a single tool to the model — its name, a natural-language description, and a JSON Schema for its arguments.

```swift
public struct AgentTool: Sendable, Equatable, Hashable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue        // JSON Schema; defaults to {"type":"object"}
    public let outputSchema: JSONValue?      // advisory result schema; NOT sent to the model; nil if none
    public let ui: String?                  // ui:// resource URI, nil if no tool UI
    public let visibility: ToolVisibility

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue = .object(["type": "object"]),
        ui: String? = nil,
        visibility: ToolVisibility = .all,
        outputSchema: JSONValue? = nil
    )
}
```

`AgentTool` is `Hashable` so merged tool lists deduplicate by identity; keep names unique across providers.

## `ToolVisibility`

An `OptionSet` that controls who may invoke a tool.

| Member | Meaning |
|--------|---------|
| `.model` | The LLM may call it |
| `.app` | Host application code may call it |
| `.all` | Both (default) |

A tool with only `.app` visibility is never offered to the model but can still be called programmatically by the host application.

## `ToolProvider`

The single seam between an agent and its tools.

```swift
public protocol ToolProvider: Sendable {
    func listTools() async throws -> [AgentTool]
    func call(_ name: String, arguments: JSONValue) async throws -> ToolResult
}
```

`call` distinguishes two failure modes:

- **Tool-level failure** — return a `ToolResult` with `isError: true`. The agent feeds the error text back to the model and the loop continues.
- **Infrastructure failure** — `throw`. The call itself is aborted (transport error, auth failure, etc.).

:::note[Keep `listTools` pure]
`listTools` is called before every turn. Avoid side effects or expensive I/O inside it; do any initialisation in your provider's `init` or a dedicated setup method.
:::

## `ToolResult`

What `call` returns.

```swift
public struct ToolResult: Sendable, Equatable {
    public let content: [ContentPart]?      // text added to the model's context
    public let structuredContent: JSONValue // structured data, NOT sent to the model
    public let ui: UIPayload?               // widget package, nil if the tool has no UI
    public let isError: Bool

    public init(
        content: [ContentPart]? = nil,
        structuredContent: JSONValue = .object([:]),
        ui: UIPayload? = nil,
        isError: Bool = false
    )

    /// Convenience — builds a tool-level error the model can read.
    public static func failure(_ message: String) -> ToolResult
}
```

`content` is what lands in the model's context window. `structuredContent` is the source of truth for presenter/UI hydration and is **never** forwarded to the model.

:::note[Tool UIs]
A tool can advertise a `ui://` URI in `AgentTool.ui`. When it does, `ToolResult.ui` carries a self-contained `UIPayload` widget package that the host app can render. See [UI Overview](/agent-squad/swift/ui/overview/).
:::

## `JSONValue`

All tool arguments and structured results use `JSONValue`, a schema-less enum that round-trips through `Codable`.

```swift
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```

`JSONValue` conforms to all Swift literal protocols, so you can write schemas and result payloads inline:

```swift
let schema: JSONValue = [
    "type": "object",
    "properties": [
        "limit": ["type": "integer"],
        "live":  ["type": "boolean"]
    ],
    "required": ["limit"]
]
```

Read object fields with a `String` subscript and typed accessors (`stringValue`, `intValue`, `boolValue`, `doubleValue`); both return `nil` on a wrong-shape or missing value, so chaining is safe:

```swift
let city = arguments["city"]?.stringValue
```

:::caution[Number encoding]
Whole-number `Double` values decode to `.int` (e.g. `1.0` → `.int(1)`). Integer IDs that exceed `Int` range lose precision as `.double`. Carry large or opaque numeric IDs as `.string`.
:::

## Where tools come from

| Source | How |
|--------|-----|
| Local Swift | `Tool.local` in a [`ToolKit`](/agent-squad/swift/tools/built-in/local-http/) |
| HTTP APIs | `Tool.http` / `HTTPToolGroup` in a [`ToolKit`](/agent-squad/swift/tools/built-in/local-http/) |
| MCP servers | [`MCPServer(url:)`](/agent-squad/swift/mcp/overview/) from the `AgentSquadMCP` module |
| Composed | [`AggregateToolProvider`](/agent-squad/swift/tools/built-in/composing/) |
| Fully custom | Conform to `ToolProvider` directly — see [Custom Tools](/agent-squad/swift/tools/custom/) |

Pass the provider when constructing an agent — see [Agents Overview](/agent-squad/swift/agents/overview/) for how each agent type accepts a `ToolProvider`.
