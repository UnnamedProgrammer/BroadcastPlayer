import AVFoundation
import Foundation
import Observation
import OSLog

nonisolated enum CaptureTransport: String {
    case builtIn
    case usb
    case thunderbolt
    case pci
    case fireWire
    case displayPort
    case hdmi
    case network
    case wireless
    case virtual
    case other
    case unknown

    var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .thunderbolt: "Thunderbolt"
        case .pci: "PCI"
        case .fireWire: "FireWire"
        case .displayPort: "DisplayPort"
        case .hdmi: "HDMI"
        case .network: "Network"
        case .wireless: "Wireless"
        case .virtual: "Virtual"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }

    static func from(code: Int32) -> CaptureTransport {
        switch FourCC.string(from: code) {
        case "bltn": .builtIn
        case "usb": .usb
        case "thun": .thunderbolt
        case "pci": .pci
        case "1394": .fireWire
        case "dprt": .displayPort
        case "hdmi": .hdmi
        case "ntwk": .network
        case "wrls": .wireless
        case "virt": .virtual
        case "othr": .other
        default: .unknown
        }
    }
}

nonisolated struct CaptureDeviceEntry: Identifiable {
    let device: AVCaptureDevice

    var id: String { device.uniqueID }
    var name: String { device.localizedName }
    var manufacturer: String { device.manufacturer }
    var modelID: String { device.modelID }
    var transport: CaptureTransport { .from(code: device.transportType) }
    var isExternal: Bool { device.deviceType == .external }
    var isConnected: Bool { device.isConnected }
    var isSuspended: Bool { device.isSuspended }
    var isInUseByAnotherApplication: Bool { device.isInUseByAnotherApplication }

    var deviceTypeName: String {
        switch device.deviceType {
        case .external: "External"
        case .continuityCamera: "Continuity camera"
        case .builtInWideAngleCamera: "Built-in wide angle"
        case .deskViewCamera: "DeskView camera"
        default: device.deviceType.rawValue
        }
    }

    var positionName: String {
        switch device.position {
        case .unspecified: "Unspecified"
        case .front: "Front"
        case .back: "Back"
        @unknown default: "Unknown"
        }
    }
}

struct CaptureSourceSelection {
    let device: AVCaptureDevice
    let format: AVCaptureDevice.Format
    let frameRate: Double
}

@Observable
final class CaptureDeviceManager {
    private enum DefaultsKey {
        static let selectedDeviceID = "capture.selectedDeviceID"
        static let frameRatePreference = "capture.frameRatePreference"
        static let selectedFormats = "capture.selectedFormats"
    }

    var onCaptureSourceChanged: ((CaptureSourceSelection?) -> Void)?

