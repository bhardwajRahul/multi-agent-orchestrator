---
title: Custom Tools
description: Implement the ToolProvider protocol in native Swift to give agents access to any API or business logic.
---

:::tip[Reach for the built-ins first]
Most tools don't need a custom provider. Use [`ToolKit`](/agent-squad/swift/tools/overview/#toolkit-local--api-tools) with `Tool.local` (Swift code) and `Tool.http` (HTTP APIs), and [`AggregateToolProvider`](/agent-squad/swift/tools/overview/#aggregatetoolprovider-mixing-sources) to combine sources. Conform to `ToolProvider` directly only when you need something they don't cover — a **dynamic** tool list, stateful per-session behaviour, or custom dispatch.
:::

Conform to [`ToolProvider`](/agent-squad/swift/tools/overview/) directly to expose any Swift function as a callable tool. The protocol has two requirements: `listTools` (declare what exists) and `call` (execute by name).

For a full explanation of `AgentTool`, `ToolResult`, `ToolVisibility`, and `JSONValue`, see [Tools Overview](/agent-squad/swift/tools/overview/).

## Single-tool provider

The minimal pattern — one struct, one tool:

```swift
import AgentSquad

struct WeatherToolProvider: ToolProvider {
    func listTools() async throws -> [AgentTool] {
        [
            AgentTool(
                name: "get_weather",
                description: "Returns current weather for a city.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "city": ["type": "string", "description": "City name"]
                    ],
                    "required": ["city"]
                ]
            )
        ]
    }

    func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        guard name == "get_weather" else {
            return .failure("Unknown tool: \(name)")
        }
        guard case .string(let city) = arguments["city"] else {
            return .failure("Missing required argument: city")
        }
        // ... call your API ...
        let summary = "Sunny, 22 °C"
        return ToolResult(
            content: [.text(summary)],
            structuredContent: ["city": .string(city), "summary": .string(summary)]
        )
    }
}
```

Pass the provider when constructing an agent — see [Agents Overview](/agent-squad/swift/agents/overview/).

:::note[Argument extraction]
Use pattern matching on `JSONValue` cases (`case .string(let v) = arguments["key"]`) rather than force-casting. Return `.failure(...)` for missing or wrong-typed arguments so the model can self-correct.
:::

## Composing multiple providers

You don't need to hand-write a composite — [`AggregateToolProvider`](/agent-squad/swift/tools/overview/#aggregatetoolprovider-mixing-sources) is built in. It fans out `listTools` in parallel, deduplicates by name (first-wins), and routes each `call` to the owning provider:

```swift
let tools = AggregateToolProvider([
    myCustomProvider,
    ToolKit([localTool, apiTool]),
    MCPServer(url: "https://mcp/sse"),
])
```

:::caution[Name uniqueness]
Tools are deduplicated by name when lists are merged. If two providers advertise the same name, the first one (earlier in the array) wins. Keep tool names unique across all providers.
:::

## Controlling visibility

Use `ToolVisibility` to restrict who can invoke a tool:

```swift
AgentTool(
    name: "internal_audit_log",
    description: "Records an audit event.",
    visibility: .app          // never offered to the model; only callable by host code
)
```

| Value | Effect |
|-------|--------|
| `.model` | LLM may call it; host code may not |
| `.app` | Host code may call it; never offered to the LLM |
| `.all` | Both (default) |

## Using MCP tools alongside native tools

MCP-backed tools arrive as a `ToolProvider` (`MCPServer`) from the `AgentSquadMCP` module. Combine them with your native tools using `AggregateToolProvider`:

```swift
let tools = AggregateToolProvider([
    nativeProvider,                          // your custom ToolProvider
    MCPServer(url: "https://mcp/sse"),       // from AgentSquadMCP
])
```

See [MCP servers](/agent-squad/swift/mcp/overview/) for session setup. To plug a different MCP SDK or transport, conform your own type to `MCPClient` — see [Custom MCP client](/agent-squad/swift/mcp/custom/).
