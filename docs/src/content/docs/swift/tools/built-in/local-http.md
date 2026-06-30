---
title: Local & HTTP tools
description: ToolKit, Tool.local, Tool.http, HTTPToolGroup and the parameter DSL — native tools with minimal code.
---

`ToolKit` is a built-in `ToolProvider` over a fixed list of `Tool`s. Each `Tool` is either **local** (a Swift closure) or **HTTP** (a declarative API call) — mix them freely in one kit. It's an immutable value, so an agent calls it with no actor hop.

```swift
public struct ToolKit: ToolProvider {
    public init(_ tools: [Tool])
    public init(_ tools: Tool...)   // variadic
}
```

For the core primitives (`AgentTool`, `ToolResult`, `JSONValue`, `ToolVisibility`), see [Tools Overview](/agent-squad/swift/tools/overview/).

## `Tool.local` — backed by Swift code

```swift
let now = Tool.local(name: "current_time", description: "ISO-8601 now.") { _ in
    ToolResult(content: [.text(ISO8601DateFormatter().string(from: .now))])
}
```

The handler receives the model's arguments as a `JSONValue` and returns a `ToolResult`. Return `ToolResult.failure(_:)` for a recoverable, tool-level error; `throw` only for infrastructure failures.

## `Tool.http` — backed by an API

`Tool.http` turns an `HTTPToolSpec` into a tool with **no handler code**. Arguments map into the request by convention:

- `{token}` placeholders in `url` are filled from the matching argument (percent-encoded) and consumed.
- Leftover arguments become **query items** for `GET`/`HEAD`/`DELETE`, or a **JSON body** for `POST`/`PUT`/`PATCH`.

```swift
public struct HTTPToolSpec: Sendable {
    public init(
        method: HTTPMethod,
        url: String,                              // optionally templated with {token}
        headers: [String: String] = [:],         // static headers
        secrets: [String: String] = [:],         // header field→value, kept out of header traces
        hostArguments: [String: JSONValue] = [:], // injected per call, hidden from the model's schema
        body: HTTPBody = .auto,
        response: ResponseMapping = .standard,
        timeout: TimeInterval = 30,
        invoker: any HTTPInvoker = URLSessionInvoker()
    )
}
```

The default `ResponseMapping.standard` maps a 2xx body to the model's `content` and parses JSON into `structuredContent`; a non-2xx becomes a tool-level error.

:::note[Credentials never reach the model]
Put static auth in `headers` (or `secrets`, which is also kept out of header traces). Use `hostArguments` for values the host supplies on every call (e.g. `session_id`) — they're injected into the request **and stripped from the schema the model sees**, mirroring `MCPServer`.
:::

:::tip[Testing HTTP tools]
`HTTPToolSpec` sends through an injectable `HTTPInvoker` (default `URLSessionInvoker`). Pass a mock conforming to `HTTPInvoker` to test argument mapping and response handling with no network.
:::

## Less boilerplate: parameters, verb factories, and groups

You rarely need to write raw JSON Schema or nest `HTTPToolSpec` by hand.

**Parameter DSL** — describe arguments instead of hand-writing schema. The `Tool` factories accept `ToolParameter`s and build the `inputSchema` for you:

```swift
.string("city", "City name", required: true)   // → {"type":"string","description":"City name"}
.integer("limit")                               // optional
.string("mode", values: ["fast", "full"])      // enum
.raw("filters", customSchema)                   // escape hatch for nested/exotic shapes
```

**Verb factories** — `Tool.get`/`.post`/`.put`/`.delete` collapse the nested `HTTPToolSpec`:

```swift
let weather = Tool.get(
    "get_weather", "https://api.example.com/weather/{city}", "Weather for a city.",
    .string("city", required: true)
)
```

**`HTTPToolGroup`** — when many endpoints share a base URL, headers, credentials, and response convention, declare them **once**; each endpoint is then one line:

