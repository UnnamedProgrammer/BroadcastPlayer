import AVFoundation
import Foundation
import Observation
import OSLog

@Observable
final class CaptureManager {
    let renderer: MetalRenderer?

    private(set) var configuration: CaptureConfiguration?
    private(set) var errorMessage: String?
    private(set) var isRunning = false
    private(set) var inputWidth = 0
    private(set) var inputHeight = 0
    private(set) var inputFrameRate = 0.0
    private(set) var measuredInputFPS = 0.0
    private(set) var deliveredFrames = 0
    private(set) var droppedFrames = 0
    private(set) var renderedFrames = 0
    private(set) var displayedFPS = 0.0
    private(set) var processingMilliseconds = 0.0
    private(set) var displayJitterMilliseconds = 0.0
    private(set) var gpuMilliseconds = 0.0
    private(set) var videoBufferDescription = "2 frames"
    private(set) var captureJitterMilliseconds = 0.0
    private(set) var colorDescription = "—"
    private(set) var pixelFormatName = "—"
    private(set) var isReceivingFrames = false

    private let engine = CaptureEngine()
    private var statsTask: Task<Void, Never>?

    init() {
        var rendererError: String?
        var createdRenderer: MetalRenderer?

        do {
            createdRenderer = try MetalRenderer.make()
        } catch {
            createdRenderer = nil
            rendererError = error.localizedDescription
        }

        self.renderer = createdRenderer
        self.errorMessage = rendererError

        createdRenderer?.attach(source: engine.frameBuffer)

        if let rendererError {
            Log.render.error("Metal setup failed: \(rendererError, privacy: .public)")
        }

        startStatsPolling()
    }

    var inputResolutionDescription: String {
        guard inputWidth > 0, inputHeight > 0 else { return "—" }
        return "\(inputWidth)×\(inputHeight)"
    }

    var inputFrameRateDescription: String {
        guard configuration != nil else { return "—" }
        return String(format: "%.2f fps", measuredInputFPS)
    }

    func start(device: AVCaptureDevice, format: AVCaptureDevice.Format, frameRate: Double) {
        do {
            let configuration = try engine.configure(device: device, format: format, frameRate: frameRate)
            self.configuration = configuration
            inputWidth = configuration.width
            inputHeight = configuration.height
            inputFrameRate = configuration.frameRate
            errorMessage = nil
            engine.start()
        } catch {
            errorMessage = error.localizedDescription
            configuration = nil
            Log.capture.error("Capture configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        engine.stop()
        configuration = nil
        isReceivingFrames = false
    }

    private func startStatsPolling() {
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }

                guard let self else { return }
                self.publishStats()
            }
        }
    }

    private func publishStats() {
        let snapshot = engine.statistics.snapshot()
        let receivingNow = snapshot.hasReceivedFrame && snapshot.secondsSinceLastFrame < 1.0

        if receivingNow != isReceivingFrames {
            if receivingNow {
                Log.capture.info("Receiving video: \(snapshot.width)x\(snapshot.height), format '\(snapshot.pixelFormatName, privacy: .public)'")
            } else {
                Log.capture.notice("Video signal lost")
            }
        }

        if snapshot.width > 0, snapshot.height > 0 {
            inputWidth = snapshot.width
            inputHeight = snapshot.height
        }

        measuredInputFPS = receivingNow ? snapshot.framesPerSecond : 0
        deliveredFrames = snapshot.deliveredFrames
        droppedFrames = snapshot.droppedFrames
        pixelFormatName = snapshot.hasReceivedFrame ? snapshot.pixelFormatName : "—"
        isReceivingFrames = receivingNow
        isRunning = engine.isRunning
        if configuration != nil { errorMessage = engine.errorMessage }
        let presentation = renderer?.statistics.snapshot()
        renderedFrames = presentation?.presentedFrames ?? 0
        displayedFPS = receivingNow ? presentation?.framesPerSecond ?? 0 : 0
        processingMilliseconds = receivingNow ? presentation?.processingMilliseconds ?? 0 : 0
        displayJitterMilliseconds = presentation?.intervalJitterMilliseconds ?? 0
        gpuMilliseconds = presentation?.gpuMilliseconds ?? 0
        colorDescription = renderer?.colorDescription ?? "—"
        let pacing = engine.frameBuffer.pacingSnapshot()
        captureJitterMilliseconds = pacing.jitterMilliseconds
        videoBufferDescription = pacing.adaptive
            ? (pacing.capacity == 1 ? "1 frame · low delay" : "2 frames · jitter protection")
            : "2 frames · fixed"
    }
}