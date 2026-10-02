import AVFoundation
import AudioToolbox

nonisolated final class ComfortAudioChain {
    let dynamics: AVAudioUnitEffect
    let limiter: AVAudioUnitEffect

    init() {
        dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    func attach(to engine: AVAudioEngine) {
        engine.attach(dynamics)
        engine.attach(limiter)
    }

    func connect(player: AVAudioPlayerNode, engine: AVAudioEngine,
                 format: AVAudioFormat, enabled: Bool) throws {
        if enabled {
            try engine.connectNode(player, to: dynamics, format: format)
            try engine.connectNode(dynamics, to: limiter, format: format)
            try engine.connectNode(limiter, to: engine.mainMixerNode, format: format)
            try configure()
        } else {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        }
    }

    func disconnect(from engine: AVAudioEngine) {
        engine.disconnectNodeOutput(dynamics)
        engine.disconnectNodeOutput(limiter)
    }

    private func configure() throws {
        // Gentle compression, no gate (quiet details remain), modest make-up gain.
        for (parameter, value): (AudioUnitParameterID, AudioUnitParameterValue) in [
            (kDynamicsProcessorParam_Threshold, -22), (kDynamicsProcessorParam_HeadRoom, 12),
            (kDynamicsProcessorParam_ExpansionRatio, 1), (kDynamicsProcessorParam_ExpansionThreshold, -80),
            (kDynamicsProcessorParam_AttackTime, 0.005), (kDynamicsProcessorParam_ReleaseTime, 0.15),
            (kDynamicsProcessorParam_OverallGain, 4)
        ] {
            try set(dynamics, parameter, value)
        }
        try set(limiter, kLimiterParam_AttackTime, 0.001)
        try set(limiter, kLimiterParam_DecayTime, 0.05)
        try set(limiter, kLimiterParam_PreGain, 0)
    }

    private func set(_ effect: AVAudioUnitEffect, _ parameter: AudioUnitParameterID,
                     _ value: AudioUnitParameterValue) throws {
        let status = effect.withAudioUnit { AudioUnitSetParameter($0, parameter, kAudioUnitScope_Global, 0, value, 0) }
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Comfort sound could not configure a system audio effect."])
        }
    }
}