```swift
let api = HTTPToolGroup(
    baseURL: "https://api.example.com",
    headers: ["X-Tenant": tenant],
    secrets: ["Authorization": "Bearer \(token)"],
    hostArguments: ["session_id": .string(sessionId)],
    response: .jsonEnvelopeError          // built-in preset, see below
)

let tools = ToolKit([
    api.get("get_weather", "/weather/{city}", "Weather.", .string("city", required: true)),
    api.get("get_odds",    "/odds/{matchId}", "Live odds.", .string("matchId", required: true)),
])
```

**Response presets** — `ResponseMapping.standard` (2xx → content, non-2xx → error) is the default. For APIs that always return `200 OK` and signal failure with an error field in the body, use `ResponseMapping.jsonEnvelopeError` (or `jsonEnvelope(errorKey:messageKey:)` to name the fields). Drop to `.custom { response in … }` for full control.

:::note[Optional output schema]
Every factory takes an optional `outputSchema:` (a `JSONValue` JSON Schema for the result). It's **advisory** — documents the `structuredContent` shape for UI/curator code and mirrors MCP `outputSchema`. It is **not** sent to the model. Leave it `nil` unless something downstream consumes it.
:::

## Examples

### A whole API with `HTTPToolGroup` (recommended)

Declare the shared configuration once; each endpoint is one line. This is the least code for the common "I have several endpoints on one API" case.

```swift
import AgentSquad

let api = HTTPToolGroup(
    baseURL: "https://api.example.com",
    headers: ["X-Match-Id": matchId],                 // shared on every call
    secrets: ["Authorization": "Bearer \(apiKey)"],   // never seen by the model
    hostArguments: ["session_id": .string(sessionId)], // injected per call, hidden from the schema
    response: .jsonEnvelopeError                       // 200 + {error_code} → tool failure
)

let agent = Agent(
    name: "Football", description: "Match assistant.", model: model,
    tools: ToolKit(
        api.get("web_research",   "/web-research",   "News, injuries, probable lineups.",
                .string("query", required: true), .string("team1", required: true), .string("team2", required: true)),
        api.get("get_lineup",     "/lineup",         "Starting XI and formations."),
        api.get("player_details", "/player-details", "A player's betting markets.",
                .string("player", required: true), .string("team", required: true)),
        api.get("team_stats",     "/team-stats",     "Team form & stats.", .string("team_id", required: true))
    )
)
```

### Local tools only

```swift
import AgentSquad

let tools = ToolKit(
    .local(name: "current_time", description: "ISO-8601 now.") { _ in
        ToolResult(content: [.text(ISO8601DateFormatter().string(from: .now))])
    },
    .local(
        name: "add", description: "Adds two integers.",
        inputSchema: ["type": "object", "properties": ["a": ["type": "integer"], "b": ["type": "integer"]], "required": ["a", "b"]]
    ) { args in
        let sum = (args["a"]?.intValue ?? 0) + (args["b"]?.intValue ?? 0)
        return ToolResult(content: [.text("\(sum)")], structuredContent: ["sum": .int(sum)])
    }
)

let agent = Agent(name: "Helper", description: "Local utilities.", model: model, tools: tools)
```

### A POST tool with a custom response mapping

```swift
let placeBet = Tool.post(
    "place_bet", "https://api.example.com/bets", "Place a bet.",
    .string("selection", required: true), .number("stake", required: true),
    secrets: ["Authorization": "Bearer \(apiKey)"],
    response: .custom { response in
        guard response.isSuccess else { return .failure("Bet rejected (HTTP \(response.status)).") }
        let body = try response.json()
        return ToolResult(content: [.text("Bet placed — ref \(body["reference"]?.stringValue ?? "unknown").")], structuredContent: body)
    }
)
```

To combine these with MCP tools, see [Composing providers](/agent-squad/swift/tools/built-in/composing/).
