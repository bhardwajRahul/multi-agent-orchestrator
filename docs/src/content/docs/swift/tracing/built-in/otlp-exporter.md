---
title: OTLPExporter
description: TraceExporter that POSTs spans as OTLP/HTTP JSON — compatible with Langfuse, Datadog, Grafana, Honeycomb, and any OpenTelemetry collector.
---

`OTLPExporter` implements `TraceExporter` by posting batches of `TraceEvent` records as OTLP/HTTP JSON. This is the wire format that Langfuse, Langsmith, Datadog, Grafana, and Honeycomb all ingest natively.

## Init

```swift
public struct OTLPExporter: TraceExporter {
    public init(
        endpoint: URL,
        headers: [String: String] = [:],
        serviceName: String = "agent-squad",
        http: any HTTPPoster = URLSessionPoster()
    )
}
```

- `endpoint` — the collector's `/v1/traces` path.
- `headers` — inject auth: `["Authorization": "Basic <b64>"]`, `["x-api-key": "..."]`, `["dd-api-key": "..."]`, etc.
- `serviceName` — becomes the `service.name` resource attribute in every span.
- `http` — injectable `HTTPPoster` for unit-testing without a live network.

## Usage

```swift
let tracer = ProcessingTracer(
    exporter: OTLPExporter(
        endpoint: URL(string: "https://collector.example.com/v1/traces")!,
        headers: ["Authorization": "Basic <token>"],
        serviceName: "MyApp"
    )
)
```

## Error handling

`export` throws `OTLPExporterError.httpStatus(Int, body: String?)` on any non-2xx response. The `body` contains up to 1 KB of the collector's response body, which typically includes the rejection reason.

```swift
public enum OTLPExporterError: Error, Equatable {
    case httpStatus(Int, body: String?)
    case nonHTTPResponse
}
```

Export failures on the automatic batch path (triggered by `batchSize`) are swallowed — a tracer must never crash the app and there is no retry or offline persistence. Call `tracer.flush()` explicitly when you want to surface errors.

## GenAI semantic conventions

`OTLPExporter` maps `TraceEvent` fields to the OTel GenAI semantic conventions so backends render model and token data natively:

| TraceEvent field | OTLP attribute |
|---|---|
| `model` | `gen_ai.request.model` |
| `promptTokens` | `gen_ai.usage.input_tokens` |
| `completionTokens` | `gen_ai.usage.output_tokens` |
| `userId` | `enduser.id` |
| `sessionId` | `session.id` |
| `input` | `gen_ai.prompt` |
| `output` | `gen_ai.completion` |

Metadata top-level keys become additional OTLP span attributes verbatim. The reserved keys above cannot be shadowed by metadata.

`generation` spans map to OTLP span kind `CLIENT` (3); all others use `INTERNAL` (1).

## HTTPPoster — testing seam

`OTLPExporter` delegates the single HTTP call to an `HTTPPoster`:

```swift
public protocol HTTPPoster: Sendable {
    func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> (response: HTTPURLResponse, body: Data)
}
```

The default implementation uses `URLSession`:

```swift
public struct URLSessionPoster: HTTPPoster {
    public init(session: URLSession = .shared)
}
```

Inject a custom `HTTPPoster` in tests to inspect the encoded payload without a network round-trip:

```swift
struct RecordingPoster: HTTPPoster {
    var captured: [Data] = []
    mutating func post(url: URL, headers: [String: String], body: Data) async throws
        -> (response: HTTPURLResponse, body: Data)
    {
        captured.append(body)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
}
```

## Langfuse example

Langfuse uses HTTP Basic auth with its public/secret key pair:

```swift
import Foundation

let publicKey = "pk-lf-..."
let secretKey = "sk-lf-..."
let credentials = Data("\(publicKey):\(secretKey)".utf8).base64EncodedString()

let tracer = ProcessingTracer(
    exporter: OTLPExporter(
        endpoint: URL(string: "https://cloud.langfuse.com/api/public/otel/v1/traces")!,
        headers: ["Authorization": "Basic \(credentials)"],
        serviceName: "MyApp"
    )
)
```

## Related pages

- [Tracing Overview](/agent-squad/swift/tracing/overview/) — the full pipeline and all protocols.
- [ProcessingTracer](/agent-squad/swift/tracing/built-in/processing-tracer/) — the `Tracer` that drives `OTLPExporter` through a `BatchSpanProcessor`.
- [BatchSpanProcessor](/agent-squad/swift/tracing/built-in/batch-span-processor/) — assembles and batches `TraceEvent` records before they reach the exporter.
- [Custom Tracing](/agent-squad/swift/tracing/custom/) — implement `TraceExporter` to target any backend.
