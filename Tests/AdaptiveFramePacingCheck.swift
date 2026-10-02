import CoreVideo
import Foundation

@main struct AdaptiveFramePacingCheck {
    static func main() {
        for fps in [24.0, 30.0, 59.94, 60.0] {
            var pacing = AdaptiveFramePacing()
            pacing.reset(frameRate: fps)
            for i in 0...Int(fps * 3) { pacing.recordArrival(Double(i) / fps) }
            precondition(pacing.capacity == 1, "Stable \(fps) Hz signal did not enter low delay")
            let disturbed = 3.5
            pacing.recordArrival(disturbed)
            precondition(pacing.capacity == 2, "Timing gap did not activate protection")
            for i in 1...Int(fps * 5) { pacing.recordArrival(disturbed + Double(i) / fps) }
            precondition(pacing.capacity == 1, "Protection never recovered")
            pacing.enabled = false
            for i in 1...300 { pacing.recordArrival(10 + Double(i) / fps) }
            precondition(pacing.capacity == 2)
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let queue = CaptureFrameBuffer()
        queue.configure(frameRate: 60)
        for i in 0...180 { queue.store(buffer!, at: Double(i) / 60) }
        precondition(queue.pacingSnapshot().capacity == 1)
        precondition(queue.takeNext()?.generation == 181, "Stable mode retained an old frame")
        queue.store(buffer!, at: 3.04)
        queue.store(buffer!, at: 3.045)
        precondition(queue.pacingSnapshot().capacity == 2)
        precondition(queue.takeNext()?.generation == 182)
        precondition(queue.takeNext()?.generation == 183)
        queue.clear()
        precondition(queue.takeNext() == nil)
        print("Adaptive 24/30/59.94/60 Hz buffering, jitter recovery and ordered bounded queue: PASS")
    }
}
