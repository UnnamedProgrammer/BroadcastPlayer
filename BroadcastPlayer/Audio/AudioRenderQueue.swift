import Foundation

// Render completions must release capacity immediately, even while the capture
// dispatch queue is busy. Epochs isolate completions from stopped player runs.
nonisolated final class AudioRenderQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var epoch: UInt64 = 0

    func reset() {
        lock.lock()
        epoch &+= 1
        frames = 0
        lock.unlock()
    }

    func reserve(_ count: Int, limit: Int) -> (epoch: UInt64, frames: Int, overflow: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let overflow = frames + count > limit
        if overflow { epoch &+= 1; frames = 0 }
        frames += count
        return (epoch, frames, overflow)
    }

    func complete(_ count: Int, epoch expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == expected else { return false }
        frames = max(0, frames - count)
        return true
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return epoch == expected
    }
}
