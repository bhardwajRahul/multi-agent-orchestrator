---
title: "Example: MCP server"
description: A complete program giving an agent tools from a remote MCP server, run through the Orchestrator.
---

Tools from a remote MCP server via `MCPServer(url:)`, run through the `Orchestrator` (which fetches history, runs the agent, and persists the turn). See [MCP servers](/agent-squad/swift/mcp/overview/) for session setup.

```swift
import Foundation
import AgentSquad
import AgentSquadMCP

@main
struct MCPDemo {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let apiKey = env["OPENAI_API_KEY"] ?? ""
        let model = ChatCompletionsClient(model: "gpt-4o-mini", apiKey: apiKey)

        // Connects lazily on first use. Auth rides as a header; session_id is injected per call and
        // hidden from the model's schema.
        let tools = MCPServer(
            url: env["MCP_URL"] ?? "https://mcp.example.com/sse",
            hostArguments: ["session_id": .string(env["SESSION_ID"] ?? "demo")],
            headers: ["Authorization": "Bearer \(env["MCP_TOKEN"] ?? "")"]
        )

        let agent = Agent(name: "assistant", description: "Assistant with MCP tools.", model: model, tools: tools)
        let store = try DeviceChatStorage(userId: "demo", inMemory: true)
        let orchestrator = Orchestrator(agents: [agent], store: store)

        for try await event in orchestrator.route(.text("What can you help me with?"), userId: "demo", sessionId: "s1") {
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

The `Orchestrator` with a single agent and no classifier routes every turn to that agent — the standard entry point even without multi-agent routing. To combine MCP tools with local/HTTP tools, wrap them in an [`AggregateToolProvider`](/agent-squad/swift/tools/built-in/composing/).
