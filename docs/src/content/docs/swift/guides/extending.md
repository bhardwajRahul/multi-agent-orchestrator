---
title: Extending the framework
description: Every part of AgentSquad is a protocol you can implement yourself — agents, routing, tools, storage, LLM connectors, tracing, voice transport, and audio I/O.
---

AgentSquad is protocol-first: nearly every moving part is an interface with a built-in conformance
you can swap out. If a built-in doesn't fit, implement the protocol and pass your type in — nothing
else changes.

Each area has an **Overview** (the protocol), one or more **Built-in** pages, and a **Custom** page
with a worked, compile-ready implementation.

| You want to customize | Protocol | Built-in(s) | Custom example |
|---|---|---|---|
| **An agent** (own model loop, rules, API) | `AgentProtocol` | [Agent](/agent-squad/swift/agents/built-in/agent/), [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/) | [Custom agent](/agent-squad/swift/agents/custom/) |
| **Routing** between agents | `Classifier` | [LLMClassifier](/agent-squad/swift/classifiers/built-in/llm-classifier/) | [Custom classifier](/agent-squad/swift/classifiers/custom/) |
| **Tools** from any source | `ToolProvider` | [MCP](/agent-squad/swift/mcp/overview/), native Swift | [Custom tool provider](/agent-squad/swift/tools/custom/) |
| **A different MCP SDK** | `MCPClient` | [SDKMCPClient](/agent-squad/swift/mcp/built-in/sdk-client/) | [Custom client](/agent-squad/swift/mcp/custom/) |
| **An LLM connector** (non-OpenAI API) | `LLMClient` | [ChatCompletionsClient](/agent-squad/swift/llm/built-in/chat-completions/) | [Custom connector](/agent-squad/swift/llm/custom/) |
| **The HTTP layer** under the OpenAI client | `ChatCompletionsTransport` | URLSession default | [Custom connector](/agent-squad/swift/llm/custom/) |
| **Chat persistence** | `ChatStorage` | [In-memory](/agent-squad/swift/storage/built-in/in-memory/), [File](/agent-squad/swift/storage/built-in/file/), [Device](/agent-squad/swift/storage/built-in/device/) | [Custom store](/agent-squad/swift/storage/custom/) |
| **Where traces go** | `Tracer` | [OSLogTracer](/agent-squad/swift/tracing/built-in/oslog-tracer/), [ProcessingTracer](/agent-squad/swift/tracing/built-in/processing-tracer/) | [Custom tracing](/agent-squad/swift/tracing/custom/) |
| **Span export** | `TraceExporter` | [OTLPExporter](/agent-squad/swift/tracing/built-in/otlp-exporter/) | [Custom tracing](/agent-squad/swift/tracing/custom/) |
| **Span batching/processing** | `SpanProcessor` | [BatchSpanProcessor](/agent-squad/swift/tracing/built-in/batch-span-processor/) | [Custom tracing](/agent-squad/swift/tracing/custom/) |
| **Redacting trace data** | `Redactor` | default | [Custom tracing](/agent-squad/swift/tracing/custom/) |
| **Shaping tool output for the presenter** | `ToolOutputCurator` | [DataBlock/PerTool curators](/agent-squad/swift/ui/built-in/curators/) | [Custom curator](/agent-squad/swift/ui/custom/) |
| **The realtime voice socket** | `RealtimeTransport` | [WebSocket transport](/agent-squad/swift/voice/built-in/websocket-transport/) | [Custom transport](/agent-squad/swift/voice/custom/) |
| **Audio capture / playback** | `AudioInput` / `AudioOutput` | [MicCapture](/agent-squad/swift/audio/built-in/mic-capture/), [AudioPlayback](/agent-squad/swift/audio/built-in/audio-playback/) | [Custom audio](/agent-squad/swift/audio/custom/) |

## The shape of every extension

All three runtimes follow the same contract: implement the protocol, hand the instance to the type
that consumes it (the `Orchestrator`, an agent, or a voice assistant), and the framework treats your
type exactly like a built-in. Protocols are `Sendable` (often `Actor`-bound) so your conformance must
honor the declared concurrency — match the `async`/`throws`/isolation annotations in the source.

:::note
The core `AgentSquad` module has **no external dependencies**. A custom conformance lives in your own
code and pulls in only what *you* import — the framework never grows a dependency on your behalf.
:::
