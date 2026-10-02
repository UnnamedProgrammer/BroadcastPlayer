import Foundation

nonisolated struct FramePacingSnapshot: Sendable {
    let capacity: Int
    let jitterMilliseconds: Double
    let adaptive: Bool
}

nonisolated struct AdaptiveFramePacing {
    private var period = 1.0 / 60
    private var lastArrival: Double?
    private var stableSince: Double?
    private var protectUntil = -Double.infinity
    private var deviation = 0.0
    private(set) var capacity = 2
    var enabled = true {
        didSet { capacity = 2; stableSince = nil }
    }

    mutating func reset(frameRate: Double) {
        period = 1 / max(1, frameRate.isFinite ? frameRate : 60)
        lastArrival = nil
        stableSince = nil
        protectUntil = -Double.infinity
        deviation = 0
        capacity = 2
    }

    mutating func recordArrival(_ time: Double) {
        defer { lastArrival = time }
        guard let previous = lastArrival else { stableSince = time; return }
        let interval = time - previous
        guard interval > 0 else { protect(at: time); return }
        let error = abs(interval - period)
        deviation += 0.05 * (min(error, period * 3) - deviation)
        if error > period * 0.35 {
            protect(at: time)
        } else if enabled, time >= protectUntil {
            if stableSince == nil { stableSince = time }
            if time - stableSince! >= 2 { capacity = 1 }
        }
        if !enabled { capacity = 2 }
    }

    mutating func protect(at time: Double) {
        protectUntil = time + 2
        stableSince = nil
        capacity = 2
    }

    var snapshot: FramePacingSnapshot {
        FramePacingSnapshot(capacity: capacity, jitterMilliseconds: deviation * 1000, adaptive: enabled)
    }
}
