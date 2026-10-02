import AVFoundation
import Foundation

@main struct ComfortAudioCheck {
    static func render(enabled: Bool, rightSilent: Bool = false) throws -> [Float] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), chain = ComfortAudioChain()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        engine.attach(player); chain.attach(to: engine)
        try chain.connect(player: player, engine: engine, format: format, enabled: enabled)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120000)!
        input.frameLength = 120000
        for i in 0..<120000 {
            let amplitude: Double = i < 24000 ? 0.02 : i < 72000 ? 0.98 : i < 96000 ? 0.02 : 0
            let value = Float(amplitude * sin(2 * Double.pi * 440 * Double(i) / 48000))
            input.floatChannelData![0][i] = value
            input.floatChannelData![1][i] = rightSilent ? 0 : value
        }
        player.scheduleBuffer(input)
        engine.prepare(); try engine.start(); try player.playAudio()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var samples: [Float] = [], attempts = 0
        while samples.count < 120000 {
            let n = AVAudioFrameCount(min(1024, 120000 - samples.count))
            let status = try engine.renderOffline(n, to: output)
            if status != .success {
                attempts += 1; precondition(attempts < 20, "Offline render stalled: \(status)"); continue
            }
            for i in 0..<Int(output.frameLength) {
                let l = output.floatChannelData![0][i], r = output.floatChannelData![1][i]
                precondition(l.isFinite && r.isFinite)
                if rightSilent {
                    precondition(abs(r) < 0.00001, "Left channel leaked into the right channel")
                } else {
                    precondition(abs(l - r) < 0.00001, "Stereo image changed")
                }
                samples.append(l)
            }
        }
        player.stop(); engine.stop()
        return samples
    }

    static func rms(_ samples: [Float], _ range: Range<Int>) -> Double {
        sqrt(samples[range].reduce(0.0) { $0 + Double($1 * $1) } / Double(range.count))
    }

    static func main() throws {
        let raw = try render(enabled: false), comfortable = try render(enabled: true)
        let quiet = 12000..<20000, loud = 40000..<60000
        let rawQuiet = rms(raw, quiet), newQuiet = rms(comfortable, quiet)
        let rawLoud = rms(raw, loud), newLoud = rms(comfortable, loud)
        print("Quiet RMS: \(rawQuiet) → \(newQuiet); loud RMS: \(rawLoud) → \(newLoud)")
        precondition(abs(rawQuiet - 0.02 / sqrt(2)) < 0.0001, "Bypass altered PCM levels")
        precondition(newQuiet > rawQuiet * 1.2, "Quiet sounds did not lift")
        precondition(newLoud < rawLoud * 0.85, "Loud sounds did not compress")
        precondition(comfortable.map { abs($0) }.max()! <= 1.001, "Output clipped")
        precondition(rms(comfortable, 110000..<120000) < 0.00001, "Silence became noise")
        let steps = zip(comfortable.dropFirst(), comfortable).map { abs($0 - $1) }
        precondition(steps.max()! < 0.15, "DSP introduced a sharp discontinuity")
        _ = try render(enabled: true, rightSilent: true)
        print("Comfort compression, peak limiting, stereo preservation, silent tail and bypass: PASS")
    }
}
