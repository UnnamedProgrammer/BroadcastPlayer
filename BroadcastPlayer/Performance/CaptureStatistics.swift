import Foundation
import OSLog
import QuartzCore

nonisolated struct CaptureStatsSnapshot: Sendable {
    let deliveredFrames: Int
    let droppedFrames: Int
    let framesPerSecond: Double
    let width: Int
    let height: Int
    let pixelFormatName: String
    let secondsSinceLastFrame: Double
    let hasReceivedFrame: Bool
}

nonisolated final class CaptureStatistics: @unchecked Sendable {
    private let lock = NSLock()

    private var deliveredFrames = 0
    private var droppedFrames = 0
    private var width = 0
    private var height = 0
    private var pixelFormat: OSType = 0
    private var lastFrameTime: Double = 0
    private var windowStart: Double = CACurrentMediaTime()
    private var framesInWindow = 0
    private var framesPerSecond = 0.0
    private var loggedUnsupportedFormat = false

    func recordFrame(pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        lock.lock()
        deliveredFrames += 1
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        if pixelFormat != format {
            pixelFormat = format
            loggedUnsupportedFormat = false
        }
        lastFrameTime = now
        framesInWindow += 1

        let elapsed = now - windowStart
        if elapsed >= 0.5 {
            framesPerSecond = Double(framesInWindow) / elapsed
            framesInWindow = 0
            windowStart = now
        }
        lock.unlock()
    }

    func recordDroppedFrames(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        droppedFrames += count
        lock.unlock()
    }

    func shouldLogUnsupportedFormatOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !loggedUnsupportedFormat else { return false }
        loggedUnsupportedFormat = true
        return true
    }

    func reset() {
        lock.lock()
        deliveredFrames = 0
        droppedFrames = 0
        width = 0
        height = 0
        pixelFormat = 0
        lastFrameTime = 0
        windowStart = CACurrentMediaTime()
        framesInWindow = 0
        framesPerSecond = 0
        loggedUnsupportedFormat = false
        lock.unlock()
    }

    func snapshot() -> CaptureStatsSnapshot {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }

        return CaptureStatsSnapshot(
            deliveredFrames: deliveredFrames,
            droppedFrames: droppedFrames,
            framesPerSecond: framesPerSecond,
            width: width,
            height: height,
            pixelFormatName: FourCC.string(from: Int32(bitPattern: pixelFormat)),
            secondsSinceLastFrame: lastFrameTime > 0 ? now - lastFrameTime : .infinity,
            hasReceivedFrame: deliveredFrames > 0
        )
    }
}