import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Adaptive low latency", isOn: Binding(
                    get: { appState.usesAdaptiveLatency }, set: { appState.updateAdaptiveLatency($0) }
                ))
                Text("Uses one queued frame for a stable signal and temporarily allows two when timing becomes uneven. Off uses a fixed two-frame queue.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Video buffer", value: appState.capture.videoBufferDescription)
                Picker("Frame rate", selection: frameRate) {
                    ForEach(FrameRatePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                Text("Used when choosing the capture format. If the device cannot deliver this rate, the closest supported format is used instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Toggle("Play capture-card audio", isOn: Binding(
                    get: { appState.audio.isEnabled }, set: { appState.audio.updateEnabled($0) }
                ))
                Picker("Audio input", selection: Binding(
                    get: { appState.audio.selectedInputID }, set: { appState.audio.updateInput($0) }
                )) {
                    Text("Automatic (match video device)").tag("")
                    ForEach(appState.audio.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .disabled(!appState.audio.isEnabled)
                HStack {
                    Text("Volume")
                    Slider(value: Binding(get: { appState.audio.volume },
                        set: { appState.audio.updateVolume($0) }), in: 0...1)
                    Text("\(Int((appState.audio.volume * 100).rounded()))%")
                        .monospacedDigit().frame(width: 40)
                }
                .disabled(!appState.audio.isEnabled)
                Toggle("Mute", isOn: Binding(get: { appState.audio.isMuted },
                    set: { appState.audio.updateMuted($0) }))
                Toggle("Comfort sound", isOn: Binding(
                    get: { appState.audio.isComfortEnabled }, set: { appState.audio.updateComfort($0) }
                ))
                Text("Reduces loud peaks and gently lifts quiet sounds. Uses Apple's dynamics processor and peak limiter. Switching restarts the short audio buffer; off preserves the original dynamics.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Test speakers (quiet tone)") { appState.audio.testSpeakers() }
                Text("For HDMI capture, set the console to Stereo uncompressed / PCM. A clean test tone with noisy capture points to the console or capture device.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Output", value: appState.audio.outputDescription)
                if appState.audio.outputLatencyMilliseconds > 0 {
                    LabeledContent("Output latency", value: String(format: "%.0f ms", appState.audio.outputLatencyMilliseconds))
                    Text("Reported by the output device. Bluetooth can add audible delay even when playback is stable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(appState.audio.sourceName)
                Text(appState.audio.errorMessage ?? (appState.audio.isReceiving
                    ? appState.audio.formatDescription : "Waiting for audio signal"))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Plays through the system speakers or headphones at the source quality, without lossy encoding or voice effects. 100% preserves the original level; lower volume attenuates it. External audio inputs only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Video") {
                Toggle("4K Clarity (1080p / 1200p → 2×)", isOn: natural4K)
                Toggle("1080p60 → 16:10 display", isOn: Binding(
                    get: { appState.adaptsTo16By10 }, set: { appState.update16By10($0) }
                ))
                Text("Selects 1920×1080 at 60 fps and reconstructs it at 3840×2400 on the GPU. Fills a 16:10 screen without cropping or bars, with about 11% vertical stretch.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Sharpness")
                    Slider(value: Binding(get: { appState.sharpness },
                        set: { appState.updateSharpness($0) }), in: 0...1)
                    Text("\(Int((appState.sharpness * 100).rounded()))%")
                        .monospacedDigit().frame(width: 40)
                }
                .disabled(!appState.isNatural4KEnabled)
                HStack {
                    Text("Shadow visibility")
                    Slider(value: Binding(get: { appState.shadowLift },
                        set: { appState.updateShadowLift($0) }), in: 0...1)
                    Text("\(Int((appState.shadowLift * 100).rounded()))%")
                        .monospacedDigit().frame(width: 40)
                }
                Text("Brightens dark details while preserving black and bright areas. 0% keeps the original tone; start at 20–30% for dark games.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset shadow visibility") { appState.updateShadowLift(0) }
                Button("Reset sharpness to 35%") { appState.updateSharpness(0.35) }
                Toggle("Compare original / enhanced (⌘B)", isOn: Binding(
                    get: { appState.comparesOriginal }, set: { appState.updateComparison($0) }
                ))
                .disabled(!appState.canCompare)
                Toggle("Zoom to fill screen (crop image)", isOn: Binding(
                    get: { appState.fillsFullScreen }, set: { appState.updateFillFullScreen($0) }
                ))
                Text(appState.adaptsTo16By10
                    ? "Off: shows the complete frame adapted to 16:10. On: crops if the display proportions differ."
                    : "Off: shows the entire image with its original proportions; black bars may appear. On: zooms to fill the display and crops edges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Reconstructs 1920×1080 at 3840×2160 or 1920×1200 at 3840×2400, preserving the source proportions, then restores fine contrast at the display resolution. Start at 35%; reduce sharpness if the source has grain or compression artifacts. At 0%, reconstruction stays on and added sharpening is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Toggle("Verbose logging", isOn: verboseLogging)
                Text("Writes additional detail to the unified log, visible in Console.app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 820)
    }

    private var natural4K: Binding<Bool> {
        Binding(get: { appState.isNatural4KEnabled }, set: { appState.updateNatural4K($0) })
    }

    private var frameRate: Binding<FrameRatePreference> {
        Binding(
            get: { appState.devices.frameRatePreference },
            set: { appState.devices.updateFrameRatePreference($0) }
        )
    }

    private var verboseLogging: Binding<Bool> {
        Binding(
            get: { appState.isVerboseLoggingEnabled },
            set: { appState.updateVerboseLogging($0) }
        )
    }
}