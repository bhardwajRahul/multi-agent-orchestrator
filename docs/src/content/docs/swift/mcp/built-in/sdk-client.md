---
title: SDKMCPClient
description: The default MCPClient implementation, backed by the official MCP Swift SDK.
---

`SDKMCPClient` is the production `MCPClient` that ships with `AgentSquadMCP`. It wraps the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (`Client` + `HTTPClientTransport`) and confines the SDK entirely to this type — nothing above the [`MCPClient`](/agent-squad/swift/mcp/overview/#the-mcpclient-protocol) seam ever imports it.

You rarely construct `SDKMCPClient` directly. The `MCPServer(url:)` convenience initializers create one for you. Use the direct initializer only when you need to customize `clientName`, `clientVersion`, or `streaming` and then pass the client to `MCPToolProvider(client:)`.

## Initializer

```swift
public init(
    endpoint: URL,
    clientName: String = SDKMCPClient.defaultClientName,     // "AgentSquad"
    clientVersion: String = SDKMCPClient.defaultClientVersion, // "0.1.0"
    tokenProvider: (@Sendable () async -> String?)? = nil,
    streaming: Bool = true
)
```

| Parameter | Default | Notes |
|---|---|---|
| `endpoint` | — | The MCP server URL |
| `clientName` | `"AgentSquad"` | Identity sent on the MCP `initialize` handshake |
| `clientVersion` | `"0.1.0"` | Identity sent on the MCP `initialize` handshake |
| `tokenProvider` | `nil` | Async closure returning a Bearer token; called once per `connect()` |
| `streaming` | `true` | Whether the transport uses HTTP streaming |

### Default identity constants

```swift
public static let defaultClientName    = "AgentSquad"
public static let defaultClientVersion = "0.1.0"
```

These constants are shared between `SDKMCPClient` and the `MCPServer(url:)` convenience initializers so the two construction paths never drift apart.

## Authentication

`SDKMCPClient` fetches the Bearer token from `tokenProvider` at `connect()` and injects it via the transport's synchronous `requestModifier`, making the token fixed for the session. A mid-session `401` surfaces as a thrown error from the call site; the `MCPToolProvider` recover path is `disconnect()` + `connect()`, which fetches a fresh token.

:::note[Per-session, not per-call]
`tokenProvider` is called once per `connect()`. For credentials that rotate faster than a session lifetime, put the rotation logic inside a custom `MCPClient` implementation rather than relying on this closure. See [Custom MCP client](/agent-squad/swift/mcp/custom/).
:::

## Pagination

`listTools()` paginates to completion automatically. It guards against cursor cycles (A → B → A) by tracking every cursor it has seen and breaking the loop on a repeat. No configuration is required.

## Error handling

`SDKMCPClient` throws `MCPClientError` for infrastructure-level failures:

| Case | When |
|---|---|
| `.notConnected` | A method is called before `connect()` succeeds |
| `.emptyResource(String)` | `readResource` returns no content for the given URI |

These are transport or protocol failures, not tool-level errors. They propagate as thrown errors; `MCPToolProvider` does not wrap them in a `ToolResult`.

## Usage

### Via the convenience initializers (typical)

The `MCPServer(url:)` overloads on `MCPToolProvider` construct an `SDKMCPClient` for you:

```swift
import AgentSquad
import AgentSquadMCP

// String overload
let tools = MCPServer(url: "https://mcp.example.com/sse")

// URL overload with auth
let tools = MCPServer(
    url: URL(string: "https://mcp.example.com/sse")!,
    tokenProvider: { await TokenStore.shared.currentToken() }
)
```

### Direct construction (custom identity or transport mode)

```swift
import AgentSquadMCP

let client = SDKMCPClient(
    endpoint: URL(string: "https://mcp.example.com/sse")!,
    clientName: "MyApp",
    clientVersion: "2.0.0",
    tokenProvider: { await TokenStore.shared.currentToken() },
    streaming: false   // fall back to request/response if SSE is not supported
)

let tools = MCPToolProvider(
    client: client,
    hostArguments: ["session_id": .string(sessionId)]
)
```

## Related pages

- [MCP overview](/agent-squad/swift/mcp/overview/) — `MCPToolProvider`, `MCPServer`, supporting types, host arguments, and MCP Apps UI.
- [Custom MCP client](/agent-squad/swift/mcp/custom/) — replace `SDKMCPClient` with your own transport or a test double.
- [Tools overview](/agent-squad/swift/tools/overview/) — the `ToolProvider` protocol that `MCPToolProvider` implements.
