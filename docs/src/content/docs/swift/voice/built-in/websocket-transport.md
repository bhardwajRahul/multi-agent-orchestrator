---
title: WebSocket transport
description: RealtimeTransport protocol and the built-in URLSessionWebSocketTransport — the default live WebSocket adapter for OpenAI Realtime.
---

`RealtimeTransport` is the frame channel between the voice session's control logic and the wire. The built-in `URLSessionWebSocketTransport` is a thin `URLSessionWebSocketTask` adapter with no external dependencies. For writing your own transport — including a mock for unit tests — see [Custom transport](/agent-squad/swift/voice/custom/).

---

## RealtimeTransport protocol

```swift
public protocol RealtimeTransport: Sendable {
    func connect() async throws
    func send(_ json: String) async throws
    var events: AsyncStream<String> { get }
    func close() async
}

public enum RealtimeTransportError: Error, Equatable {
    case notConnected
    case alreadyConnected
}
```

Frames are plain JSON strings. `connect()` may return before the WebSocket handshake completes; a failed handshake surfaces as `events` finishing or the next `send` throwing, not necessarily from `connect()` itself.

:::note
`events` must be a `nonisolated let` so the protocol's synchronous getter is satisfied from outside the actor. Store the `AsyncStream.Continuation` as a matching `nonisolated let` and drive it from inside the actor — the pattern `URLSessionWebSocketTransport` uses.
:::

---

## URLSessionWebSocketTransport

The live implementation — a thin `URLSessionWebSocketTask` adapter with no external dependencies.

```swift
public actor URLSessionWebSocketTransport: RealtimeTransport {
    public init(
        url: URL = URL(string: "wss://api.openai.com/v1/realtime")!,
        model: String = "gpt-realtime",
        apiKey: String,
        headers: [String: String] = [:],
        session: URLSession = .shared
    )
}
```

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `url` | `wss://api.openai.com/v1/realtime` | Base WebSocket endpoint |
| `model` | `"gpt-realtime"` | Appended as `?model=…` to the URL automatically |
| `apiKey` | — | Sent as `Authorization: Bearer <apiKey>` |
| `headers` | `[:]` | Additional request headers merged with the `Authorization` header |
| `session` | `.shared` | Inject a custom `URLSession` for testing or proxy configuration |

`model` is appended as a query parameter (`?model=…`) to the URL on init. One instance per connection — construct a new one to reconnect after a close.

---

## Usage

```swift
import AgentSquad

// Minimal — just an API key
let transport = URLSessionWebSocketTransport(
    apiKey: "sk-..."
)

// Custom endpoint (e.g. Azure OpenAI or a proxy)
let transport = URLSessionWebSocketTransport(
    url: URL(string: "wss://my-proxy.example.com/v1/realtime")!,
    model: "gpt-4o-realtime-preview",
    apiKey: myToken,
    headers: ["X-Request-ID": requestId]
)

let assistant = OpenAIVoiceAssistant(
    name: "voice-assistant",
    transport: transport,
    tools: myToolProvider,
    userId: "u1",
    sessionId: UUID().uuidString
)
```

:::caution
One `URLSessionWebSocketTransport` instance represents one connection. Never share an instance between two assistants or across reconnects — construct a fresh one each time.
:::

---

## How the receive loop works

`connect()` resumes the `URLSessionWebSocketTask` and launches an internal `receive()` loop. Because `URLSessionWebSocketTask.receive()` must be re-armed after each message, the loop calls it in a `while !Task.isCancelled` cycle and yields each text frame to `events`. When the task errors or the loop is cancelled, the continuation finishes — ending the session's pump.

---

## Related pages

- [Voice overview](/agent-squad/swift/voice/overview/) — `RealtimeRuntime`, protocols, and event reference
- [Custom transport](/agent-squad/swift/voice/custom/) — mock transport for unit tests and custom backend implementations
- [OpenAIVoiceAssistant](/agent-squad/swift/voice/built-in/openai-voice/) — single-LLM built-in
- [OpenAIGroundedVoiceAssistant](/agent-squad/swift/voice/built-in/openai-grounded-voice/) — grounded two-phase built-in
