---
title: Custom MCP client
description: Conform your own type to MCPClient to plug a different MCP SDK or inject a test double.
---

`MCPToolProvider` depends on the `MCPClient` protocol, not on the official MCP Swift SDK directly. Swap `SDKMCPClient` for any other transport by conforming your own type to `MCPClient` and passing it to `MCPToolProvider(client:)`.

The same pattern works for test doubles: a `struct` or `final class` conforming to `MCPClient` with hard-coded return values lets you test `MCPToolProvider` behavior — pagination, host-argument injection, UI assembly — without any network traffic.

## The `MCPClient` protocol

```swift
public protocol MCPClient: Sendable {
    /// Connect and perform the MCP `initialize` handshake.
    func connect() async throws
    func listTools() async throws -> [MCPToolInfo]
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult
    /// Read a `ui://` (or any) resource — used to fetch an advertised UI template.
    func readResource(uri: String) async throws -> MCPResourceContents
    /// Tear down the connection. Must be idempotent.
    func disconnect() async
}
```

All five methods are `async`; `connect`, `listTools`, `callTool`, and `readResource` are also `throws`. The type must be `Sendable`. An `actor` is the natural fit because real implementations are stateful — they hold a live connection.

## Full conformance example

```swift
import Foundation
import AgentSquad
import AgentSquadMCP

/// A custom MCP client backed by a different transport.
/// Replace the bodies with your SDK's equivalents.
public actor MyMCPClient: MCPClient {

    private let endpoint: URL

    public init(endpoint: URL) {
        self.endpoint = endpoint
    }

    // MARK: - MCPClient

    /// Connect and perform the MCP `initialize` handshake.
    public func connect() async throws {
        // e.g. try await mySDK.connect(to: endpoint)
    }

    /// List every tool the server advertises, paginating to completion.
    public func listTools() async throws -> [MCPToolInfo] {
        // e.g. let sdkTools = try await mySDK.listTools()
        // return sdkTools.map { tool in
        //     MCPToolInfo(
        //         name: tool.name,
        //         description: tool.description ?? "",
        //         inputSchema: /* convert to JSONValue */,
        //         ui: /* _meta.ui.resourceUri or nil */,
        //         visibility: .all
        //     )
        // }
        return []
    }

    /// Invoke a tool and return the structured result.
    public func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        // e.g. let response = try await mySDK.callTool(name: name, arguments: arguments)
        // return MCPCallResult(
        //     content: /* [ContentPart] or nil */,
        //     structuredContent: /* JSONValue or nil */,
        //     meta: nil,
        //     isError: response.isError ?? false
        // )
        return MCPCallResult()
    }

    /// Fetch an MCP resource — used for `ui://` UI template fetches.
    public func readResource(uri: String) async throws -> MCPResourceContents {
        // e.g. let raw = try await mySDK.readResource(uri: uri)
        // return MCPResourceContents(mimeType: raw.mimeType, text: raw.text)
        return MCPResourceContents(mimeType: "text/plain")
    }

    /// Tear down the connection. Must be idempotent.
    public func disconnect() async {
        // e.g. await mySDK.disconnect()
    }
}
```

## Wiring the custom client

Construct `MCPToolProvider` (or its `MCPServer` alias) with the lower-level initializer — the same one the URL convenience inits delegate to internally:

```swift
let client = MyMCPClient(endpoint: URL(string: "https://mcp.example.com/sse")!)

let tools = MCPToolProvider(
    client: client,
    hostArguments: ["session_id": .string(sessionId)]
)

let agent = Agent(
    name: "Assistant",
    description: "General assistant with MCP tools.",
    model: model,
    toolProvider: tools
)
```

## Test double

For unit tests, a `struct` or `final class` is sufficient — no network, no state:

```swift
import AgentSquadMCP

struct MockMCPClient: MCPClient {
    func connect() async throws {}
    func listTools() async throws -> [MCPToolInfo] {
        [MCPToolInfo(name: "echo", description: "Echoes input", inputSchema: .object([:]))]
    }
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        MCPCallResult(content: [.text("ok")], isError: false)
    }
    func readResource(uri: String) async throws -> MCPResourceContents {
        MCPResourceContents(mimeType: "text/html", text: "<p>template</p>")
    }
    func disconnect() async {}
}

// In your test:
let tools = MCPToolProvider(client: MockMCPClient())
```

:::note[Pagination]
`MCPToolProvider` calls `listTools()` and assembles the result itself; it does not page on your behalf. If your custom client's server paginates, implement cursor-following inside `listTools()` as `SDKMCPClient` does.
:::

:::note[Reconnect path]
`MCPToolProvider` calls `connect()` once, lazily on first use, and does not call it again unless it detects a mid-session failure and triggers a reconnect. Make `connect()` idempotent (a second call on an already-connected client is a no-op) and `disconnect()` idempotent too (safe to call more than once).
:::

## Related pages

- [MCP overview](/agent-squad/swift/mcp/overview/) — `MCPToolProvider`, `MCPServer`, supporting types, host arguments, and the full protocol definition.
- [SDKMCPClient](/agent-squad/swift/mcp/built-in/sdk-client/) — the default implementation you are replacing.
- [Tools overview](/agent-squad/swift/tools/overview/) — the `ToolProvider` protocol and `ToolResult`.
