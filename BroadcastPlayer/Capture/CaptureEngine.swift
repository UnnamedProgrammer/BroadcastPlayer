import AVFoundation
import CoreMedia
import Foundation
import OSLog

nonisolated enum CaptureEngineError: LocalizedError {
    case cannotAddInput(String)
    case cannotAddOutput
    case configurationLockFailed(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .cannotAddInput(let name):
            "The capture session cannot use \"\(name)\" as a video input."
        case .cannotAddOutput:
            "The capture session cannot add a video data output."
        case .configurationLockFailed(let reason):
            "The capture device could not be locked for configuration (\(reason))."
        case .notConfigured:
            "The capture engine was started before a device was configured."
        }
    }
}

nonisolated struct CaptureConfiguration: Sendable {
    let deviceName: String
    let width: Int
    let height: Int
    let frameRate: Double
}

nonisolated final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let frameBuffer = CaptureFrameBuffer()
    let statistics = CaptureStatistics()

    private let queue = DispatchQueue(label: "com.broadcastplayer.capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var running = false
    private var wantsToRun = false
    private var recoveryEpoch: UInt64 = 0
    private var recoveryAttempts = 0
    private var observers: [NSObjectProtocol] = []
    private var runtimeError: String?

    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "Video capture stopped unexpectedly."
            guard let self else { return }
            self.queue.async { [self] in recover(reason: reason) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [self] in
                if wantsToRun { recover(reason: "Capture interruption ended") }
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var errorMessage: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtimeError
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    func configure(
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        frameRate: Double
    ) throws -> CaptureConfiguration {
        try queue.sync {
            try performConfiguration(device: device, format: format, frameRate: frameRate)
        }
    }

    func start() {
        queue.async { [self] in
            guard configured else {
                Log.capture.error("Capture start requested before configuration")
                return
            }
            wantsToRun = true
            recoveryEpoch &+= 1
            recoveryAttempts = 0
            guard !self.session.isRunning else { return }

            self.session.startRunning()
            self.setRunning(self.session.isRunning)
            Log.capture.info("Capture session started, running=\(self.session.isRunning, privacy: .public)")
        }
    }

    func stop() {
        queue.async { [self] in
            wantsToRun = false
            recoveryEpoch &+= 1
            frameBuffer.clear()
            guard self.session.isRunning else {
                self.setRunning(false)
                return
            }
            self.session.stopRunning()
            self.setRunning(false)
            self.frameBuffer.clear()
            Log.capture.info("Capture session stopped")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if recoveryAttempts > 0 {
            recoveryAttempts = 0
            stateLock.lock()
            runtimeError = nil
            stateLock.unlock()
        }
        statistics.recordFrame(pixelBuffer: pixelBuffer)
        frameBuffer.store(pixelBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        statistics.recordDroppedFrames(1)
        Log.capture.notice("Capture output dropped a frame")
    }

    private func performConfiguration(
        device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        frameRate: Double
    ) throws -> CaptureConfiguration {
        configured = false
        recoveryEpoch &+= 1
        stateLock.lock()
        runtimeError = nil
        stateLock.unlock()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input {
            session.removeInput(input)
            self.input = nil
        }

        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureEngineError.cannotAddInput(device.localizedName)
        }

        guard session.canAddInput(newInput) else {
            throw CaptureEngineError.cannotAddInput(device.localizedName)
        }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(where: { $0 === output }) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

            guard session.canAddOutput(output) else {
                throw CaptureEngineError.cannotAddOutput
            }
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: queue)
        }

        let requestedDuration = Self.resolvedFrameDuration(in: format, desiredRate: frameRate)

        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureEngineError.configurationLockFailed(error.localizedDescription)
        }

        device.activeFormat = format
        device.activeVideoMinFrameDuration = requestedDuration
        device.activeVideoMaxFrameDuration = requestedDuration
        device.unlockForConfiguration()

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(dimensions.width),
            kCVPixelBufferHeightKey as String: Int(dimensions.height)
        ]
        let appliedDuration = device.activeVideoMinFrameDuration
        let appliedRate = appliedDuration.isValid && appliedDuration.seconds > 0
            ? 1.0 / appliedDuration.seconds
            : frameRate

        configured = true
        statistics.reset()
        frameBuffer.clear()
        frameBuffer.configure(frameRate: appliedRate)

        let configuration = CaptureConfiguration(
            deviceName: device.localizedName,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            frameRate: appliedRate
        )
        Log.capture.info("Configured '\(configuration.deviceName, privacy: .public)' at \(configuration.width)x\(configuration.height) @ \(Self.rateText(appliedRate), privacy: .public) fps")
        return configuration
    }

    private func recover(reason: String) {
        guard wantsToRun, configured else { return }
        guard recoveryAttempts < 3 else {
            setRunning(false)
            stateLock.lock()
            runtimeError = "Video capture could not restart. Reconnect the capture device."
            stateLock.unlock()
            return
        }
        recoveryAttempts += 1
        recoveryEpoch &+= 1
        let epoch = recoveryEpoch
        setRunning(false)
        stateLock.lock()
        runtimeError = "Recovering video capture… \(reason)"
        stateLock.unlock()
        Log.capture.notice("Restarting video capture after: \(reason, privacy: .public)")
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            guard wantsToRun, configured, recoveryEpoch == epoch else { return }
            if session.isRunning { session.stopRunning() }
            session.startRunning()
            setRunning(session.isRunning)
            if !session.isRunning {
                recover(reason: reason)
            } else {
                stateLock.lock()
                runtimeError = nil
                stateLock.unlock()
            }
        }
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        running = value
        stateLock.unlock()
    }

    private static func resolvedFrameDuration(in format: AVCaptureDevice.Format, desiredRate: Double) -> CMTime {
        let safeRate = max(desiredRate, 1)
        let desired = CMTime(seconds: 1.0 / safeRate, preferredTimescale: 60000)

        let ranges = format.videoSupportedFrameRateRanges.filter {
            $0.minFrameDuration.isValid && $0.maxFrameDuration.isValid && $0.minFrameDuration.seconds > 0
        }

        guard let range = ranges.first(where: {
            $0.minFrameRate - 0.5 <= safeRate && safeRate <= $0.maxFrameRate + 0.5
        }) ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else {
            return desired
        }

        let shorter = min(range.minFrameDuration, range.maxFrameDuration)
        let longer = max(range.minFrameDuration, range.maxFrameDuration)
        return min(max(desired, shorter), longer)
    }

    private static func rateText(_ rate: Double) -> String {
        String(format: "%.2f", rate)
    }
}