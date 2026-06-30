---
title: Composing providers
description: AggregateToolProvider — give an agent a mix of local, HTTP, and MCP tools behind one seam.
---

`AggregateToolProvider` composes several `ToolProvider`s behind one. `listTools` fans out in parallel and merges the results, deduplicating by name with **first-wins** (earlier providers shadow later ones); `call` routes to the provider that owns the name.

```swift
public actor AggregateToolProvider: ToolProvider {
    public init(_ providers: [any ToolProvider])
    public init(_ providers: any ToolProvider...)   // variadic
}
```

This is the recommended way to give an agent a mix of local tools, your own APIs, and third-party MCP servers at once.

## Mixing local + API + MCP

```swift
import AgentSquad
import AgentSquadMCP

let agent = Agent(
    name: "Assistant",
    description: "Sports assistant.",
    model: model,
    tools: AggregateToolProvider(
        ToolKit(
            .local(name: "current_time", description: "ISO-8601 now.") { _ in
                ToolResult(content: [.text(ISO8601DateFormatter().string(from: .now))])
            },
            Tool.get("get_odds", "https://api.example.com/odds/{matchId}", "Live odds.", .string("matchId", required: true))
        ),
        MCPServer(url: "https://mcp.example.com/sse")   // third-party MCP tools
    )
)
```

The agent sees one flat tool list and routes each call automatically — it never knows that `current_time` is local code, `get_odds` is an HTTP call, and the rest came from MCP.

:::note[Name uniqueness and failures]
Tools are deduplicated by name (first provider wins). Keep names unique across providers. If any provider's `listTools` throws, the aggregate `listTools` throws too — a provider's tools are never silently dropped.
:::

See [Local & HTTP tools](/agent-squad/swift/tools/built-in/local-http/) for `ToolKit`/`Tool.get`, and [MCP servers](/agent-squad/swift/mcp/overview/) for `MCPServer`.
