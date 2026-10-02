# Testing Broadcast Player

Run these standalone checks from the repository root on macOS with Xcode's command-line tools installed. The Xcode scheme does not currently contain an XCTest target; use the commands below rather than `xcodebuild test`.

The CPU and offline audio checks do not require a capture card. GPU checks require a Metal-capable Mac; `ClarityGPUCheck.swift` also requires MetalFX support.

## CPU checks

### Adaptive video buffering

Checks stable capture cadence at 24, 30, 59.94, and 60 Hz, jitter protection and recovery, fixed buffering, frame order, and queue bounds.

```sh
swiftc -O Tests/AdaptiveFramePacingCheck.swift \
  BroadcastPlayer/Capture/AdaptiveFramePacing.swift \
  BroadcastPlayer/Capture/CaptureFrameBuffer.swift \
  -o /tmp/BroadcastAdaptiveCheck
/tmp/BroadcastAdaptiveCheck
```

### PCM decoding

Checks signed integer normalization, planar floating-point input, channel separation, format changes, and rejection of malformed samples.

```sh
swiftc Tests/AudioPCMDecoderCheck.swift \
  BroadcastPlayer/Audio/AudioPCMDecoder.swift \
  -o /tmp/BroadcastPCMCheck
/tmp/BroadcastPCMCheck
```

### Audio queue accounting

Checks queue bounds, overflow handling, and completion callbacks across playback resets.

```sh
swiftc Tests/AudioRenderQueueCheck.swift \
  BroadcastPlayer/Audio/AudioRenderQueue.swift \
  -o /tmp/BroadcastAudioQueueCheck
/tmp/BroadcastAudioQueueCheck
```

## GPU checks

### Color conversion and presentation statistics

Executes the NV12 shader for Rec. 601, Rec. 709, and Rec. 2020 in full and limited range. Also checks source color profiles, concurrent frame snapshots, queue bounds, and presentation-rate accounting.

```sh
swiftc -O Tests/VideoPipelineCheck.swift \
  BroadcastPlayer/Metal/VideoColorInfo.swift \
  BroadcastPlayer/Capture/AdaptiveFramePacing.swift \
  BroadcastPlayer/Capture/CaptureFrameBuffer.swift \
  BroadcastPlayer/Performance/PresentationStatistics.swift \
  -o /tmp/BroadcastVideoCheck
/tmp/BroadcastVideoCheck
```

### Reconstruction and clarity

Exercises the actual MetalFX and clarity shaders. Checks flat colors, black levels, detail enhancement, sharpening edge bounds, and the original comparison half.

```sh
# 1920×1080 → 3840×2160
swift Tests/ClarityGPUCheck.swift

# 1920×1200 → 3840×2400
swift Tests/ClarityGPUCheck.swift 1200

# 1920×1080 → 3840×2400 with 16:10 adaptation
swift Tests/ClarityGPUCheck.swift 1080 2400
```

### Shadow visibility

Checks the gray ramp, black and highlight preservation, neutral color balance, zero-strength bypass, and the unprocessed comparison half.

```sh
swiftc -parse-as-library Tests/ShadowLiftGPUCheck.swift \
  -o /tmp/BroadcastShadowCheck
/tmp/BroadcastShadowCheck
```

## Offline audio processing

Runs the production comfort processing chain through AVAudioEngine's offline renderer. Checks quiet-sound gain, loud-sound compression, clipping, stereo symmetry and channel separation, silence, and bypass levels. It does not play audible output.

```sh
swiftc Tests/ComfortAudioCheck.swift \
  BroadcastPlayer/Audio/ComfortAudioChain.swift \
  -o /tmp/BroadcastComfortCheck
/tmp/BroadcastComfortCheck
```

## Output and hardware integration

### Continuous playback on the current output

This check schedules **silent PCM** through the current macOS output. To test Bluetooth, select Bluetooth headphones as the system output before running it. It compares playback completion accounting and checks continuous rendering with comfort processing both off and on.

```sh
swiftc Tests/BluetoothPlaybackCheck.swift \
  BroadcastPlayer/Audio/AudioRenderQueue.swift \
  BroadcastPlayer/Audio/ComfortAudioChain.swift \
  -o /tmp/BroadcastOutputCheck
/tmp/BroadcastOutputCheck
```

### Capture-card audio

Requires exactly one USB capture-card audio input, an active stereo PCM source, and audio capture permission for the test process. Playback is muted. Checks native-format capture, render completions, queue resets, mute behavior, stop, and restart.

```sh
swiftc Tests/AudioCaptureCheck.swift \
  BroadcastPlayer/Audio/AudioCaptureEngine.swift \
  BroadcastPlayer/Audio/AudioPCMDecoder.swift \
  BroadcastPlayer/Audio/AudioRenderQueue.swift \
  BroadcastPlayer/Audio/ComfortAudioChain.swift \
  BroadcastPlayer/Utilities/Logger.swift \
  -o /tmp/BroadcastCaptureAudioCheck
/tmp/BroadcastCaptureAudioCheck
```

## Manual playback check

1. Build and launch the app, allow capture permissions, and select a supported input mode.
2. Check that Capture FPS and Display FPS update separately.
3. Enter and leave fullscreen; switch between Preview and Device, then return to Preview.
4. Toggle 4K Clarity and Compare. Adjust Sharpness and Shadow visibility, then restore the desired settings.
5. Toggle Adaptive low latency and inspect the Video buffer status.
6. Play stereo PCM audio. Toggle Comfort sound and mute; verify continuous playback and inspect audio queue resets.
7. Switch between speakers and headphones and check playback after the output route settles.
8. Disconnect and reconnect the capture card, then verify that the saved device selection returns.

Hardware checks describe conditions to verify; they do not guarantee a specific FPS or end-to-end latency on every capture card.
