---
title: "Example: Local tool"
description: A complete program giving an agent local Swift tools via ToolKit and Tool.local.
---

Two local tools (a clock and an adder) in a `ToolKit`, wired to an `Agent`, running one turn. See [Local & HTTP tools](/agent-squad/swift/tools/built-in/local-http/) for the API.

```swift
import Foundation
import AgentSquad

@main
struct LocalToolDemo {
    static func main() async throws {
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        let model = ChatCompletionsClient(model: "gpt-4o-mini", apiKey: apiKey)

        let tools = ToolKit(
            .local(name: "current_time", description: "The current UTC time (ISO-8601).") { _ in
                ToolResult(content: [.text(ISO8601DateFormatter().string(from: Date()))])
            },
            .local(
                name: "add",
                description: "Adds two integers.",
                inputSchema: [
                    "type": "object",
                    "properties": ["a": ["type": "integer"], "b": ["type": "integer"]],
                    "required": ["a", "b"],
                ]
            ) { args in
                let sum = (args["a"]?.intValue ?? 0) + (args["b"]?.intValue ?? 0)
                return ToolResult(content: [.text("\(sum)")], structuredContent: ["sum": .int(sum)])
            }
        )

        let agent = Agent(name: "helper", description: "Local utilities.", model: model, tools: tools)
        let context = AgentContext(userId: "demo", sessionId: "s1")

        for try await event in agent.process(.text("What time is it, and what is 2 + 3?"), history: [], context: context) {
            if case .textDelta(let token) = event { print(token, terminator: "") }
        }
        print("")
    }
}
```

The agent calls `current_time` and `add` itself as it answers; the handler's `ToolResult` text feeds back into the model. Next: [API tools](/agent-squad/swift/examples/api-tools/).
