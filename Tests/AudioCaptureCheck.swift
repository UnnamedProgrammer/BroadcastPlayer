// Hardware integration check, without audible playback or file recording.
// swiftc BroadcastPlayer/Audio/AudioCaptureEngine.swift BroadcastPlayer/Audio/AudioPCMDecoder.swift BroadcastPlayer/Audio/AudioRenderQueue.swift BroadcastPlayer/Audio/ComfortAudioChain.swift BroadcastPlayer/Utilities/Logger.swift Tests/AudioCaptureCheck.swift -o /tmp/BroadcastAudioCheck
// /tmp/BroadcastAudioCheck
import AVFoundation
import Foundation

@main
struct AudioCaptureCheck {
    static func main() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw NSError(domain: "AudioTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio access is required for this hardware test."])
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified).devices.filter { $0.transportType == 1970496032 }
        guard devices.count == 1, let device = devices.first else {
            throw NSError(domain: "AudioTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Connect exactly one USB capture-card audio input."])
        }
        let engine = AudioCaptureEngine()
        engine.start(deviceID: device.uniqueID, volume: 0)
        let deadline = Date().addingTimeInterval(8)
        while !engine.snapshot().isReceiving && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let first = engine.snapshot()
        precondition(first.error == nil, "\(first.error ?? "")")
        precondition(first.isReceiving && first.receivedBuffers > 0, "No audio callbacks")
        precondition(first.isPCM, "Capture input should expose PCM")
        let native = device.formats.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0.formatDescription)?.pointee }
        precondition(native.contains { $0.mSampleRate == first.sampleRate && $0.mChannelsPerFrame == first.channels && $0.mBitsPerChannel == first.bits }, "Native format was changed")
        print("Native PCM: \(first.sampleRate) Hz, \(first.channels) channels, \(first.bits) bits: PASS")
        engine.setVolume(0)
        Thread.sleep(forTimeInterval: 2)
        let playing = engine.snapshot()
        precondition(playing.error == nil, "\(playing.error ?? "")")
        precondition(playing.playedBuffers > 20, "Buffers were captured but never played")
        precondition(playing.peak.isFinite && playing.peak <= 1.0001, "Invalid sample amplitude")
        precondition(playing.playbackResets < 3, "Repeated playback underruns")
        print("Playback completions \(playing.playedBuffers), resets \(playing.playbackResets), peak \(playing.peak): PASS")
        precondition(engine.snapshot().receivedBuffers > first.receivedBuffers, "Mute stopped source capture")
        print("Muted playback keeps source capture running: PASS")
        engine.stop()
        Thread.sleep(forTimeInterval: 0.5)
        precondition(engine.snapshot().receivedBuffers == 0 && !engine.snapshot().isReceiving, "Stop retained audio")
        print("Stop clears queued capture state: PASS")
        engine.start(deviceID: device.uniqueID, volume: 0)
        let restartDeadline = Date().addingTimeInterval(5)
        while !engine.snapshot().isReceiving && Date() < restartDeadline { Thread.sleep(forTimeInterval: 0.1) }
        precondition(engine.snapshot().isReceiving, "Restart failed")
        engine.stop()
        Thread.sleep(forTimeInterval: 0.3)
        print("Restart native input: PASS")
    }
}
