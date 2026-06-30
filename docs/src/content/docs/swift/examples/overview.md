---
title: Examples
description: Complete, runnable AgentSquad programs — local tools, HTTP APIs, and MCP servers, end to end.
---

Short, **complete** programs you can drop into an executable SwiftPM target and run. Unlike the focused snippets on the capability pages, each example here is a whole program: imports, model, tools, agent, and one turn streamed to stdout.

| Example | Shows |
|---------|-------|
| [Local tool](/agent-squad/swift/examples/local-tool/) | `ToolKit` + `Tool.local` — Swift functions as tools |
| [API tools](/agent-squad/swift/examples/api-tools/) | `HTTPToolGroup` — REST endpoints as tools, no handler code |
| [MCP server](/agent-squad/swift/examples/mcp-server/) | `MCPServer(url:)` + `Orchestrator` — tools from a remote MCP server |

## Running an example

Add an executable target that depends on `AgentSquad` (and `AgentSquadMCP` for the MCP example):

```swift
// Package.swift
.executableTarget(name: "demo", dependencies: [
    .product(name: "AgentSquad", package: "agent-squad"),
])
```

Then set your key and run:

```bash
OPENAI_API_KEY=sk-… swift run demo
```

Each example reads `OPENAI_API_KEY` from the environment and points `ChatCompletionsClient` at OpenAI by default — pass a `baseURL:` to target Azure, OpenRouter, Groq, or a local Ollama/llama.cpp.
