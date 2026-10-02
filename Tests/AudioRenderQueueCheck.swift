import Foundation

@main struct AudioRenderQueueCheck {
    static func main() {
        let queue = AudioRenderQueue()
        let capture = DispatchQueue(label: "capture-test")
        let blocked = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let first = queue.reserve(1920, limit: 7200)
        capture.async { entered.signal(); blocked.wait() }
        entered.wait()
        // The render thread drains capacity while USB capture work is blocked.
        precondition(queue.complete(1920, epoch: first.epoch))
        for _ in 0..<1000 {
            let next = queue.reserve(960, limit: 7200)
            precondition(!next.overflow, "Delayed capture accounting caused a false overflow")
            precondition(queue.complete(960, epoch: next.epoch))
        }
        blocked.signal(); capture.sync {}
        let beforeReset = queue.reserve(1920, limit: 7200)
        queue.reset()
        let afterReset = queue.reserve(1920, limit: 7200)
        precondition(!queue.complete(1920, epoch: beforeReset.epoch))
        precondition(queue.isCurrent(afterReset.epoch))
        let overflow = queue.reserve(6000, limit: 7200)
        precondition(overflow.overflow && overflow.frames == 6000)
        precondition(!queue.complete(1920, epoch: afterReset.epoch))
        precondition(queue.complete(6000, epoch: overflow.epoch))
        print("Render accounting during capture stalls, stale callbacks and bounded overflow: PASS")
    }
}
