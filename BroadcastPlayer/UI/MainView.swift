import AppKit
import AVFoundation
import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState
    @State private var mode: Mode = .preview
    @State private var window: NSWindow?
    @State private var isFullScreen = false
    @State private var hasRestoredWindow = false
    @AppStorage("window.fullScreen") private var savedFullScreen = false

    enum Mode: String, CaseIterable, Identifiable {
        case preview
        case device

        var id: String { rawValue }

        var title: String {
            switch self {
            case .preview: "Preview"
            case .device: "Device"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFullScreen {
                header
                Divider()
            }
            if isFullScreen {
                preview
            } else {
                content
            }
            if !isFullScreen {
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(WindowReader { attached in
            window = attached
            guard let attached, !hasRestoredWindow else { return }
            hasRestoredWindow = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard savedFullScreen, !attached.styleMask.contains(.fullScreen) else { return }
                attached.toggleFullScreen(nil)
            }
        })
        .ignoresSafeArea(.container, edges: isFullScreen ? .all : [])
        .toolbarVisibility(isFullScreen ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    DeviceSelector()
                    if !appState.devices.formats.isEmpty {
                        Picker("Capture format", selection: formatSelection) {
                            ForEach(appState.devices.formats) { format in
                                Text("\(format.resolutionLabel) · \(format.frameRateLabel)").tag(format.id)
                            }
                        }
                        .frame(maxWidth: 260)
                    }
                    Toggle("4K Clarity", isOn: Binding(
                        get: { appState.isNatural4KEnabled },
                        set: { appState.updateNatural4K($0) }
                    ))
                    .toggleStyle(.button)
                    .help("Upscale 1920×1080 or 1920×1200 at 2× with MetalFX reconstruction and adaptive sharpening")
                    Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        window?.toggleFullScreen(nil)
                    }
                    .help("Show video full screen (Control–Command–F). Esc to exit.")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
            guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
            isFullScreen = true
            savedFullScreen = true
            appState.capture.renderer?.fillsScreen = appState.fillsFullScreen
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
            isFullScreen = false
            savedFullScreen = false
            appState.capture.renderer?.fillsScreen = false
        }
        .onChange(of: appState.fillsFullScreen) { _, fill in
            appState.capture.renderer?.fillsScreen = isFullScreen && fill
        }
        .onExitCommand {
            if isFullScreen { window?.toggleFullScreen(nil) }
        }
    }

    private var formatSelection: Binding<String> {
        Binding(
            get: { appState.devices.preferredFormat?.id ?? "" },
            set: { appState.devices.selectFormat(id: $0) }
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Broadcast Player")
                .font(.title3.weight(.semibold))
            Text(verbatim: Self.versionDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            Button(appState.audio.isMuted ? "Unmute" : "Mute", systemImage: appState.audio.isMuted ? "speaker.slash" : "speaker.wave.2") {
                appState.audio.updateMuted(!appState.audio.isMuted)
            }
            .labelStyle(.iconOnly)
            .disabled(!appState.audio.isEnabled)
            .help("Mute capture-card audio (Command–Shift–M)")

            Toggle("Compare", isOn: Binding(
                get: { appState.comparesOriginal }, set: { appState.updateComparison($0) }
            ))
            .toggleStyle(.button)
            .disabled(!appState.canCompare)
            .help("Original on the left, enhanced on the right (Command–B)")

            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .preview:
            preview
        case .device:
            DeviceInspector()
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let renderer = appState.capture.renderer {
            ZStack {
                Color.black
                VideoView(renderer: renderer)
                    .onTapGesture(count: 2) { window?.toggleFullScreen(nil) }

                if appState.comparesOriginal && appState.canCompare && previewMessage == nil {
                    HStack {
                        Text("Original")
                        Spacer()
                        Text("4K Clarity")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.55))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay {
                        Rectangle().fill(.white.opacity(0.7)).frame(width: 1)
                    }
                    .allowsHitTesting(false)
                }
                if let message = previewMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 30, weight: .light))
                        Text(verbatim: message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(28)
                }
            }
        } else {
            ContentUnavailableView {
                Label("Metal unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: appState.capture.errorMessage ?? "A Metal device is required to display the video signal.")
            }
        }
    }

    private var previewMessage: String? {
        if appState.devices.selectedEntry != nil {
            switch appState.devices.authorizationStatus {
            case .notDetermined:
                return "Waiting for camera access to the capture device…"
            case .denied:
                return "Allow BroadcastPlayer in System Settings → Privacy & Security → Camera."
            case .restricted:
                return "Camera access is restricted on this Mac."
            case .authorized:
                break
            @unknown default:
                return "Camera access is unavailable on this Mac."
            }
        }
        if let error = appState.capture.errorMessage {
            return error
        }
        if appState.capture.configuration == nil {
            return "No capture source selected. Choose a capture device in the toolbar."
        }
        if !appState.capture.isReceivingFrames {
            return "Waiting for a video signal on the capture device input…"
        }
        return nil
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statistic("Input", appState.capture.inputResolutionDescription)
            statistic("Capture", appState.capture.inputFrameRateDescription)
            statistic("Display", String(format: "%.2f fps", appState.capture.displayedFPS))
            statistic("Dropped", "\(appState.capture.droppedFrames)")
            if appState.isNatural4KEnabled {
                if let size = VideoGeometry.upscaleSize(width: appState.capture.inputWidth, height: appState.capture.inputHeight, adaptsTo16By10: appState.adaptsTo16By10) {
                    statistic("Upscale", "\(size.x)×\(size.y) · Clarity")
                } else {
                    statistic("Upscale", "1080p / 1200p required")
                }
            }

            Spacer(minLength: 16)

            Text(verbatim: appState.statusMessage)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            SettingsLink {
                Text("Settings…")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.caption.monospacedDigit())
        }
    }

    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "Version \(version) (\(build))"
    }
}

private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        view.removeEscapeMonitor()
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        private var escapeMonitor: Any?

        func removeEscapeMonitor() {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
            if window != nil {
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53,
                          let window = self?.window,
                          event.window === window,
                          window.styleMask.contains(.fullScreen) else { return event }
                    window.toggleFullScreen(nil)
                    return nil
                }
            }
            let attachedWindow = window
            DispatchQueue.main.async { [weak self] in
                self?.onWindow?(attachedWindow)
            }
        }
    }
}
