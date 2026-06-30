---
title: MicCapture
description: AVAudioEngine-backed AudioInput that taps the microphone, converts to PCM16 @ 24 kHz mono, and yields frames into a bounded AsyncStream.
---

`MicCapture` is part of the `AgentSquadAudio` product. It taps `AVAudioEngine`'s input node, converts the hardware stream to **PCM16 @ 24 kHz mono**, and yields frames through a bounded `AsyncStream<Data>`.

```swift
import AgentSquadAudio
```

---

## Init

```swift
public init(sampleRate: Double = 24_000, maxBufferedFrames: Int = 16)
```

| Parameter | Default | Notes |
|---|---|---|
| `sampleRate` | `24_000` | Target sample rate in Hz. Must match what the realtime runtime expects. |
| `maxBufferedFrames` | `16` | Capacity of the internal `AsyncStream`. Under back-pressure the **oldest** frames are dropped — the tap thread never blocks. |

---

## Public surface

```swift
public let frames: AsyncStream<Data>   // yields PCM16 little-endian mono frames

public func start() async throws       // installs tap, starts engine, requests mic permission (iOS)
public func stop()  async              // stops engine, removes tap, finishes the stream
```

`start()` is idempotent — a second call before `stop()` is a no-op. Calling `start()` again after `stop()` is not supported; create a new instance.

---

## MicCaptureError

```swift
public enum MicCaptureError: Error, Equatable {
    case permissionDenied       // user denied mic access (iOS only)
    case converterUnavailable   // AVAudioConverter could not be initialised for the hardware format
}
```

---

## iOS mic permission

On iOS, `start()` requests microphone access before installing the tap:

- **iOS 17+** — uses `AVAudioApplication.requestRecordPermission`
- **iOS 16** — falls back to `AVAudioSession.requestRecordPermission` (the deprecated overload; no compiler warning fires at the iOS 16 deployment floor)

If the user denies permission, `start()` throws `MicCaptureError.permissionDenied`.

:::caution
Add `NSMicrophoneUsageDescription` to your `Info.plist`. Without it the system permission prompt will not appear, and the request is silently treated as denied.
:::

---

## VoiceAudioSession (iOS only)

On iOS, `start()` calls the internal `VoiceAudioSession.activate()` helper before installing the tap. It configures the shared `AVAudioSession`:

```
category:  .playAndRecord
mode:      .voiceChat
options:   [.defaultToSpeaker, .allowBluetoothHFP]
```

`VoiceAudioSession` is idempotent — re-activating an already-active session is a no-op. On macOS the call is compiled out (`#if os(iOS)`) and the system default audio device is used.

---

## Usage

```swift
let mic = MicCapture()          // 24 kHz, 16-frame queue
try await mic.start()

for await frame in mic.frames {
    // frame: Data containing PCM16 little-endian mono samples
}

await mic.stop()
```

### Wiring to the voice runtime

Pass `MicCapture` directly to `RealtimeRuntime` — the runtime only cares about the `AudioInput` protocol:

```swift
let runtime = RealtimeRuntime(
    input:  MicCapture(),
    output: AudioPlayback(),
    // ... other config
)
```

:::caution
`start()` and `stop()` are not safe to call concurrently. `RealtimeRuntime` serialises them internally. If you drive `MicCapture` directly, serialise calls yourself.
:::

---

## Related pages

- [Audio overview](/agent-squad/swift/audio/overview/) — the `AudioInput` protocol and how it fits into the runtime
- [AudioPlayback](/agent-squad/swift/audio/built-in/audio-playback/) — the companion `AudioOutput` built-in
- [Custom audio](/agent-squad/swift/audio/custom/) — rolling your own `AudioInput` conformance
- [Voice overview](/agent-squad/swift/voice/overview/) — the `RealtimeRuntime` that consumes `MicCapture`
