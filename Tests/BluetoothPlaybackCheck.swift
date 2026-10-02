// Runs silent synthetic PCM through the current output; no capture or recording.
// Select Bluetooth headphones first, then:
// swiftc Tests/BluetoothPlaybackCheck.swift BroadcastPlayer/Audio/{AudioRenderQueue,ComfortAudioChain}.swift -o /tmp/BluetoothCheck
// /tmp/BluetoothCheck
import AVFoundation
import Foundation

final class PlaybackProbe: @unchecked Sendable {
    let queue = DispatchQueue(label: "BluetoothPlaybackCheck")
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let renderQueue = AudioRenderQueue()
    let comfortChain = ComfortAudioChain()
    var resets = 0
    var completions = 0

    func run(_ callback: AVAudioPlayerNodeCompletionCallbackType, comfort: Bool = false) throws -> (Int, Int) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        engine.attach(player)
        comfortChain.attach(to: engine)
        try comfortChain.connect(player: player, engine: engine, format: format, enabled: comfort)
        engine.prepare()
        try engine.start()
        player.volume = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in
            let reservation = renderQueue.reserve(960, limit: 7200)
            if reservation.overflow {
                player.stop()
                resets += 1
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 960) }
            let currentEpoch = reservation.epoch
            player.scheduleBuffer(buffer, completionCallbackType: callback) { [weak self] _ in
                guard let self else { return }
                guard self.renderQueue.complete(960, epoch: currentEpoch) else { return }
                self.queue.async { [self] in
                    guard self.renderQueue.isCurrent(currentEpoch) else { return }
                    self.completions += 1
                }
            }
            if !player.isPlaying && reservation.frames >= 1920 { try? player.playAudio() }
        }
        timer.resume()
        Thread.sleep(forTimeInterval: 5)
        return queue.sync {
            timer.cancel()
            renderQueue.reset()
            player.stop()
            engine.stop()
            return (resets, completions)
        }
    }
}
@main struct BluetoothPlaybackCheck {
    static func main() throws {
        let previous = try PlaybackProbe().run(.dataPlayedBack)
        let corrected = try PlaybackProbe().run(.dataRendered)
        let comfort = try PlaybackProbe().run(.dataRendered, comfort: true)
        print("Presentation callback: \(previous.0) resets, \(previous.1) completions")
        print("Render callback: \(corrected.0) resets, \(corrected.1) completions")
        print("Comfort processing: \(comfort.0) resets, \(comfort.1) completions")
        precondition(corrected.0 == 0, "The render queue repeatedly stalled")
        precondition(corrected.1 > 150, "Playback did not render continuously")
        precondition(comfort.0 == 0 && comfort.1 > 150, "Comfort processing stalled playback")
        print("Bluetooth latency no longer overflows the 150 ms source queue: PASS")
    }
}
