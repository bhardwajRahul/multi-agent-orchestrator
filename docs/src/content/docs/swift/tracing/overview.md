---
title: Tracing Overview
description: The Tracer → SpanProcessor → TraceExporter pipeline, core protocols, and when to use each built-in.
---

AgentSquad ships an OpenTelemetry-style tracing pipeline. A `Tracer` opens spans, a `SpanProcessor` assembles and batches them, and a `TraceExporter` ships the finished `TraceEvent` records to a backend. Each layer is a protocol — swap any piece without touching the others.

## Pipeline

```
Tracer  ──► SpanProcessor  ──► TraceExporter
  │               │
  └─ SpanHandle   └─ BatchSpanProcessor (built-in)
```

**Local dev** — [`OSLogTracer`](/agent-squad/swift/tracing/built-in/oslog-tracer/) writes to `os.Logger`; no network, no configuration.

**Production** — [`ProcessingTracer`](/agent-squad/swift/tracing/built-in/processing-tracer/) + [`BatchSpanProcessor`](/agent-squad/swift/tracing/built-in/batch-span-processor/) + [`OTLPExporter`](/agent-squad/swift/tracing/built-in/otlp-exporter/) posts OTLP/HTTP JSON to any compatible collector.

## Tracer protocol

```swift
public protocol Tracer: Sendable {
    func startTrace(
        name: String,
        userId: String?,
        sessionId: String?,
        metadata: JSONValue?
    ) -> any SpanHandle

    func flush() async throws   // drain buffer on app-background
    func shutdown() async       // final drain + release resources
}
```

`startTrace` returns the root `SpanHandle`. Its `id` is the trace id — use it to deep-link into your backend.

`flush()` and `shutdown()` have no-op default implementations, so a simple tracer only needs `startTrace`.

:::caution
Nothing drains automatically on `ProcessingTracer`. Call `flush()` in your app's background handler and `shutdown()` on termination, or spans below the batch size are lost.
:::

## SpanHandle

```swift
public protocol SpanHandle: Sendable {
    var id: String { get }

    func span(_ name: String, input: JSONValue?) -> any SpanHandle
    func generation(_ name: String, model: String, input: JSONValue?) -> any GenerationHandle

    func setInput(_ input: JSONValue)
    func setMetadata(_ metadata: JSONValue)

    func end(output: JSONValue?, error: (any Error)?)
}
```

- `span` — opens a child span (a step, a tool call).
- `generation` — opens a child generation for an LLM call; pairs with `GenerationHandle.usage`.
- `setInput` / `setMetadata` — can be called any time before `end`. Useful when the input only arrives after the span opens (e.g. a transcript for a voice turn). Calls after `end` are silently dropped.
- `setMetadata` — takes a `.object` `JSONValue`; top-level keys become span attributes on the backend. On `OTLPExporter` the keys are emitted verbatim alongside the built-in GenAI attributes.

### GenerationHandle

```swift
public protocol GenerationHandle: SpanHandle {
    func usage(promptTokens: Int?, completionTokens: Int?)
}
```

Call `usage` after the LLM response arrives. `BatchSpanProcessor` merges the numbers into the span before it exports.

:::note
Parent spans are passed explicitly on `AgentContext` rather than via `@TaskLocal` because task-local values don't survive `AsyncThrowingStream` producer tasks.
:::

## SpanProcessor protocol

```swift
public protocol SpanProcessor: Sendable {
    func onOpen(_ span: SpanData)
    func onUsage(id: String, promptTokens: Int?, completionTokens: Int?)
    func onSetInput(id: String, input: JSONValue)    // no-op default
    func onSetMetadata(id: String, metadata: JSONValue) // no-op default
    func onEnd(id: String, endedAt: Date, output: JSONValue?, error: String?)
    func flush() async throws
    func shutdown() async
}
```

:::caution
The synchronous lifecycle hooks (`onOpen`, `onUsage`, `onSetInput`, `onSetMetadata`, `onEnd`) run on the agent's hot path. They must be non-blocking — buffer and return. Do not do network I/O or hold blocking locks in them.

Order within a span must be preserved (`onOpen` before `onEnd`). A per-message detached `Task` or unordered fan-out corrupts token attribution and parent linkage.
:::

## TraceExporter protocol

```swift
public protocol TraceExporter: Sendable {
    func export(_ batch: [TraceEvent]) async throws
    func flush() async throws
    func shutdown() async
}
```

`flush` and `shutdown` have no-op default implementations. Implement them if your exporter buffers internally.

## SpanData

`SpanData` is the snapshot handed to `SpanProcessor.onOpen` at span-open time. Usage, late input, and metadata arrive later via `onUsage` / `onSetInput` / `onSetMetadata`.

```swift
public struct SpanData: Sendable {
    public let id: String
    public let traceId: String
    public let parentId: String?
    public let kind: TraceEvent.Kind
    public let name: String
    public let startedAt: Date
    public let input: JSONValue?
    public let model: String?
    public let userId: String?
    public let sessionId: String?
    public let metadata: JSONValue?
}
```

## TraceEvent

`TraceEvent` is the finished, flat record handed to `TraceExporter` in batches. `BatchSpanProcessor` assembles it from `SpanData` plus any late mutations before export.

```swift
public struct TraceEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case trace        // root span
        case span         // step / tool call
        case generation   // LLM call
    }

    public enum Status: String, Sendable, Codable {
        case running
        case ok
        case error
    }

    public let traceId: String
    public let id: String
    public let parentId: String?
    public let kind: Kind
    public let name: String
    public let status: Status
    public let startedAt: Date
    public let endedAt: Date?
    public let input: JSONValue?
    public let output: JSONValue?
    public let error: String?
    public let model: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let userId: String?
    public let sessionId: String?
    public let metadata: JSONValue?
}
```

Serialized wire keys are snake_case (`trace_id`, `started_at`, `prompt_tokens`, etc.) regardless of any future property rename.

## Built-in implementations

| Implementation | Use case |
|---|---|
| [`OSLogTracer`](/agent-squad/swift/tracing/built-in/oslog-tracer/) | Local development — logs to Console.app / Instruments, no network |
| [`ProcessingTracer`](/agent-squad/swift/tracing/built-in/processing-tracer/) | Production — routes spans through a `SpanProcessor` |
| [`BatchSpanProcessor`](/agent-squad/swift/tracing/built-in/batch-span-processor/) | Batch-and-export — assembles `TraceEvent` records and ships on size or `flush()` |
| [`OTLPExporter`](/agent-squad/swift/tracing/built-in/otlp-exporter/) | OTLP/HTTP JSON — compatible with Langfuse, Datadog, Grafana, Honeycomb |

## Custom tracing

Implement any layer of the pipeline to swap in your own backend, batching strategy, or metrics sink. See [Custom Tracing](/agent-squad/swift/tracing/custom/) for full conformance examples covering `TraceExporter`, `SpanProcessor`, `Tracer`, and `Redactor`.

## Related pages

- [Orchestrator](/agent-squad/swift/orchestrator/overview/) — the orchestrator opens the root span and passes it down through `AgentContext`.
- [Messages & events](/agent-squad/swift/reference/messages-and-events/) — `AgentContext` carries the active `SpanHandle` so agents open child spans without global state.
- [Voice](/agent-squad/swift/voice/overview/) — voice sessions set `metadata` on turn spans to carry modality and audio token breakdown.
