---
title: OSLogTracer
description: The default local-development tracer — writes span lifecycle to os.Logger with no network or configuration required.
---

`OSLogTracer` is the right tracer for local development. It writes span lifecycle events to `os.Logger` so they appear in Console.app and Instruments. Input/output payloads are intentionally omitted from log lines (they may contain user data); only names, ids, model, and token counts appear. No network, no `Redactor`, safe by default.

For production export see [`ProcessingTracer`](/agent-squad/swift/tracing/built-in/processing-tracer/).

## Init

```swift
public struct OSLogTracer: Tracer {
    public init(subsystem: String = "AgentSquad", category: String = "trace")
}
```

Both parameters are optional. The defaults place all log output under subsystem `AgentSquad`, category `trace`.

## Usage

```swift
let tracer = OSLogTracer()

let orchestrator = MultiAgentOrchestrator(
    config: OrchestratorConfig(tracer: tracer)
)
```

Open Console.app, filter by subsystem `AgentSquad` and category `trace`, then run your agent. You will see lines like:

```
▶︎ trace "my-request" [<uuid>] user=- session=-
  ↳ span "classifier" [<uuid>] parent=[<uuid>]
  ✓ end "classifier" [<uuid>] 0.012s
  ↳ gen "claude-3-5-sonnet" model=claude-3-5-sonnet [<uuid>] parent=[<uuid>]
  · usage [<uuid>] prompt=320 completion=87
  ✓ end "claude-3-5-sonnet" [<uuid>] 1.243s
✓ end "my-request" [<uuid>] 1.261s
```

Error spans emit at `os.Logger.error` level so they surface in standard log filters:

```
  ✗ end "my-span" [<uuid>] 0.003s error=MyError(...)
```

## Behaviour notes

- `flush()` and `shutdown()` are no-ops — `OSLogTracer` holds no buffer.
- Child spans are structurally flat in log output (the tree is implied by `parent=[...]`). Use Instruments' tracing template for a timeline view.
- `setInput` and `setMetadata` are silently ignored — `OSLogSpan` is stateless and does not retain open spans.

:::note
`OSLogTracer` conforms to `Tracer` but only requires `startTrace`. It provides no-op `flush` and `shutdown` through the protocol default extensions.
:::

## Related pages

- [Tracing Overview](/agent-squad/swift/tracing/overview/) — the full pipeline and all protocols.
- [ProcessingTracer](/agent-squad/swift/tracing/built-in/processing-tracer/) — the production tracer that drives `SpanProcessor` and supports `flush`/`shutdown`.
- [Custom Tracing](/agent-squad/swift/tracing/custom/) — implement `Tracer` directly to build a metrics-only or no-op tracer.
