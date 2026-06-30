---
title: Custom Tracing
description: Implement TraceExporter, SpanProcessor, Tracer, or Redactor to swap any layer of the tracing pipeline.
---

Every layer of the tracing pipeline is a protocol. Implement any one of them to change batching strategy, target a proprietary backend, emit metrics, or enforce a custom privacy policy — without touching the rest of the stack.

See [Tracing Overview](/agent-squad/swift/tracing/overview/) for the pipeline diagram and all protocol signatures.

## Custom exporter

Implement `TraceExporter` to target any backend. `flush` and `shutdown` have no-op default implementations; override them if your exporter buffers internally.

```swift
struct MyExporter: TraceExporter {
    func export(_ batch: [TraceEvent]) async throws {
        // encode and POST batch
    }
}

let tracer = ProcessingTracer(exporter: MyExporter())
```

Wire it through [`ProcessingTracer`](/agent-squad/swift/tracing/built-in/processing-tracer/)'s convenience init. [`BatchSpanProcessor`](/agent-squad/swift/tracing/built-in/batch-span-processor/) handles batching, ordering, and redaction; your exporter only needs to ship the finished batch.

## Custom span processor

Implement `SpanProcessor` directly when you need different batching logic, fan-out to multiple exporters, or span sampling.

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

Wire it through `ProcessingTracer`'s `processor:` init:

```swift
let tracer = ProcessingTracer(processor: MyProcessor())
```

:::caution
The synchronous lifecycle hooks (`onOpen`, `onUsage`, `onSetInput`, `onSetMetadata`, `onEnd`) run on the agent's hot path. They must be non-blocking — buffer the message and return immediately. Do not do network I/O or hold blocking locks in them. [`BatchSpanProcessor`](/agent-squad/swift/tracing/built-in/batch-span-processor/) does this by being an actor that only enqueues messages.

Order within a span must be preserved (`onOpen` before `onEnd`). A per-message detached `Task` or unordered fan-out corrupts token attribution and parent linkage.
:::

## Custom Tracer

Implement `Tracer` directly when you want to forward spans to your own backend without going through `ProcessingTracer` — for example, a metrics-only tracer, a no-op tracer for tests, or a shim around a third-party SDK.

The only required method is `startTrace`; `flush` and `shutdown` have no-op defaults.

```swift
import Foundation
import AgentSquad

/// A tracer that emits per-span metrics and discards payloads.
/// Replace the `record` stubs with your real metrics sink (StatsD, Prometheus, etc.).
struct MetricsTracer: Tracer {

    func startTrace(
        name: String,
        userId: String?,
        sessionId: String?,
        metadata: JSONValue?
    ) -> any SpanHandle {
        MetricsSpan(name: name, id: UUID().uuidString, traceId: UUID().uuidString)
    }

    func flush() async throws {
        // flush your metrics client if needed
    }

    func shutdown() async {
        // teardown
    }
}

struct MetricsSpan: SpanHandle {
    let name: String
    let id: String
    let traceId: String

    func span(_ name: String, input: JSONValue?) -> any SpanHandle {
        MetricsSpan(name: name, id: UUID().uuidString, traceId: traceId)
    }

    func generation(_ name: String, model: String, input: JSONValue?) -> any GenerationHandle {
        MetricsGeneration(name: name, id: UUID().uuidString, traceId: traceId)
    }

    func end(output: JSONValue?, error: (any Error)?) {
        // record(counter: "span.ended", tags: ["name": name, "status": error == nil ? "ok" : "error"])
    }
}

struct MetricsGeneration: GenerationHandle {
    let name: String
    let id: String
    let traceId: String

    func span(_ name: String, input: JSONValue?) -> any SpanHandle {
        MetricsSpan(name: name, id: UUID().uuidString, traceId: traceId)
    }

    func generation(_ name: String, model: String, input: JSONValue?) -> any GenerationHandle {
        MetricsGeneration(name: name, id: UUID().uuidString, traceId: traceId)
    }

    func usage(promptTokens: Int?, completionTokens: Int?) {
        // record(histogram: "llm.tokens.prompt",     value: promptTokens ?? 0)
        // record(histogram: "llm.tokens.completion", value: completionTokens ?? 0)
    }

    func end(output: JSONValue?, error: (any Error)?) {
        // record(counter: "generation.ended", tags: ["name": name])
    }
}
```

Wire it the same way as any built-in tracer:

```swift
let orchestrator = MultiAgentOrchestrator(
    config: OrchestratorConfig(tracer: MetricsTracer())
)
```

## Custom Redactor

Implement `Redactor` when the built-in `Redaction` doesn't fit your privacy policy — for example, to strip a specific metadata key or to redact by field rather than by length.

```swift
public protocol Redactor: Sendable {
    func redact(_ event: TraceEvent) -> TraceEvent
}
```

The example below strips any metadata key whose name starts with an underscore (internal keys) and removes the `input` field entirely for `generation` spans:

```swift
/// Strips metadata keys that start with an underscore (internal keys)
/// and removes the `input` field for `generation` spans.
struct PrivacyRedactor: Redactor {
    func redact(_ event: TraceEvent) -> TraceEvent {
        let cleanedMetadata: JSONValue? = event.metadata.flatMap { meta in
            guard case .object(let dict) = meta else { return meta }
            let filtered = dict.filter { !$0.key.hasPrefix("_") }
            return filtered.isEmpty ? nil : .object(filtered)
        }

        let input: JSONValue? = event.kind == .generation ? nil : event.input

        return TraceEvent(
            traceId: event.traceId,
            id: event.id,
            parentId: event.parentId,
            kind: event.kind,
            name: event.name,
            status: event.status,
            startedAt: event.startedAt,
            endedAt: event.endedAt,
            input: input,
            output: event.output,
            error: event.error,
            model: event.model,
            promptTokens: event.promptTokens,
            completionTokens: event.completionTokens,
            userId: event.userId,
            sessionId: event.sessionId,
            metadata: cleanedMetadata
        )
    }
}
```

Pass it to `ProcessingTracer` or `BatchSpanProcessor`:

```swift
let tracer = ProcessingTracer(
    exporter: myExporter,
    redaction: PrivacyRedactor()
)
```

The built-in `Redaction` covers the common defaults — dropping all payloads is also straightforward:

```swift
// Drop all payloads:
struct DropPayloads: Redactor {
    func redact(_ event: TraceEvent) -> TraceEvent {
        TraceEvent(
            traceId: event.traceId, id: event.id, parentId: event.parentId,
            kind: event.kind, name: event.name, status: event.status,
            startedAt: event.startedAt, endedAt: event.endedAt,
            model: event.model,
            promptTokens: event.promptTokens, completionTokens: event.completionTokens,
            userId: event.userId, sessionId: event.sessionId
        )
    }
}
```

## Related pages

- [Tracing Overview](/agent-squad/swift/tracing/overview/) — all protocols and the full pipeline diagram.
- [ProcessingTracer](/agent-squad/swift/tracing/built-in/processing-tracer/) — the production `Tracer`; accepts a custom `SpanProcessor` or `Redactor`.
- [BatchSpanProcessor](/agent-squad/swift/tracing/built-in/batch-span-processor/) — the built-in `SpanProcessor`; accepts a custom `TraceExporter` and `Redactor`.
- [OTLPExporter](/agent-squad/swift/tracing/built-in/otlp-exporter/) — built-in `TraceExporter`; accepts a custom `HTTPPoster` for testing.
- [OSLogTracer](/agent-squad/swift/tracing/built-in/oslog-tracer/) — the built-in dev `Tracer`.
