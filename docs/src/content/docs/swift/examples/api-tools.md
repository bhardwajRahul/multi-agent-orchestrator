---
title: "Example: API tools"
description: A complete program turning REST endpoints into agent tools with HTTPToolGroup — no handler code.
---

Several REST endpoints declared as tools with one `HTTPToolGroup` — shared base URL, auth, host arguments, and response convention declared once. See [Local & HTTP tools](/agent-squad/swift/tools/built-in/local-http/) for the API.

```swift
import Foundation
import AgentSquad

@main
struct APIToolsDemo {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["OPENAI_API_KEY"] ?? ""
        let model = ChatCompletionsClient(model: "gpt-4o-mini", apiKey: apiKey)

        // Declare the whole API once.
        let jsa = HTTPToolGroup(
            baseURL: "https://api.example.com",
            headers: ["X-Match-Id": env["MATCH_ID"] ?? "1153385758023680"],
            secrets: ["Authorization": "Bearer \(env["JSA_KEY"] ?? "")"],     // never seen by the model
            hostArguments: ["session_id": .string(env["SESSION_ID"] ?? "demo")], // injected per call, hidden from the schema
            response: .jsonEnvelopeError                                        // 200 + {error_code} → tool failure
        )

        // One line per endpoint.
        let tools = ToolKit(
            jsa.get("get_lineup", "/lineup", "Starting XI and formations."),
            jsa.get("player_details", "/player-details", "A player's betting markets.",
                    .string("player", required: true), .string("team", required: true)),
            jsa.get("team_stats", "/team-stats", "Team form & stats.", .string("team_id", required: true))
        )

        let agent = Agent(name: "football", description: "Match assistant.", model: model, tools: tools)
        let context = AgentContext(userId: "demo", sessionId: "s1")

        for try await event in agent.process(.text("Who starts for France, and how is their recent form?"), history: [], context: context) {
            switch event {
            case .textDelta(let token): print(token, terminator: "")
            case .toolCall(_, let name, _): print("\n[tool] \(name)")
            default: break
            }
        }
        print("")
    }
}
```

`get_lineup` sends `X-Match-Id` as a header; `player_details`/`team_stats` map their arguments to query items; `session_id` is injected on every call and hidden from the model.

## Tools from several hosts

APIs rarely all live on one host. Use **one `HTTPToolGroup` per host** (each with its own base URL, auth, and response convention), and `Tool.get(fullURL:)` for one-off endpoints — then combine them all in a single `ToolKit`. The agent sees one flat tool list and never knows they span different hosts.

```swift
import Foundation
import AgentSquad

@main
struct MultiHostDemo {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = ChatCompletionsClient(model: "gpt-4o-mini", apiKey: env["OPENAI_API_KEY"] ?? "")

        // Host 1 — your football API: several endpoints, shared bearer auth + error convention.
        let football = HTTPToolGroup(
            baseURL: "https://football.example.com/v1",
            secrets: ["Authorization": "Bearer \(env["FOOTBALL_KEY"] ?? "")"],
            response: .jsonEnvelopeError
        )

        // Host 2 — a public weather API: different host, key injected as a query arg, hidden from the model.
        let weather = HTTPToolGroup(
            baseURL: "https://api.weather.example",
            hostArguments: ["appid": .string(env["WEATHER_KEY"] ?? "")]
        )

        let tools = ToolKit(
            football.get("get_lineup", "/lineup/{matchId}", "Starting XI.", .string("matchId", required: true)),
            football.get("team_stats", "/teams/{teamId}/stats", "Team form.", .string("teamId", required: true)),
            weather.get("forecast", "/forecast", "Weather for a city.", .string("city", required: true)),
            // Host 3 — a one-off endpoint on yet another host: full URL, no group needed.
            Tool.get("fx_rate", "https://fx.example.org/latest", "Currency conversion rate.",
                     .string("from", required: true), .string("to", required: true))
        )

        let agent = Agent(name: "match-day", description: "Match-day assistant.", model: model, tools: tools)
        let context = AgentContext(userId: "demo", sessionId: "s1")
        for try await event in agent.process(.text("Lineups for match 123 and the weather there?"), history: [], context: context) {
            if case .textDelta(let token) = event { print(token, terminator: "") }
        }
        print("")
    }
}
```

Each group keeps its own base URL and credentials, so `FOOTBALL_KEY` never reaches the weather host and vice versa. Next: [MCP server](/agent-squad/swift/examples/mcp-server/).
