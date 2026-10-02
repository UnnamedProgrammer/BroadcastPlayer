import AVFoundation
import Foundation
import Observation
import OSLog

@Observable
final class AppState {
    private enum DefaultsKey {
        static let verboseLogging = "diagnostics.verboseLogging"
        static let adaptiveLatency = "video.adaptiveLatency"
        static let shadowLift = "video.shadowLift"
        static let sharpness = "video.claritySharpness"
        static let natural4K = "video.natural4K"
        static let adaptsTo16By10 = "video.adaptsTo16By10"
        static let fillFullScreen = "video.fillFullScreen"
    }

    let devices = CaptureDeviceManager()
    let capture = CaptureManager()
    let audio = AudioCaptureManager()

    private(set) var statusMessage = "Idle"
    private(set) var launchDate = Date()
    private(set) var isVerboseLoggingEnabled = false
    private(set) var isNatural4KEnabled = true
    private(set) var sharpness = 0.35
    private(set) var shadowLift = 0.0
    private(set) var usesAdaptiveLatency = true
    private(set) var comparesOriginal = false
    var canCompare: Bool {
        isNatural4KEnabled && VideoGeometry.upscaleSize(width: capture.inputWidth, height: capture.inputHeight) != nil
    }
    private(set) var adaptsTo16By10 = false
    private(set) var fillsFullScreen = false

    init() {
        isVerboseLoggingEnabled = UserDefaults.standard.bool(forKey: DefaultsKey.verboseLogging)

        adaptsTo16By10 = UserDefaults.standard.bool(forKey: DefaultsKey.adaptsTo16By10)
        capture.renderer?.adaptsTo16By10 = adaptsTo16By10
        fillsFullScreen = UserDefaults.standard.object(forKey: DefaultsKey.fillFullScreen) as? Bool ?? false
        isNatural4KEnabled = UserDefaults.standard.object(forKey: DefaultsKey.natural4K) as? Bool ?? true
        let savedSharpness = UserDefaults.standard.object(forKey: DefaultsKey.sharpness) as? Double ?? 0.35
        sharpness = savedSharpness.isFinite ? min(max(savedSharpness, 0), 1) : 0.35
        capture.renderer?.sharpness = Float(sharpness)
        capture.renderer?.isNatural4KEnabled = isNatural4KEnabled

        usesAdaptiveLatency = UserDefaults.standard.object(forKey: DefaultsKey.adaptiveLatency) as? Bool ?? true
        capture.renderer?.setAdaptiveQueue(usesAdaptiveLatency)
        let savedLift = UserDefaults.standard.double(forKey: DefaultsKey.shadowLift)
        shadowLift = savedLift.isFinite ? min(max(savedLift, 0), 1) : 0
        capture.renderer?.shadowLift = Float(shadowLift)

        devices.onCaptureSourceChanged = { [weak self] selection in
            guard let self else { return }
            guard let selection else {
                self.capture.stop()
                self.audio.followVideo(nil)
                return
            }
            guard self.devices.authorizationStatus == .authorized else {
                self.capture.stop()
                self.audio.followVideo(nil)
                if self.devices.authorizationStatus == .notDetermined {
                    self.devices.requestAuthorization()
                }
                return
            }
            self.capture.start(
                device: selection.device,
                format: selection.format,
                frameRate: selection.frameRate
            )
            self.audio.followVideo(self.capture.configuration != nil ? selection.device : nil)
        }

        devices.republishSource()
    }

    func update16By10(_ enabled: Bool) {
        adaptsTo16By10 = enabled
        capture.renderer?.adaptsTo16By10 = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.adaptsTo16By10)
        if enabled {
            updateNatural4K(true)
            devices.updateFrameRatePreference(.fps60)
            if let format = devices.formats.first(where: {
                $0.width == 1920 && $0.height == 1080 && $0.supports(frameRate: 60)
            }) {
                devices.selectFormat(id: format.id)
            }
        }
    }

    func updateAdaptiveLatency(_ enabled: Bool) {
        usesAdaptiveLatency = enabled
        capture.renderer?.setAdaptiveQueue(enabled)
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.adaptiveLatency)
    }

    func updateShadowLift(_ value: Double) {
        guard value.isFinite else { return }
        shadowLift = min(max(value, 0), 1)
        capture.renderer?.shadowLift = Float(shadowLift)
        UserDefaults.standard.set(shadowLift, forKey: DefaultsKey.shadowLift)
    }

    func updateSharpness(_ value: Double) {
        guard value.isFinite else { return }
        sharpness = min(max(value, 0), 1)
        capture.renderer?.sharpness = Float(sharpness)
        UserDefaults.standard.set(sharpness, forKey: DefaultsKey.sharpness)
    }

    func updateComparison(_ enabled: Bool) {
        comparesOriginal = enabled
        capture.renderer?.comparesOriginal = enabled
    }

    func updateFillFullScreen(_ enabled: Bool) {
        fillsFullScreen = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.fillFullScreen)
    }

    func updateNatural4K(_ enabled: Bool) {
        isNatural4KEnabled = enabled
        capture.renderer?.isNatural4KEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.natural4K)
    }

    func updateVerboseLogging(_ enabled: Bool) {
        guard enabled != isVerboseLoggingEnabled else { return }
        isVerboseLoggingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.verboseLogging)
        Log.app.info("Verbose logging \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    func setStatus(_ message: String) {
        statusMessage = message
        Log.app.info("Status: \(message, privacy: .public)")
    }

    func logProbe() {
        Log.app.info("Video: \(self.capture.inputResolutionDescription, privacy: .public), capture \(self.capture.measuredInputFPS) fps, display \(self.capture.displayedFPS) fps, app delay \(self.capture.processingMilliseconds) ms, drops \(self.capture.droppedFrames)")
        Log.app.info("Color: \(self.capture.colorDescription, privacy: .public), 4K \(self.isNatural4KEnabled), 16:10 \(self.adaptsTo16By10), sharpness \(self.sharpness)")
        Log.app.info("Audio: \(self.audio.formatDescription, privacy: .public) → \(self.audio.outputDescription, privacy: .public), output latency \(self.audio.outputLatencyMilliseconds) ms, queue resets \(self.audio.playbackResets)")
        setStatus("Diagnostics saved")
    }
}
