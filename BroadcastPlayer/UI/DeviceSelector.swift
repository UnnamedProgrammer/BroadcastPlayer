import SwiftUI

struct DeviceSelector: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let devices = appState.devices

        if devices.entries.isEmpty {
            Label("No capture device", systemImage: "video.slash")
                .foregroundStyle(.secondary)
        } else {
            Picker("Capture device", selection: selection) {
                if let id = devices.selectedDeviceID, devices.selectedEntry == nil {
                    Text("Disconnected").tag(Optional(id))
                }
                ForEach(devices.entries) { entry in
                    Text(label(for: entry)).tag(Optional(entry.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 240)
            .help("Select the capture device used for the video signal")
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { appState.devices.selectedDeviceID },
            set: { appState.devices.select(id: $0) }
        )
    }

    private func label(for entry: CaptureDeviceEntry) -> String {
        var parts = [entry.name, entry.transport.displayName]
        if entry.isInUseByAnotherApplication {
            parts.append("in use")
        }
        return parts.joined(separator: " · ")
    }
}