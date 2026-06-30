---
title: MCP Overview
description: Connect any MCP server as a ToolProvider using the separate AgentSquadMCP module.
---

`AgentSquadMCP` is a separate Swift package product that wraps the [official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) and exposes any MCP server as a `ToolProvider` you hand directly to an agent. The `AgentSquad` core stays dependency-free; add `AgentSquadMCP` only to targets that need it.

```swift
// Package.swift — add the product alongside AgentSquad
.product(name: "AgentSquadMCP", package: "agent-squad")
```

## What it provides

`MCPToolProvider` is a `ToolProvider` backed by an MCP server. Pass it to any [Agent](/agent-squad/swift/agents/built-in/agent/) as `toolProvider:` and the orchestrator can invoke every tool the server advertises.

`MCPServer` is a typealias for `MCPToolProvider`. Both names refer to the same type; use whichever reads better at the call site.

```swift
import AgentSquad
import AgentSquadMCP

let tools = MCPServer(url: "https://mcp.example.com/sse")

let agent = Agent(
    name: "Assistant",
    description: "General assistant with MCP tools.",
    model: model,
    toolProvider: tools
)
```

The provider connects lazily on first use and holds the connection for its lifetime. You do not call `connect()` directly.

## Initializers

### `MCPServer(url:)` — String overload

```swift
public init(
    url urlString: String,
    hostArguments: [String: JSONValue] = [:],
    clientName: String = SDKMCPClient.defaultClientName,   // "AgentSquad"
    clientVersion: String = SDKMCPClient.defaultClientVersion, // "0.1.0"
    tokenProvider: (@Sendable () async -> String?)? = nil,
    streaming: Bool = true
)
```

:::caution[Invalid URL string]
An invalid URL string traps at runtime via `preconditionFailure` — this is a configuration mistake caught on first run. Use the `URL` overload if you are constructing the URL programmatically.
:::

### `MCPServer(url:)` — URL overload

```swift
public init(
    url: URL,
    hostArguments: [String: JSONValue] = [:],
    clientName: String = SDKMCPClient.defaultClientName,
    clientVersion: String = SDKMCPClient.defaultClientVersion,
    tokenProvider: (@Sendable () async -> String?)? = nil,
    streaming: Bool = true
)
```

Both convenience overloads create an `SDKMCPClient` internally. For a custom transport or a test double, use the lower-level initializer instead:

```swift
public init(client: any MCPClient, hostArguments: [String: JSONValue] = [:])
```

## Authentication

### Bearer token (per-session)

Pass a `tokenProvider` closure. It is called once at connect and the token is fixed for the session. A mid-session `401` surfaces as a thrown error; `MCPToolProvider` recovers automatically by reconnecting, which triggers a fresh token fetch.

```swift
MCPServer(
    url: "https://mcp.example.com/sse",
    tokenProvider: { await TokenStore.shared.currentToken() }
)
```

:::note[Per-turn rotation]
`tokenProvider` is called once per connection, not once per call. For credentials that rotate faster than a session (rare), put the rotation logic inside the `MCPClient` implementation, not here.
:::

### Custom HTTP headers

Pass a `headers` dictionary to send additional headers on every request. Custom headers are applied before `Authorization`, so a `tokenProvider` cannot be clobbered by a caller-supplied header.

```swift
MCPServer(
    url: "https://mcp.example.com/sse",
    tokenProvider: { await resolveBearer() },
    headers: ["X-Match-Id": matchId]
)
```

Headers are captured at `connect` and fixed for the session — the same lifetime as the bearer token. To pick up a changed value, disconnect and reconnect.

:::note[Pending implementation]
The `headers:` parameter is specified and designed but not yet merged into main. The diff is in `FEATURE_MCP_CUSTOM_HEADERS.md`.
:::

## Host arguments

Some tool arguments should come from the host (session ID, tenant, …) and never from the model. Declare them in `hostArguments`:

```swift
MCPServer(
    url: "https://mcp.example.com/sse",
    hostArguments: ["session_id": .string(sessionId)],
    tokenProvider: { await resolveBearer() }
)
```

`MCPToolProvider` automatically:

