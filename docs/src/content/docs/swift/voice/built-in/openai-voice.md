---
title: OpenAIVoiceAssistant
description: Single-LLM realtime voice assistant — calls tools and speaks the answer in one response.
---

`OpenAIVoiceAssistant` is the single-LLM `VoiceAssistant` implementation. One OpenAI Realtime WebSocket handles the entire agent turn: the model calls any needed tools and then speaks the answer directly. For the two-phase gatherer→presenter variant see [OpenAIGroundedVoiceAssistant](/agent-squad/swift/voice/built-in/openai-grounded-voice/).

---

## Init

```swift
public actor OpenAIVoiceAssistant: VoiceAssistant {
    public init(
        name: String,
        transport: any RealtimeTransport,
        tools: any ToolProvider,
        userId: String,
        sessionId: String,
        store: (any ChatStorage)? = nil,
        tracer: any Tracer = OSLogTracer(),
        traceTranscripts: Bool = true,
        maxMessages: Int? = ChatStorageDefaults.maxMessages,
        modality: RealtimeModality = RealtimeModality(),
        instructions: String = OpenAIVoiceAssistant.defaultInstructions,
        model: String = "gpt-realtime",
        voice: String = "marin",
        language: String? = nil,
        sampleRate: Int = 24_000
    )
}
```

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `name` | — | Identifies this assistant in storage and traces; slugified for the storage key |
| `transport` | — | Any `RealtimeTransport`; use `URLSessionWebSocketTransport` in production |
| `tools` | — | Tool registry the model may call during a turn |
| `userId` | — | Scopes storage and tracing |
| `sessionId` | — | Scopes storage and tracing |
| `store` | `nil` | Enables history seeding and persistence; see [Storage overview](/agent-squad/swift/storage/overview/) |
| `tracer` | `OSLogTracer()` | Span sink; see [Tracing overview](/agent-squad/swift/tracing/overview/) |
| `traceTranscripts` | `true` | When `false`, span input/output fields are omitted while structure and token counts still flow |
| `maxMessages` | `ChatStorageDefaults.maxMessages` | Cap on replayed history items |
| `modality` | `RealtimeModality()` (speech in / audio out) | Controls the event mix; see [Voice overview](/agent-squad/swift/voice/overview/) |
| `instructions` | `defaultInstructions` | System prompt — tells the model to use tools and reply concisely in speech |
| `model` | `"gpt-realtime"` | Passed as the `?model=` query parameter by the transport |
| `voice` | `"marin"` | OpenAI Realtime voice name |
| `language` | `nil` | BCP-47 language code; `nil` lets the model auto-detect |
| `sampleRate` | `24_000` | PCM16 sample rate; must match `AudioInput`/`AudioOutput` |

---

## History seeding

When `store` is provided, `start()` replays prior turns from `ChatStorage` as conversation items before the pump handles inbound frames. Each completed turn (user transcript + spoken reply) is saved under `slugify(name)`. See [Storage overview](/agent-squad/swift/storage/overview/).

---

## Text-only typed turns

`sendText` marks the turn as text-only: the tool→continue loop stays in text and `.state(.speaking)` is never emitted. This is useful for non-voice UIs sharing the same session or for injecting context without audio output.

---

## Usage

```swift
import AgentSquad

let transport = URLSessionWebSocketTransport(
    apiKey: "sk-..."
)

let assistant = OpenAIVoiceAssistant(
    name: "support-voice",
    transport: transport,
    tools: myToolProvider,
    userId: currentUser.id,
    sessionId: UUID().uuidString,
    store: InMemoryChatStorage(),
    voice: "marin",
    language: "en"
)

let runtime = RealtimeRuntime(
    session: assistant,
    input: MicCapture(),
    output: AudioPlayback()
)

try await runtime.start()

for await event in runtime.events {
    switch event {
    case .state(let phase):
        updateStatusIndicator(phase)
    case .userTranscript(let text, final: true):
        showUserBubble(text)
    case .presenterText(let text, final: true):
        showAssistantBubble(text)
    case .error(let msg):
        print("voice error:", msg)
    default:
        break
    }
}
```

:::note
`RealtimeRuntime` is the only caller of `start()`, `stop()`, `sendAudio()`, and `interrupt()` on the assistant. Your app interacts exclusively with `RealtimeRuntime`. See [Voice overview](/agent-squad/swift/voice/overview/).
:::

---

## Phase events emitted

| Phase | When |
|---|---|
| `.listening` | After `start()` and after each completed or interrupted turn |
| `.thinking` | When a typed turn (`sendText`) starts — VAD turns emit `.speaking` directly |
| `.speaking` | When the model begins its spoken response |

---

## Related pages

- [Voice overview](/agent-squad/swift/voice/overview/) — `RealtimeRuntime`, protocols, and event reference
- [OpenAIGroundedVoiceAssistant](/agent-squad/swift/voice/built-in/openai-grounded-voice/) — two-phase grounded variant
- [WebSocket transport](/agent-squad/swift/voice/built-in/websocket-transport/) — `URLSessionWebSocketTransport`
- [Custom transport](/agent-squad/swift/voice/custom/) — mock and custom `RealtimeTransport` implementations
- [Audio overview](/agent-squad/swift/audio/overview/) — `MicCapture` and `AudioPlayback`
