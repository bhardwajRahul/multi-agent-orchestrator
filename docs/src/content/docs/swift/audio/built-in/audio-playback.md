---
title: AudioPlayback
description: AVAudioEngine-backed AudioOutput that converts PCM16 frames to float32 and schedules them on an AVAudioPlayerNode for continuous, barge-in-safe playback.
---

`AudioPlayback` is part of the `AgentSquadAudio` product. It accepts PCM16 @ 24 kHz frames, converts them to float32, and schedules them on an `AVAudioPlayerNode` for continuous playback. `flush()` provides an instant barge-in cut by discarding all buffered audio.

```swift
import AgentSquadAudio
```

---

## Init

```swift
public init(sampleRate: Double = 24_000)
```

| Parameter | Default | Notes |
|---|---|---|
| `sampleRate` | `24_000` | Sample rate in Hz for the internal float32 `AVAudioFormat`. Must match the PCM16 frames the runtime will enqueue. |

---

## Public surface

```swift
public func start()                 async throws  // attaches player node, starts engine (iOS: activates audio session)
public func enqueue(_ pcm16: Data)  async          // schedules one PCM16 frame for playback
public func flush()                 async          // discards all scheduled/playing buffers — instant barge-in cut
public func stop()                  async          // stops player and engine
```

`start()` is idempotent — a second call before `stop()` is a no-op.

`enqueue` converts the incoming PCM16 bytes to float32 samples and schedules the resulting buffer via `AVAudioPlayerNode.scheduleBuffer(_:completionHandler:)`. It returns immediately without waiting for the buffer to finish playing, so callers are never serialised to real-time playback speed.

`flush()` calls `player.stop()` then `player.play()` to discard all scheduled buffers and re-arm the player for the next enqueue call — no interruption to the downstream pipeline.

---

## VoiceAudioSession (iOS only)

On iOS, `start()` calls the internal `VoiceAudioSession.activate()` helper, which configures the shared `AVAudioSession`:

```
category:  .playAndRecord
mode:      .voiceChat
options:   [.defaultToSpeaker, .allowBluetoothHFP]
```

If `MicCapture.start()` was already called first, the session is already active and this is a no-op. On macOS the call is compiled out and the system default audio device is used.

---

## Usage

```swift
let playback = AudioPlayback()
try await playback.start()

// Feed frames as they arrive from the realtime runtime
await playback.enqueue(pcm16Frame)

// User interrupts — discard buffered audio instantly
await playback.flush()

await playback.stop()
```

### Wiring to the voice runtime

```swift
let runtime = RealtimeRuntime(
    input:  MicCapture(),
    output: AudioPlayback(),
    // ... other config
)
```

The runtime drives `start`, `enqueue`, `flush`, and `stop` from its single event pump, so `AudioPlayback` is never called concurrently by the runtime.

:::caution
Like `MicCapture`, `AudioPlayback` is `@unchecked Sendable` — its methods are not safe to call concurrently. Serialise calls yourself if you drive it outside the runtime.
:::

---

## Related pages

- [Audio overview](/agent-squad/swift/audio/overview/) — the `AudioOutput` protocol and how it fits into the runtime
- [MicCapture](/agent-squad/swift/audio/built-in/mic-capture/) — the companion `AudioInput` built-in
- [Custom audio](/agent-squad/swift/audio/custom/) — rolling your own `AudioOutput` conformance
- [Voice overview](/agent-squad/swift/voice/overview/) — the `RealtimeRuntime` that consumes `AudioPlayback`
