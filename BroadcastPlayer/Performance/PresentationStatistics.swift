import Foundation
import QuartzCore

nonisolated struct PresentationSnapshot: Sendable {
    let framesPerSecond: Double
    let processingMilliseconds: Double
    let presentedFrames: Int
    let intervalJitterMilliseconds: Double
    let gpuMilliseconds: Double
}

nonisolated final class PresentationStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: Double, delay: Double)] = []
    private var count = 0
    private var gpuMilliseconds = 0.0

    func record(time: Double, arrival: Double) {
        lock.lock()
        defer { lock.unlock() }
        // Presentation callbacks can arrive on different driver threads.
        samples.append((time, max(0, time - arrival)))
        samples.sort { $0.time < $1.time }
        let newest = samples.last!.time
        samples.removeAll { newest - $0.time > 2 }
        count += 1
    }

    func recordGPU(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        gpuMilliseconds += 0.1 * (milliseconds - gpuMilliseconds)
        lock.unlock()
    }

    func snapshot(now: Double = CACurrentMediaTime()) -> PresentationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last,
              now - last.time < 1, samples.count > 1 else {
            return PresentationSnapshot(framesPerSecond: 0, processingMilliseconds: 0, presentedFrames: count, intervalJitterMilliseconds: 0, gpuMilliseconds: gpuMilliseconds)
        }
        let intervals = zip(samples.dropFirst(), samples).map { $0.time - $1.time }
        let mean = (last.time - first.time) / Double(intervals.count)
        let variance = intervals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(intervals.count)
        return PresentationSnapshot(
            framesPerSecond: Double(samples.count - 1) / max(last.time - first.time, 0.001),
            processingMilliseconds: samples.reduce(0) { $0 + $1.delay } / Double(samples.count) * 1000,
            presentedFrames: count, intervalJitterMilliseconds: sqrt(variance) * 1000, gpuMilliseconds: gpuMilliseconds)
    }
}
