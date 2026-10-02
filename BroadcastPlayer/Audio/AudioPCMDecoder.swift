import AVFoundation
import CoreMedia
import Foundation

nonisolated enum AudioPCMError: LocalizedError {
    case invalidFormat
    case copyFailed(OSStatus)
    case invalidSamples

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Unsupported PCM audio format from the capture device."
        case .copyFailed(let status): "Cannot copy audio samples (\(status))."
        case .invalidSamples: "The capture device delivered invalid audio samples."
        }
    }
}

// Use the complete ASBD (including interleaving and signed/float flags), rather
// than assuming the storage layout from the bit depth or channel count alone.
nonisolated final class AudioPCMDecoder {
    private var converter: AVAudioConverter?

    func decode(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw AudioPCMError.invalidFormat
        }
        var asbd = stream.pointee
        let count = CMSampleBufferGetNumSamples(sample)
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              count > 0, count <= Int(Int32.max),
              let inputFormat = AVAudioFormat(streamDescription: &asbd),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw AudioPCMError.invalidFormat
        }
        input.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
            frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard status == noErr else { throw AudioPCMError.copyFailed(status) }
        if converter?.inputFormat != inputFormat || converter?.outputFormat != outputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        guard let converter else { throw AudioPCMError.invalidFormat }
        // Same rate and channel count: this changes sample representation only.
        try converter.convert(to: output, from: input)
        guard output.frameLength == input.frameLength, let channels = output.floatChannelData else {
            throw AudioPCMError.invalidFormat
        }
        for channel in 0..<Int(output.format.channelCount) {
            for index in 0..<Int(output.frameLength) {
                let value = channels[channel][index]
                guard value.isFinite, abs(value) <= 1.0001 else { throw AudioPCMError.invalidSamples }
            }
        }
        return output
    }
}
