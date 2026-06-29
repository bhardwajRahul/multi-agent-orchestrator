---
title: Custom Tools
description: Implement the ToolProvider protocol in native Swift to give agents access to any API or business logic.
---

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

Fan out across several providers behind a single `ToolProvider` seam:

```swift
struct CompositeToolProvider: ToolProvider {
    let providers: [any ToolProvider]

    func listTools() async throws -> [AgentTool] {
        try await providers.asyncFlatMap { try await $0.listTools() }
    }

    func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        for provider in providers {
            let available = try await provider.listTools()
            if available.contains(where: { $0.name == name }) {
                return try await provider.call(name, arguments: arguments)
            }
        }
        return .failure("Unknown tool: \(name)")
    }
}
```

:::caution[Name uniqueness]
The agent deduplicates tools by name when merging lists. If two providers advertise the same name, the first one wins. Keep tool names unique across all providers in a composite.
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

MCP-backed tools arrive as a `ToolProvider` from the `AgentSquadMCP` module. Wrap them together with your native provider in a `CompositeToolProvider`:

```swift
let composite = CompositeToolProvider(providers: [
    nativeProvider,
    mcpProvider          // from AgentSquadMCP
])
```

See [MCP Overview](/agent-squad/swift/mcp/overview/) for session setup.
