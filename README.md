<div align="center">

# Broadcast Player

**Your console. Your Mac display.**

A native macOS app for viewing HDMI capture with GPU upscaling, adjustable image clarity, and stereo PCM audio.

![macOS 27 or later](https://img.shields.io/badge/macOS-27%2B-161616?logo=apple&logoColor=white) ![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white) ![Metal and MetalFX](https://img.shields.io/badge/Rendering-Metal%20%2B%20MetalFX-4667DF)

[Download](https://github.com/UnnamedProgrammer/BroadcastPlayer/releases/latest) · [Get started](#get-started) · [Image quality](#image-quality) · [Audio](#audio) · [Keyboard shortcuts](#keyboard-shortcuts) · [Development](#development)

</div>

---

Broadcast Player turns a compatible USB or Thunderbolt capture card into a fullscreen console viewer. Choose the signal format, tune the image to your display, and hear the console through your Mac's speakers or headphones.

The app is built with SwiftUI, AVFoundation, Metal, and Core Audio. Video processing happens on the GPU, and the interface exposes both capture and presentation statistics so you can see what your setup actually delivers.

## At a glance

| Feature | What it does |
| --- | --- |
| **4K Clarity** | Upscales 1080p or 1200p with MetalFX reconstruction and adjustable sharpening. |
| **Fullscreen playback** | Shows the complete frame, with optional display adaptation or crop-to-fill. |
| **Adaptive low latency** | Limits waiting video frames to one when capture timing is stable, or two during jitter. |
| **Shadow visibility** | Lifts dark details while preserving black and bright areas. |
| **Stereo PCM audio** | Plays capture-card audio through the current system output. |
| **Comfort sound** | Makes quiet sounds easier to hear and reduces loud peaks with compression and limiting. |
| **Live diagnostics** | Reports capture/display FPS, GPU time, timing jitter, app video delay, and audio queue resets. |
| **Device recovery** | Remembers the selected device and format, restores selection after reconnection, and retries capture after runtime errors. |

## Get started

### What you need

- An **Apple Silicon Mac running macOS 27 or later** for the supported setup.
- A USB or Thunderbolt capture card that macOS exposes as a video capture device.
- A console or another HDMI source, connected to the card's HDMI input.
- **Xcode 27 or later** if you want to build from source.

```text
Console / HDMI source ── HDMI ──▶ Capture card ── USB / Thunderbolt ──▶ Mac
```

### Download and install

Get the latest app from **[GitHub Releases](https://github.com/UnnamedProgrammer/BroadcastPlayer/releases/latest)**. Xcode is not required for the downloadable app.

1. Download the **Apple Silicon DMG** and open it.
2. Drag `BroadcastPlayer.app` into **Applications**, then launch it.
3. Allow **Camera** and **Microphone** access, then choose your capture device and input format.

A ZIP download is also available. Extract it and move `BroadcastPlayer.app` to Applications. Each release includes SHA-256 checksums for both downloads.

> **First launch:** the current release is ad-hoc signed and is not notarized by Apple. macOS may block it at first. If you trust the downloaded app, follow [Apple's instructions for opening an unnotarized app](https://support.apple.com/en-us/102445): try launching it, then use **System Settings → Privacy & Security → Open Anyway** if that option is offered.

### Build from source

This repository contains the source code. To run it locally:

1. Clone the repository:

   ```sh
   git clone https://github.com/UnnamedProgrammer/BroadcastPlayer.git
   cd BroadcastPlayer
   ```

2. Open `BroadcastPlayer.xcodeproj` in Xcode.
3. Select the **BroadcastPlayer** scheme and **My Mac** as the destination.
4. Press **⌘R** to build and run.
5. Allow **Camera** access for the capture card and **Microphone** access for its audio input.
6. Select your capture device and an available format in the toolbar.

Start with **1920×1080 at 60 fps** if your capture card supports it. The listed rate is the requested capture mode; the status bar shows measured rates.

> **Console audio:** choose **Stereo uncompressed / PCM** in the console's audio settings. Dolby Digital is not decoded by the app's PCM playback path and can produce noise.

If you already have a built `BroadcastPlayer.app`, open it directly. Xcode is only needed for building. After an update, macOS may check capture permissions again; the app waits for permission before starting video capture.

## Image quality

### 4K Clarity

Enable **4K Clarity** in the toolbar or in **Settings → Video**. Supported reconstruction sizes are:

| Input | GPU output | Proportions |
| --- | --- | --- |
| 1920×1080 | 3840×2160 | 16:9 preserved |
| 1920×1200 | 3840×2400 | 16:10 preserved |
| 1920×1080 with 16:10 adaptation | 3840×2400 | Vertical stretch of about 11% |

The **Sharpness** slider controls added local contrast. Start at **35%**, then adjust for the game and source quality. At **0%**, reconstruction remains enabled while added sharpening is disabled.

Use **Compare** or **⌘B** to view the original on the left and the processed image on the right.

### Choose how the frame fits

- **Preserve proportions:** keep the complete frame and its original shape. Bars appear when the source and display have different aspect ratios.
- **1080p60 → 16:10 display:** reconstruct the complete 1080p frame for a 16:10 screen, with about 11% vertical stretch. This mode selects 1080p60 and enables upscaling.
- **Zoom to fill screen:** fill the fullscreen display by cropping the frame when needed.

For a complete frame without bars or stretching, the source and display must have matching aspect ratios.

### Make dark details easier to see

**Settings → Video → Shadow visibility** brightens dark details while preserving black, bright areas, and the balance between color channels. It is disabled by default. Try **20–30%** for dark games; reset it to **0%** for the original tone.

### Quality and performance expectations

The current pipeline is **8-bit SDR**. It reads source color metadata and handles Rec. 601, Rec. 709, and Rec. 2020 matrices for NV12 input, including full and limited ranges. HDR tone mapping is not implemented.

Upscaling can improve how a lower-resolution signal looks on a larger display, but it cannot guarantee the detail of a native 4K source. There is **no frame generation**. Presentation targets up to 60 Hz through `CAMetalDisplayLink`; actual delivered FPS depends on the source, capture hardware, and Mac workload.

## Audio

Audio follows the selected video device automatically when a matching external audio input is available. You can also select an input manually in **Settings → Audio**.

- Playback uses the **current macOS system output**, including speakers, wired headphones, USB audio, and Bluetooth headphones.
- **100% volume** preserves the source level when Comfort sound is off; lower values attenuate it.
- **Mute** keeps capture and the playback clock running.
- **Comfort sound**, disabled by default, uses Apple's Dynamics Processor and Peak Limiter to lift quiet sounds and restrain loud peaks. Toggling it briefly restarts the audio buffer.
- **Test speakers** plays a quiet tone through the same playback path to help distinguish output problems from capture-source problems.

Bluetooth output adds latency even when playback is continuous. The audio queue tracks samples awaiting rendering rather than Bluetooth presentation delay to avoid repeated queue resets.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Toggle fullscreen | **⌃⌘F** or double-click the image |
| Leave fullscreen | **Esc** |
| Compare original / enhanced | **⌘B** |
| Mute / unmute capture audio | **⇧⌘M** |

## Understand your setup

The Preview status bar separates **Capture FPS** from **Display FPS**. Open **Device → Live signal** for more detail:

- **App video delay:** time from receiving a frame in the app to its actual presentation. It excludes console and capture-card latency.
- **Timing jitter:** variation in capture arrival and display presentation intervals.
- **GPU processing:** measured GPU execution time.
- **Video buffer:** the current limit for waiting frames.
- **Audio output and queue resets:** useful when diagnosing intermittent sound.

**Adaptive low latency** is enabled by default in **Settings → Capture**. After stable frame arrivals, it reduces the waiting queue to one frame; timing disturbances temporarily allow two. Disabling it uses a fixed two-frame queue. This queue limit does not represent total end-to-end latency.

Video presentation pauses when Preview is hidden or the window is fully obscured, so Display FPS can fall to zero while capture continues.

### Troubleshooting

| Symptom | Check |
| --- | --- |
| No picture | Verify the HDMI input signal, selected capture device, and Camera permission. |
| Capture rate below the selected rate | Try 1080p60, check the card's supported modes and USB connection, and compare measured capture/display FPS. |
| Bars, stretching, or missing edges | Review the aspect-ratio and fill options under Settings → Video. |
| Crackling or digital noise | Set the HDMI source to Stereo uncompressed / PCM. Use Test speakers to check the output path. |
| Bluetooth sound cuts out | Check the selected system output and audio queue reset counter. Reconnect the headphones if the route has changed. |
| Picture looks too sharp or dark | Lower Sharpness or adjust Shadow visibility; use Compare to evaluate the result. |

## Development

### Command-line build

```sh
xcodebuild \
  -project BroadcastPlayer.xcodeproj \
  -scheme BroadcastPlayer \
  -configuration Release \
  -derivedDataPath build \
  build

mkdir -p dist
ditto build/Build/Products/Release/BroadcastPlayer.app dist/BroadcastPlayer.app
```

The project uses local ad-hoc signing. Build products and local Xcode state are excluded from Git.

### Project layout

```text
BroadcastPlayer/
├── App/           App lifecycle, shared state, and preferences
├── Capture/       Device discovery, formats, capture, and frame buffering
├── Metal/         GPU rendering, color conversion, shaders, and upscaling
├── Audio/         PCM decoding, playback queues, and optional audio effects
├── Performance/   Capture and presentation measurements
├── UI/            Preview, device inspector, and settings
└── Utilities/     Logging and format helpers
Tests/             Standalone CPU, GPU, and hardware checks
docs/              Developer documentation
```

See **[Testing](docs/TESTING.md)** for reproducible checks covering color conversion, upscaling, shadow processing, frame buffering, PCM decoding, and audio playback.

### Contributing

Bug reports and focused pull requests are welcome. For capture or playback issues, include the Mac and macOS version, capture-card model, selected mode, console audio format, and the relevant live statistics. Please remove personal information from logs and screenshots before sharing them.
