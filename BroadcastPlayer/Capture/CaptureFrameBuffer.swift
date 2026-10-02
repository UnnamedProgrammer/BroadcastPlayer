import CoreVideo
import Foundation
import QuartzCore

nonisolated struct CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let generation: UInt64
    let arrivalTime: Double
}

nonisolated final class CaptureFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CapturedFrame?
    private var pending: [CapturedFrame] = []
    private var generation: UInt64 = 0
    private var pacing = AdaptiveFramePacing()

    func store(_ buffer: CVPixelBuffer, at arrival: Double = CACurrentMediaTime()) {
        lock.lock()
        pacing.recordArrival(arrival)
        generation &+= 1
        let frame = CapturedFrame(pixelBuffer: buffer, generation: generation, arrivalTime: arrival)
        latest = frame
        pending.append(frame)
        // Absorb capture/display clock jitter without accumulating old frames.
        if pending.count > pacing.capacity { pending.removeFirst(pending.count - pacing.capacity) }
        lock.unlock()
    }

    // Buffer, sequence and time must describe the same capture callback.
    func snapshot() -> CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func takeNext() -> CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty ? latest : pending.removeFirst()
    }

    func configure(frameRate: Double) {
        lock.lock()
        pacing.reset(frameRate: frameRate)
        lock.unlock()
    }

    func setAdaptive(_ enabled: Bool) {
        lock.lock()
        pacing.enabled = enabled
        lock.unlock()
    }

    func protectFromDisplayStall(at time: Double) {
        lock.lock()
        pacing.protect(at: time)
        lock.unlock()
    }

    func pacingSnapshot() -> FramePacingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return pacing.snapshot
    }

    func clear() {
        lock.lock()
        latest = nil
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