1. Strips the declared keys from the schema before advertising tools to the model — the model never sees those parameters.
2. Injects the host values on every call, but only for keys the tool's schema explicitly declares (to avoid violating `additionalProperties: false` schemas).

:::caution[Flat scalars only]
Host arguments must be flat top-level scalars. A key declared only inside `oneOf`, `allOf`, `$ref`, or `$defs` is not hidden or injected. Host-argument values are fixed for the provider's lifetime; use `tokenProvider` for per-session credentials instead.
:::

## MCP Apps UI

When an MCP tool advertises a `_meta.ui.resourceUri` (a `ui://` URI), `MCPToolProvider` fetches the resource, caches it, and assembles a `UIPayload` on every `ToolResult`. The template is fetched lazily on first call and then served from an in-memory cache (templates are treated as static). `structuredContent` and `_meta` never reach the model's context; they travel to the UI host only.

See [Tool UIs](/agent-squad/swift/ui/overview/) for how the host app renders a `UIPayload`.

## Supporting types

### `MCPToolInfo`

A tool as advertised by the server, with UI metadata surfaced.

```swift
public struct MCPToolInfo: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let ui: String?              // _meta.ui.resourceUri, nil if no UI
    public let visibility: ToolVisibility

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        ui: String? = nil,
        visibility: ToolVisibility = .all
    )
}
```

### `MCPCallResult`

The result of a `tools/call`, split per MCP semantics.

```swift
public struct MCPCallResult: Sendable {
    public let content: [ContentPart]?        // text → model context
    public let structuredContent: JSONValue?  // data → UI, never modelled
    public let meta: JSONValue?               // _meta → UI only, never modelled
    public let isError: Bool

    public init(
        content: [ContentPart]? = nil,
        structuredContent: JSONValue? = nil,
        meta: JSONValue? = nil,
        isError: Bool = false
    )
}
```

`nil` for `structuredContent` distinguishes "no structured content returned" from an empty object. `MCPToolProvider` defaults a missing value to `{}` before building the `ToolResult`.

### `MCPResourceContents`

The contents of an MCP resource — used for `ui://` template fetches.

```swift
public struct MCPResourceContents: Sendable {
    public let mimeType: String
    public let text: String?
    public let blob: Data?        // decoded from base64 on receipt
    public let meta: JSONValue?   // _meta.ui (csp / permissions / domain / prefersBorder)

    public init(mimeType: String, text: String? = nil, blob: Data? = nil, meta: JSONValue? = nil)
}
```

### `MCPClientError`

Thrown (not returned as `ToolResult`) for infrastructure-level failures.

| Case | When |
|---|---|
| `.notConnected` | A call is attempted before `connect()` succeeds |
| `.emptyResource(String)` | `readResource` returns no content for the given URI |

These are transport/protocol errors, not tool-level failures. They propagate out of `MCPToolProvider.call(_:arguments:)` as thrown errors — the orchestrator's error-handling path applies.

## The `MCPClient` protocol

`MCPToolProvider` depends on this seam, not on the SDK directly. `SDKMCPClient` is the production implementation; conforming your own type to this protocol lets you plug a different SDK or inject a test double.

```swift
public protocol MCPClient: Sendable {
    func connect() async throws
    func listTools() async throws -> [MCPToolInfo]
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult
    func readResource(uri: String) async throws -> MCPResourceContents
    func disconnect() async
}
```

## Related pages

- [SDKMCPClient](/agent-squad/swift/mcp/built-in/sdk-client/) — the default client backed by the official MCP Swift SDK.
- [Custom MCP client](/agent-squad/swift/mcp/custom/) — plug a different SDK or add a test double by conforming to `MCPClient`.
- [Tools overview](/agent-squad/swift/tools/overview/) — the `ToolProvider` protocol and `ToolResult` that `MCPToolProvider` implements.
- [Tool UIs](/agent-squad/swift/ui/overview/) — rendering the `UIPayload` assembled from MCP Apps UI resources.
- [Agents](/agent-squad/swift/agents/overview/) — passing a `ToolProvider` to an agent.
- [Tracing](/agent-squad/swift/tracing/overview/) — observing tool calls inside a turn.
