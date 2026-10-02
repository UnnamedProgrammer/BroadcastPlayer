import AVFoundation
import Foundation
import Observation

@Observable
final class AudioCaptureManager {
    private enum Key {
        static let enabled = "audio.enabled"
        static let volume = "audio.volume"
        static let muted = "audio.muted"
        static let comfort = "audio.comfort"
        static let inputID = "audio.inputID"
    }

    private(set) var devices: [AVCaptureDevice] = []
    private(set) var selectedInputID = ""
    private(set) var isEnabled = true
    private(set) var isMuted = false
    private(set) var isComfortEnabled = false
    private(set) var volume = 1.0
    private(set) var sourceName = "No audio input"
    private(set) var formatDescription = "Waiting for audio"
    private(set) var errorMessage: String?
    private(set) var isReceiving = false
    private(set) var outputDescription = "System output"
    private(set) var outputLatencyMilliseconds = 0.0
    private(set) var playbackResets = 0
    private(set) var authorization = AVCaptureDevice.authorizationStatus(for: .audio)

    private let engine = AudioCaptureEngine()
    private var videoDevice: AVCaptureDevice?
    private var activeInputID: String?
    private var polling: Task<Void, Never>?
    private var requestingAccess = false
    private var refreshTicks = 0

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        isMuted = defaults.bool(forKey: Key.muted)
        isComfortEnabled = defaults.bool(forKey: Key.comfort)
        engine.setComfort(isComfortEnabled)
        let saved = defaults.object(forKey: Key.volume) as? Double ?? 1
        volume = saved.isFinite ? min(max(saved, 0), 1) : 1
        selectedInputID = defaults.string(forKey: Key.inputID) ?? ""
        refreshDevices()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.refreshTicks += 1
                if self.refreshTicks % 4 == 0 {
                    self.refreshDevices()
                    self.resolveInput()
                }
                self.publishStats()
            }
        }
    }

    func followVideo(_ device: AVCaptureDevice?) {
        videoDevice = device
        resolveInput()
    }

    func updateEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: Key.enabled)
        resolveInput()
    }

    func updateInput(_ id: String) {
        selectedInputID = id
        UserDefaults.standard.set(id, forKey: Key.inputID)
        resolveInput()
    }

    func updateVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(max(value, 0), 1)
        UserDefaults.standard.set(volume, forKey: Key.volume)
        engine.setVolume(isMuted ? 0 : Float(volume))
    }

    func updateComfort(_ enabled: Bool) {
        isComfortEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.comfort)
        engine.setComfort(enabled)
    }

    func testSpeakers() { engine.testSpeakers() }

    func updateMuted(_ value: Bool) {
        isMuted = value
        UserDefaults.standard.set(value, forKey: Key.muted)
        engine.setVolume(value ? 0 : Float(volume))
    }

    private func refreshDevices() {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.filter {
            // Auto routing must never feed the laptop microphone into its speakers.
            [.usb, .thunderbolt, .pci, .hdmi, .displayPort, .fireWire].contains(CaptureTransport.from(code: $0.transportType))
        }
        if discovered.map(\.uniqueID) != devices.map(\.uniqueID) { devices = discovered }
        authorization = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func matchedInput() -> AVCaptureDevice? {
        guard let videoDevice else { return nil }
        if !selectedInputID.isEmpty { return devices.first { $0.uniqueID == selectedInputID } }
        let videoName = Self.normalized(videoDevice.localizedName)
        guard !videoName.isEmpty else { return nil }
        let matched = devices.filter {
            Self.normalized($0.uniqueID).contains(videoName) || Self.normalized($0.localizedName) == videoName
        }
        if matched.count == 1 { return matched[0] }
        // Ambiguous or unrelated inputs require an explicit selection.
        return nil
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "video", with: "")
            .replacingOccurrences(of: "audio", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }

    private func resolveInput() {
        let device = isEnabled ? matchedInput() : nil
        sourceName = device?.localizedName ?? (isEnabled ? "No matching audio input" : "Audio off")
        guard let device else {
            if activeInputID != nil { engine.stop() }
            activeInputID = nil
            errorMessage = nil
            isReceiving = false
            outputDescription = "System output"
            outputLatencyMilliseconds = 0
            playbackResets = 0
            return
        }
        guard authorization == .authorized else {
            if activeInputID != nil { engine.stop(); activeInputID = nil }
            isReceiving = false
            if authorization == .notDetermined {
                errorMessage = "Allow audio input access to play capture-card sound."
                if !requestingAccess {
                    requestingAccess = true
                    Task { [weak self] in
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        guard let self else { return }
                        self.requestingAccess = false
                        self.authorization = AVCaptureDevice.authorizationStatus(for: .audio)
                        self.resolveInput()
                    }
                }
            } else {
                errorMessage = "Allow BroadcastPlayer in System Settings → Privacy & Security → Microphone."
            }
            return
        }
        guard activeInputID != device.uniqueID else { return }
        activeInputID = device.uniqueID
        errorMessage = nil
        formatDescription = "Waiting for audio"
        engine.start(deviceID: device.uniqueID, volume: isMuted ? 0 : Float(volume))
    }

    private func publishStats() {
        guard isEnabled, activeInputID != nil, authorization == .authorized else { return }
        let snapshot = engine.snapshot()
        errorMessage = snapshot.error
        playbackResets = snapshot.playbackResets
        outputLatencyMilliseconds = snapshot.outputLatencyMilliseconds
        if snapshot.outputSampleRate > 0 {
            outputDescription = "\(snapshot.outputName) · \(String(format: "%g", snapshot.outputSampleRate / 1000)) kHz"
        }
        isReceiving = snapshot.isReceiving
        if snapshot.sampleRate > 0 {
            let rate = String(format: "%g", snapshot.sampleRate / 1000)
            let inputBits = snapshot.sourceBits > 0 ? snapshot.sourceBits : snapshot.bits
            let stream = snapshot.isFloat ? " · Float\(snapshot.bits) stream" : ""
            formatDescription = "\(rate) kHz · \(snapshot.channels) ch · \(inputBits)-bit input\(snapshot.isPCM ? " PCM" : "")\(stream)"
        }
    }
}
