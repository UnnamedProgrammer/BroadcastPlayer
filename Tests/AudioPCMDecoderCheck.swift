// swiftc BroadcastPlayer/Audio/AudioPCMDecoder.swift Tests/AudioPCMDecoderCheck.swift -o /tmp/PCMCheck
import AVFoundation
import CoreMedia
import Foundation

@main
struct AudioPCMDecoderCheck {
    static func sample<T>(_ values: [T], format: AVAudioFormat, frames: Int) -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
        let size = values.count * MemoryLayout<T>.stride
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0,
            blockBufferOut: &block) == noErr)
        values.withUnsafeBytes {
            precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: size) == noErr)
        }
        var sample: CMSampleBuffer?
        precondition(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block!, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description!, sampleCount: frames,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }

    static func main() throws {
        let decoder = AudioPCMDecoder()
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
            channels: 2, interleaved: true)!
        let data: [Int16] = [-32768, 32767, -16384, 8192, 0, -8192, 16384, 0]
        let pcm = try decoder.decode(sample(data, format: integer, frames: 4))
        let channels = pcm.floatChannelData!
        for i in 0..<4 {
            precondition(abs(channels[0][i] - Float(data[i * 2]) / 32768) < 0.00001)
            precondition(abs(channels[1][i] - Float(data[i * 2 + 1]) / 32768) < 0.00001)
        }
        print("Signed Int16 normalization, channel separation and negative full scale: PASS")
        let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100,
            channels: 2, interleaved: false)!
        let planar: [Float] = [-1, -0.25, 0, 0.75, 0.5, 0.25, -0.5, 0]
        let floats = try decoder.decode(sample(planar, format: float, frames: 4))
        for c in 0..<2 { for i in 0..<4 {
            precondition(abs(floats.floatChannelData![c][i] - planar[c * 4 + i]) < 0.00001)
        }}
        print("Planar Float32, rate preservation and format switch: PASS")
        var rejected = false
        do { _ = try decoder.decode(sample([Float.nan, 0], format: float, frames: 1)) }
        catch AudioPCMError.invalidSamples { rejected = true }
        precondition(rejected, "Non-finite samples reached playback")
        print("Malformed floating samples are rejected: PASS")
    }
}
