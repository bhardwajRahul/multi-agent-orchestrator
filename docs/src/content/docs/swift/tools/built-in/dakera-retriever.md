---
title: Dakera retriever
description: DakeraRetriever — ground answers on a self-hosted Dakera memory server, as a tool provider or a direct API.
---

`DakeraRetriever` is a `ToolProvider` backed by a self-hosted [Dakera](https://dakera.ai) memory server. Dakera adds **persistent, decay-weighted vector recall** across sessions: memories are importance-scored and decay over time, so stale context stops competing with fresh, relevant facts. It runs beside your app; no framework code changes are required to adopt it.

The Swift SDK grounds answers through tools (see [GroundedAgent](/swift/agents/built-in/grounded-agent)), so retrieval is exposed the native way — a `search_memory` tool the gatherer can call. The same type also offers a direct `retrieve(_:)` API when you'd rather fetch context yourself.

It talks to Dakera's text-query endpoint (server-side embedding) over `URLSession` — no third-party SDK is added to your package.

## Configuration

```swift
public struct DakeraRetrieverOptions: Sendable {
    public var namespace: String        // the Dakera namespace to query
    public var apiKey: String?          // falls back to the DAKERA_API_KEY env var
    public var url: String              // falls back to DAKERA_URL, then http://localhost:3000
    public var topK: Int                // max results, default 10
    public var filter: JSONValue?       // optional Dakera metadata filter
    public var timeout: TimeInterval    // request timeout, default 30s
    public var toolName: String         // tool name advertised to the model, default "search_memory"
    public var toolDescription: String  // tool description advertised to the model
}
```

`apiKey` resolves from the `DAKERA_API_KEY` environment variable and `url` from `DAKERA_URL` (defaulting to `http://localhost:3000`, the [`dakera-deploy`](https://github.com/dakera-ai/dakera-deploy) default), so you can keep credentials out of source.

## As a tool provider

Hand the retriever to a `GroundedAgent` (or `Agent`) and the model can call `search_memory` to ground its answers on remembered facts:

```swift
import AgentSquad

let memory = DakeraRetriever(namespace: "user-123", topK: 5)   // reads DAKERA_API_KEY / DAKERA_URL

let agent = GroundedAgent(
    name: "Assistant",
    description: "Answers using the user's remembered context.",
    gatherer: gathererModel,
    presenter: presenterModel,
    tools: memory
)
```

To offer memory alongside other tools, compose it with [`AggregateToolProvider`](/swift/tools/built-in/composing):

```swift
let agent = Agent(
    name: "Assistant",
    model: model,
    tools: AggregateToolProvider(memory, myOtherTools)
)
```

## Direct retrieval

When you want the context yourself — to build a prompt, rank candidates, or feed another component — call `retrieve` directly:

```swift
let memory = DakeraRetriever(
    namespace: "user-123",
    apiKey: "dk-...",                 // or set DAKERA_API_KEY
    url: "http://localhost:3000",     // or set DAKERA_URL
    topK: 5
)

let documents = try await memory.retrieve("What are the user's dietary preferences?")
for document in documents {
    print(document.score, document.content)   // also: document.id, document.metadata
}

// Or get the matched text joined into one string:
let context = try await memory.retrieveAndCombineResults("dietary preferences")
```

An optional metadata `filter` narrows the query:

```swift
let recent = DakeraRetriever(
    namespace: "user-123",
    topK: 5,
    filter: ["topic": "nutrition"]
)
```

## Self-hosting Dakera

Run the server with the [`dakera-ai/dakera-deploy`](https://github.com/dakera-ai/dakera-deploy) docker-compose (the server listens on port `3000`). Point `DAKERA_URL` at it and set `DAKERA_API_KEY`, and the retriever is ready.
