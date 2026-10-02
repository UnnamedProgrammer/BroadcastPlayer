import AVFoundation
import SwiftUI

struct DeviceInspector: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let devices = appState.devices

        if let entry = devices.selectedEntry {
            List {
                deviceSection(entry)
                accessSection(devices)
                signalSection
                formatsSection(devices)
            }
        } else if let id = devices.selectedDeviceID {
            ContentUnavailableView {
                Label("Capture device disconnected", systemImage: "bolt.horizontal.circle")
            } description: {
                Text("Waiting for \(id) to be connected again. The selection is kept and restored automatically.")
            }
        } else {
            ContentUnavailableView {
                Label("No capture device", systemImage: "video.slash")
            } description: {
                Text("Connect a capture card over USB or Thunderbolt and make sure its input has an active signal.")
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ entry: CaptureDeviceEntry) -> some View {
        Section("Device") {
            LabeledContent("Name", value: entry.name)
            if !entry.manufacturer.isEmpty {
                LabeledContent("Manufacturer", value: entry.manufacturer)
            }
            if !entry.modelID.isEmpty {
                LabeledContent("Model", value: entry.modelID)
            }
            LabeledContent("Type", value: entry.deviceTypeName)
            LabeledContent("Position", value: entry.positionName)
            LabeledContent("Transport", value: entry.transport.displayName)
            LabeledContent("Connected", value: entry.isConnected ? "Yes" : "No")
            if entry.isInUseByAnotherApplication {
                LabeledContent("In use") {
                    Text("By another application").foregroundStyle(.orange)
                }
            }
            LabeledContent("Identifier") {
                Text(verbatim: entry.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func accessSection(_ devices: CaptureDeviceManager) -> some View {
        Section("Camera access") {
            LabeledContent("Status", value: devices.authorizationName)

            switch devices.authorizationStatus {
            case .notDetermined:
                Button("Request access") { devices.requestAuthorization() }
            case .denied, .restricted:
                Text("Enable BroadcastPlayer under System Settings → Privacy & Security → Camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .authorized:
                Text("The capture device can be opened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            @unknown default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func formatsSection(_ devices: CaptureDeviceManager) -> some View {
        Section {
            if devices.formats.isEmpty {
                Text("The device reports no video formats.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices.formats) { format in
                    Button {
                        devices.selectFormat(id: format.id)
                    } label: {
                        formatRow(format, isPreferred: format == devices.preferredFormat)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(format.resolutionLabel), \(format.frameRateLabel)")
                    .accessibilityAddTraits(format == devices.preferredFormat ? [.isSelected] : [])
                }
            }
        } header: {
            Text("Supported formats (\(devices.formats.count))")
        } footer: {
            if let best = devices.preferredFormat {
                Text("Selected: \(best.resolutionLabel) @ \(best.frameRateLabel). Click a format to apply it.")
                if let error = appState.capture.errorMessage {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
        }
    }

    private var signalSection: some View {
        Section("Live signal") {
            LabeledContent("Input", value: appState.capture.inputResolutionDescription)
            LabeledContent("Capture rate", value: appState.capture.inputFrameRateDescription)
            LabeledContent("Displayed rate", value: String(format: "%.2f fps", appState.capture.displayedFPS))
            LabeledContent("App video delay", value: String(format: "%.1f ms", appState.capture.processingMilliseconds))
            Text("Measured from the capture callback to display presentation. Does not include console or capture-card latency.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Display timing jitter", value: String(format: "%.2f ms", appState.capture.displayJitterMilliseconds))
            LabeledContent("GPU processing", value: String(format: "%.2f ms", appState.capture.gpuMilliseconds))
            LabeledContent("Video buffer", value: appState.capture.videoBufferDescription)
            LabeledContent("Capture timing jitter", value: String(format: "%.2f ms", appState.capture.captureJitterMilliseconds))
            LabeledContent("Capture drops", value: "\(appState.capture.droppedFrames)")
            LabeledContent("Pixel format", value: appState.capture.pixelFormatName)
            LabeledContent("Color profile", value: appState.capture.colorDescription)
            LabeledContent("Audio output", value: appState.audio.outputDescription)
            LabeledContent("Audio queue resets", value: "\(appState.audio.playbackResets)")
            Button("Write diagnostics to Console") { appState.logProbe() }
        }
    }

    private func formatRow(_ format: CaptureFormatSummary, isPreferred: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isPreferred ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isPreferred ? Color.accentColor : Color.secondary.opacity(0.4))
            Text(verbatim: format.resolutionLabel)
                .monospacedDigit()
            Text(verbatim: format.frameRateLabel)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(verbatim: format.pixelFormatCodes.joined(separator: "  "))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}