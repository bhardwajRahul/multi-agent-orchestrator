---
title: BatchSpanProcessor
description: The production SpanProcessor — assembles TraceEvent records from span lifecycle callbacks and exports them in batches at batchSize or on explicit flush().
---

`BatchSpanProcessor` is the built-in `SpanProcessor`. It receives span lifecycle events from `ProcessingTracer`, assembles each event into a complete `TraceEvent`, applies `Redaction`, and ships batches to a `TraceExporter`.

It is wired automatically when you use `ProcessingTracer`'s convenience init. Use the `processor:` init on `ProcessingTracer` only when you need a custom batching strategy — see [Custom Tracing](/agent-squad/swift/tracing/custom/).

## Init

```swift
public actor BatchSpanProcessor: SpanProcessor {
    public init(
        exporter: any TraceExporter,
        batchSize: Int = 64,
        redaction: any Redactor = Redaction.default
    )
}
```

- `exporter` — the `TraceExporter` that receives finished batches.
- `batchSize` — number of completed spans that triggers an automatic export. Must be `>= 1`.
- `redaction` — applied to every `TraceEvent` before export. Defaults to `Redaction.default` (hash user ids, clip strings at 4096 chars).

## Key behaviours

- **Single ordered consumer** — all messages (`onOpen`, `onUsage`, `onSetInput`, `onSetMetadata`, `onEnd`, `flush`, `shutdown`) flow through one `AsyncStream`. A span's `onOpen` → … → `onEnd` sequence can never reorder, so token attribution and parent linkage are always correct.
- **No timer** — a batch ships when `pending.count >= batchSize` or on an explicit `flush()`. There is no scheduled-delay flush. Size your `batchSize` to match your typical request volume.
- **Unbounded buffer** — the pending queue has no max size. Silent drops would be worse than memory pressure for small chat traces. If you need backpressure, implement a custom `SpanProcessor`.
- **Error handling** — failures on the automatic batch path are swallowed (a tracer must never crash the app). `flush()` surfaces them — call it when you can handle the error.
- **Second `end` is a no-op** — `BatchSpanProcessor` ignores a second `onEnd` for the same span id, so each span exports exactly once.

## Lifecycle

```swift
// Manual lifecycle in an app delegate / scene delegate:
try await tracer.flush()    // on sceneWillResignActive — surfaces errors
await tracer.shutdown()     // on applicationWillTerminate — final drain + release
```

`shutdown()` is the only call that stops the consumer task. Until it is called, the `BatchSpanProcessor` (and by extension `ProcessingTracer`) retains the consumer and the exporter.

:::caution
Never call `flush()` or `shutdown()` directly on the `BatchSpanProcessor` when it was created by the `ProcessingTracer` convenience init — call them on the `tracer` instead. `ProcessingTracer.flush()` and `ProcessingTracer.shutdown()` delegate to the processor.
:::

## Redaction

`BatchSpanProcessor` applies the `Redactor` to every finalized `TraceEvent` before appending it to the pending batch. The built-in `Redaction` hashes user ids and clips strings:

```swift
public struct Redaction: Redactor {
    public var hashUserIds: Bool        // default: true
    public var maxStringLength: Int?    // default: 4096; nil disables clipping

    public init(hashUserIds: Bool = true, maxStringLength: Int? = 4096)
    public static let `default` = Redaction()
}
```

- `hashUserIds: true` — replaces raw user ids with a 16-hex-char SHA-256 prefix. Stable across sessions so you can still correlate a user's traces without shipping the raw id.
- `maxStringLength` — clips strings in `input`, `output`, `error`, and `metadata`. `id`, `traceId`, `parentId`, `model`, and token counts pass through untouched.

Pass a custom `Redactor` to the `BatchSpanProcessor` (or the `ProcessingTracer` convenience init) to implement a different privacy policy. See [Custom Tracing](/agent-squad/swift/tracing/custom/) for a full conformance example.

## Related pages

- [Tracing Overview](/agent-squad/swift/tracing/overview/) — the full pipeline and all protocols.
- [ProcessingTracer](/agent-squad/swift/tracing/built-in/processing-tracer/) — the `Tracer` that feeds `BatchSpanProcessor`.
- [OTLPExporter](/agent-squad/swift/tracing/built-in/otlp-exporter/) — the default `TraceExporter` wired behind `BatchSpanProcessor`.
- [Custom Tracing](/agent-squad/swift/tracing/custom/) — implement `SpanProcessor` directly for custom batching, fan-out, or sampling.
