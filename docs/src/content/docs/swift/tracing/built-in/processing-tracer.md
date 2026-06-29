---
title: ProcessingTracer
description: The production Tracer — routes spans through a SpanProcessor and supports flush/shutdown for safe lifecycle management.
---

`ProcessingTracer` is the production `Tracer`. It creates spans as `ProcessedSpan` values that forward every lifecycle event to a `SpanProcessor` synchronously, preserving arrival order without blocking the caller.

For local development without export see [`OSLogTracer`](/agent-squad/swift/tracing/built-in/oslog-tracer/).

## Init

```swift
public struct ProcessingTracer: Tracer {
    // Full control — bring your own SpanProcessor:
    public init(processor: any SpanProcessor)

    // Convenience — wires BatchSpanProcessor around an exporter:
    public init(
        exporter: any TraceExporter,
        batchSize: Int = 64,
        redaction: any Redactor = Redaction.default
    )
}
```

The convenience init is the normal path. It creates a [`BatchSpanProcessor`](/agent-squad/swift/tracing/built-in/batch-span-processor/) internally and is equivalent to:

```swift
ProcessingTracer(
    processor: BatchSpanProcessor(
        exporter: exporter,
        batchSize: batchSize,
        redaction: redaction
    )
)
```

Use the `processor:` init when you need a custom batching strategy, fan-out to multiple exporters, or sampling — see [Custom Tracing](/agent-squad/swift/tracing/custom/).

## Usage

The most common setup: wire an [`OTLPExporter`](/agent-squad/swift/tracing/built-in/otlp-exporter/) directly through the convenience init.

```swift
let tracer = ProcessingTracer(
    exporter: OTLPExporter(
        endpoint: URL(string: "https://collector.example.com/v1/traces")!,
        headers: ["Authorization": "Basic <token>"]
    )
)

let orchestrator = MultiAgentOrchestrator(
    config: OrchestratorConfig(tracer: tracer)
)
```

## Lifecycle management

`ProcessingTracer` delegates `flush` and `shutdown` to the underlying processor. Call them explicitly — nothing drains automatically.

```swift
// In your SceneDelegate / AppDelegate:

func sceneWillResignActive(_ scene: UIScene) {
    Task { try await tracer.flush() }
}

func applicationWillTerminate(_ application: UIApplication) {
    Task { await tracer.shutdown() }
}
```

:::caution
If `flush()` and `shutdown()` are never called, any spans below the batch size will be lost when the process exits and the consumer task will not be released. This is especially important for short-lived CLI tools and test suites.
:::

## Redaction

The convenience init accepts a `Redactor` that is applied by `BatchSpanProcessor` before every export. The built-in `Redaction` hashes user ids and clips long strings:

```swift
// Custom clip limit, clear user ids:
let tracer = ProcessingTracer(
    exporter: myExporter,
    redaction: Redaction(hashUserIds: false, maxStringLength: 8192)
)
```

See [Custom Tracing](/agent-squad/swift/tracing/custom/) for a full `Redactor` conformance example.

## Related pages

- [Tracing Overview](/agent-squad/swift/tracing/overview/) — all protocols and the full pipeline diagram.
- [BatchSpanProcessor](/agent-squad/swift/tracing/built-in/batch-span-processor/) — the default `SpanProcessor` wired by the convenience init.
- [OTLPExporter](/agent-squad/swift/tracing/built-in/otlp-exporter/) — OTLP/HTTP JSON export, Langfuse/Datadog/Grafana/Honeycomb compatible.
- [Custom Tracing](/agent-squad/swift/tracing/custom/) — custom `SpanProcessor`, `Tracer`, and `Redactor` conformances.
