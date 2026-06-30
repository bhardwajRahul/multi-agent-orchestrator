---
title: Audio overview
description: The AgentSquadAudio product and the AudioInput/AudioOutput protocols that connect microphone capture and speaker playback to the voice runtime.
---

`AgentSquadAudio` is a separate Swift package product that ships two AVFoundation-backed implementations — `MicCapture` and `AudioPlayback` — built on top of two protocols declared in the core `AgentSquad` module.

```swift
import AgentSquad        // AudioInput, AudioOutput protocols
import AgentSquadAudio   // MicCapture, AudioPlayback
```

---

## Protocols

Both protocols are declared in `AgentSquad` (not `AgentSquadAudio`), so you can write custom conformances, unit-test stubs, or file-based implementations without pulling in AVFoundation.

### AudioInput

```swift
public protocol AudioInput: Sendable {
    /// Captured PCM16 chunks. Bounded drop-oldest — a slow consumer never blocks the audio thread.
    /// Finishes when capture stops.
    var frames: AsyncStream<Data> { get }

    func start() async throws
    func stop()  async
}
```

`start()` should install the capture source and begin yielding frames. `stop()` should halt capture and call `continuation.finish()` so consumers exit their `for await` loop cleanly.

### AudioOutput

```swift
public protocol AudioOutput: Sendable {
    func start()                async throws
    func enqueue(_ pcm16: Data) async
    func flush()                async
    func stop()                 async
}
```

`enqueue` schedules one PCM16 frame without waiting for it to finish playing — implementations must not serialize to real-time playback speed. `flush` is the barge-in primitive: it discards all queued or in-flight audio instantly.

---

## How they feed the voice runtime

[`RealtimeRuntime`](/agent-squad/swift/voice/overview/) accepts an `AudioInput` and an `AudioOutput` at construction time:

```swift
let runtime = RealtimeRuntime(
    input:  MicCapture(),
    output: AudioPlayback(),
    // ... other config
)
```

The runtime drives `start`, `stop`, `enqueue`, and `flush` from its single event pump, so implementations are never called concurrently by the runtime itself.

:::note
The wire format for both protocols is **PCM16 little-endian mono at 24 kHz**. This must match whatever sample rate your `MicCapture` and `AudioPlayback` are initialised with, and what the realtime session on the other end expects.
:::

---

## Built-in implementations

| Type | Protocol | Description |
|---|---|---|
| [`MicCapture`](/agent-squad/swift/audio/built-in/mic-capture/) | `AudioInput` | AVAudioEngine tap → PCM16 @ 24 kHz, with iOS permission gating |
| [`AudioPlayback`](/agent-squad/swift/audio/built-in/audio-playback/) | `AudioOutput` | AVAudioEngine + AVAudioPlayerNode, with barge-in flush |

---

## Custom implementations

You can replace either built-in with any conforming type — useful for tests, file-based input, or platforms where AVFoundation is unavailable.

See [Custom audio](/agent-squad/swift/audio/custom/) for worked examples of a file-replay `AudioInput` and a recording `AudioOutput` test sink.

---

## Related pages

- [Voice overview](/agent-squad/swift/voice/overview/) — the `RealtimeRuntime` that consumes these protocols
- [OpenAI Voice agent](/agent-squad/swift/voice/built-in/openai-voice/) — built-in agent wired to the voice runtime
- [Custom audio](/agent-squad/swift/audio/custom/)