    private(set) var entries: [CaptureDeviceEntry] = []
    private(set) var selectedDeviceID: String?
    private(set) var frameRatePreference: FrameRatePreference = .defaultPreference
    private(set) var formats: [CaptureFormatSummary] = []
    private(set) var preferredFormat: CaptureFormatSummary?
    private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .continuityCamera, .builtInWideAngleCamera],
        mediaType: .video,
        position: .unspecified
    )

    private var monitorTask: Task<Void, Never>?
    private var selectedDeviceIdentity: ObjectIdentifier?
    private var requestingAuthorization = false

    init() {
        selectedDeviceID = UserDefaults.standard.string(forKey: DefaultsKey.selectedDeviceID)
        if let storedRate = UserDefaults.standard.object(forKey: DefaultsKey.frameRatePreference) as? Int,
           let preference = FrameRatePreference(rawValue: storedRate) {
            frameRatePreference = preference
        }
        refresh()
        startMonitoring()
        Log.app.info("CaptureDeviceManager started, \(self.entries.count) device(s) visible, target \(self.frameRatePreference.displayName, privacy: .public)")
    }

    var selectedEntry: CaptureDeviceEntry? {
        guard let selectedDeviceID else { return nil }
        return entries.first { $0.id == selectedDeviceID }
    }

    var isSelectedDeviceConnected: Bool { selectedEntry != nil }

    var authorizationName: String {
        switch authorizationStatus {
        case .notDetermined: "Not determined"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorized: "Authorized"
        @unknown default: "Unknown"
        }
    }

    func select(id: String?) {
        guard let id else {
            selectedDeviceID = nil
            UserDefaults.standard.removeObject(forKey: DefaultsKey.selectedDeviceID)
            clearDeviceSpecificState()
            Log.app.info("Capture device selection cleared")
            return
        }

        guard let entry = entries.first(where: { $0.id == id }) else {
            Log.app.error("Ignoring selection of unknown capture device")
            return
        }

        guard selectedDeviceID != id || selectedDeviceIdentity != ObjectIdentifier(entry.device) else { return }

        applySelection(entry.device, persist: true)
        Log.app.info("Selected capture device '\(entry.name, privacy: .public)' via \(entry.transport.displayName, privacy: .public)")
    }

    func updateFrameRatePreference(_ preference: FrameRatePreference) {
        guard preference != frameRatePreference else { return }
        frameRatePreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: DefaultsKey.frameRatePreference)
        Log.app.info("Capture frame rate preference changed to \(preference.displayName, privacy: .public)")

        guard let entry = selectedEntry else { return }
        let matchingResolution = formats.filter {
            $0.width == preferredFormat?.width && $0.height == preferredFormat?.height
        }
        let best = CaptureFormatManager.preferredFormat(
            in: matchingResolution.isEmpty ? formats : matchingResolution,
            frameRate: preference.rate
        )
        preferredFormat = best
        logPreferredFormat(best)
        publishSource(device: entry.device, summary: best)
    }

    func selectFormat(id: String) {
        guard let entry = selectedEntry,
              let format = formats.first(where: { $0.id == id }),
              format != preferredFormat else { return }
        preferredFormat = format
        var stored = UserDefaults.standard.dictionary(forKey: DefaultsKey.selectedFormats) as? [String: String] ?? [:]
        stored[entry.id] = format.id
        UserDefaults.standard.set(stored, forKey: DefaultsKey.selectedFormats)
        publishSource(device: entry.device, summary: format)
    }

    func republishSource() {
        guard let entry = selectedEntry else {
            onCaptureSourceChanged?(nil)
            return
        }
        publishSource(device: entry.device, summary: preferredFormat)
    }

    func refresh() {
        entries = discovery.devices.map(CaptureDeviceEntry.init)

        if let selectedDeviceID {
            if let entry = entries.first(where: { $0.id == selectedDeviceID }) {
                applySelection(entry.device, persist: false)
            } else {
                clearDeviceSpecificState()
                Log.app.notice("Selected capture device is not connected: \(selectedDeviceID, privacy: .public)")
            }
        } else if let fallback = defaultEntry() {
            applySelection(fallback.device, persist: true)
            Log.app.info("Auto-selected '\(fallback.name, privacy: .public)' (\(fallback.transport.displayName, privacy: .public))")
        } else {
            clearDeviceSpecificState()
        }
    }

    func refreshAuthorizationStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status != authorizationStatus else { return }
        authorizationStatus = status
        // Restart selection after permission changes, using a fresh capture input.
        republishSource()
    }

    func requestAuthorization() {
        guard authorizationStatus == .notDetermined else {
            refreshAuthorizationStatus()
            return
        }
        guard !requestingAuthorization else { return }
        requestingAuthorization = true
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            self.requestingAuthorization = false
            self.refreshAuthorizationStatus()
            Log.app.info("Camera access request finished: \(granted ? "granted" : "denied", privacy: .public)")
        }
    }

    private func defaultEntry() -> CaptureDeviceEntry? {
        entries.first { $0.isExternal } ?? entries.first
    }

    private func applySelection(_ device: AVCaptureDevice, persist: Bool) {
        selectedDeviceID = device.uniqueID
        if persist {
            UserDefaults.standard.set(device.uniqueID, forKey: DefaultsKey.selectedDeviceID)
        }

        guard ObjectIdentifier(device) != selectedDeviceIdentity else { return }
        selectedDeviceIdentity = ObjectIdentifier(device)
        loadFormats(for: device)
    }

    private func clearDeviceSpecificState() {
        formats = []
        preferredFormat = nil
        selectedDeviceIdentity = nil
        onCaptureSourceChanged?(nil)
    }

    private func loadFormats(for device: AVCaptureDevice) {
        let summaries = CaptureFormatManager.summaries(for: device)
        formats = summaries
        let stored = UserDefaults.standard.dictionary(forKey: DefaultsKey.selectedFormats) as? [String: String] ?? [:]
        let best = summaries.first { $0.id == stored[device.uniqueID] }
            ?? CaptureFormatManager.preferredFormat(in: summaries, frameRate: frameRatePreference.rate)
        preferredFormat = best
        logPreferredFormat(best)
        publishSource(device: device, summary: best)
    }

    private func publishSource(device: AVCaptureDevice, summary: CaptureFormatSummary?) {
        guard let summary, device.formats.indices.contains(summary.index) else {
            onCaptureSourceChanged?(nil)
            return
        }

        onCaptureSourceChanged?(
            CaptureSourceSelection(
                device: device,
                format: device.formats[summary.index],
                frameRate: min(max(frameRatePreference.rate, summary.minFrameRate), summary.maxFrameRate)
            )
        )
    }

    private func logPreferredFormat(_ summary: CaptureFormatSummary?) {
        guard let summary else {
            Log.app.error("Capture device reports no usable video formats")
            return
        }

        if summary.supports(frameRate: frameRatePreference.rate) {
            Log.app.info("Preferred format: \(summary.resolutionLabel, privacy: .public) @ \(summary.frameRateLabel, privacy: .public) for target \(self.frameRatePreference.displayName, privacy: .public)")
        } else {
            Log.app.notice("Target \(self.frameRatePreference.displayName, privacy: .public) unavailable, closest format is \(summary.resolutionLabel, privacy: .public) @ \(summary.frameRateLabel, privacy: .public)")
        }
    }

    private func startMonitoring() {
        guard monitorTask == nil else { return }

        monitorTask = Task { [weak self] in
            for await _ in Self.deviceChanges() {
                guard let self else { return }
                self.refresh()
                self.refreshAuthorizationStatus()
            }
        }
    }

    private nonisolated static func deviceChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                AVCaptureDevice.wasConnectedNotification,
                AVCaptureDevice.wasDisconnectedNotification
            ]

            let pump = Task {
                await withTaskGroup(of: Void.self) { group in
                    for name in names {
                        group.addTask {
                            for await _ in center.notifications(named: name) {
                                continuation.yield(())
                            }
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in pump.cancel() }
        }
    }
}
