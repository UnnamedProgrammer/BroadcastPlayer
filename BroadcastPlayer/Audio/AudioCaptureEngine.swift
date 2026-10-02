import AVFoundation
import CoreMedia
import CoreAudio
import Foundation
import OSLog
import QuartzCore

nonisolated struct AudioCaptureSnapshot: Sendable {
    var sourceName = ""
    var sampleRate = 0.0
    var channels: UInt32 = 0
    var bits: UInt32 = 0
    var sourceBits: UInt32 = 0
    var isFloat = false
    var isPCM = false
    var receivedBuffers = 0
    var playedBuffers = 0
    var playbackResets = 0
    var outputName = "System output"
    var outputSampleRate = 0.0
    var outputLatencyMilliseconds = 0.0
    var routeChanges = 0
    var peak: Float = 0
    var lastSampleTime = 0.0
    var error: String?

    var isReceiving: Bool {
        lastSampleTime > 0 && CACurrentMediaTime() - lastSampleTime < 1
    }
}

// Capture the card’s native signed PCM explicitly. AVAudioEngine handles the
// speaker clock; a bounded startup buffer absorbs USB callback jitter.
nonisolated final class AudioCaptureEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.broadcastplayer.audio", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let playback = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let comfort = ComfortAudioChain()
    private var isComfortEnabled = false
    private var decoder = AudioPCMDecoder()
    private var playbackFormat: AVAudioFormat?
    private let renderQueue = AudioRenderQueue()
    private var volume: Float = 1
    private var testingToneUntil = 0.0
    private var toneEpoch: UInt64 = 0
    private var routeObserver: NSObjectProtocol?
    private var routeEpoch: UInt64 = 0
    private var isChangingRoute = false
    private let dataOutput = AVCaptureAudioDataOutput()
    private let lock = NSLock()
    private var state = AudioCaptureSnapshot()

    override init() {
        super.init()
        playback.attach(player)
        comfort.attach(to: playback)
        routeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: playback, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [self] in
                // Route changes can arrive in a burst while CoreAudio renegotiates.
                routeEpoch &+= 1
                let epoch = routeEpoch
                isChangingRoute = true
                resetPlayback()
                lock.lock()
                state.routeChanges += 1
                lock.unlock()
                queue.asyncAfter(deadline: .now() + 0.1) { [self] in
                    guard routeEpoch == epoch else { return }
                    isChangingRoute = false
                }
            }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    func start(deviceID: String, volume: Float) {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            resetPlayback()
            decoder = AudioPCMDecoder()
            testingToneUntil = 0
            toneEpoch &+= 1
            self.volume = min(max(volume, 0), 1)
            guard let device = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
            ).devices.first(where: { $0.uniqueID == deviceID }) else {
                lock.lock()
                state = AudioCaptureSnapshot(error: "The selected audio input disconnected.")
                lock.unlock()
                return
            }
            let native = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
            let sourceBits = native?.mBitsPerChannel ?? 0
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            var failure: String?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    throw NSError(domain: "AudioCapture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot open audio input \(device.localizedName)."])
                }
                session.addInput(input)
                guard session.canAddOutput(dataOutput) else {
                    throw NSError(domain: "AudioCapture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Audio playback is unavailable for this input."])
                }
                // Match the external card's integer PCM; avoid negotiation with
                // a second preview output that can change its stream format.
                dataOutput.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: native?.mSampleRate ?? 48000,
                    AVNumberOfChannelsKey: native?.mChannelsPerFrame ?? 2,
                    AVLinearPCMBitDepthKey: [16, 24, 32].contains(sourceBits) ? sourceBits : 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                session.addOutput(dataOutput)
                dataOutput.setSampleBufferDelegate(self, queue: queue)
            } catch {
                failure = error.localizedDescription
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
            }
            session.commitConfiguration()
            lock.lock()
            state = AudioCaptureSnapshot(sourceName: device.localizedName, sourceBits: sourceBits, error: failure)
            lock.unlock()
            if let failure {
                Log.audio.error("Audio setup failed: \(failure, privacy: .public)")
                return
            }
            session.startRunning()
            if !session.isRunning {
                lock.lock()
                state.error = "Audio capture did not start. Check input access and the capture device."
                lock.unlock()
            }
            Log.audio.info("PCM audio playback started: \(device.localizedName, privacy: .public)")
        }
    }

    func setVolume(_ volume: Float) {
        queue.async { [self] in
            self.volume = min(max(volume, 0), 1)
            player.volume = self.volume
        }
    }

    func setComfort(_ enabled: Bool) {
        queue.async { [self] in
            guard isComfortEnabled != enabled else { return }
            isComfortEnabled = enabled
            resetPlayback()
        }
    }

    func stop() {
        queue.async { [self] in
            player.volume = 0
            testingToneUntil = 0
            toneEpoch &+= 1
            resetPlayback()
            if session.isRunning { session.stopRunning() }
            lock.lock()
            state = AudioCaptureSnapshot()
            lock.unlock()
        }
    }

    // A quiet, faded sine tone bypasses HDMI capture but uses this same player
    // and system output. It distinguishes source noise from speaker playback.
    func testSpeakers() {
        queue.async { [self] in
            toneEpoch &+= 1
            let epoch = toneEpoch
            testingToneUntil = CACurrentMediaTime() + 1.2
            resetPlayback()
            do {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                buffer.frameLength = 48000
                let channels = buffer.floatChannelData!
                for i in 0..<48000 {
                    let fade = min(1.0, min(Double(i), Double(47999 - i)) / 960.0)
                    let sample = Float(sin(2 * Double.pi * 440 * Double(i) / 48000) * 0.08 * fade)
                    channels[0][i] = sample
                    channels[1][i] = sample
                }
                try comfort.connect(player: player, engine: playback, format: format, enabled: isComfortEnabled)
                playbackFormat = format
                playback.prepare()
                try playback.start()
                player.volume = 1 // The generated signal itself is quiet (-22 dB peak).
                player.scheduleBuffer(buffer)
                try player.playAudio()
                queue.asyncAfter(deadline: .now() + 1.2) { [self] in
                    guard epoch == toneEpoch else { return }
                    testingToneUntil = 0
                    resetPlayback()
                }
            } catch {
                testingToneUntil = 0
                resetPlayback()
                lock.lock()
                state.error = "Speaker test failed: \(error.localizedDescription)"
                lock.unlock()
            }
        }
    }

    func snapshot() -> AudioCaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isChangingRoute, CACurrentMediaTime() >= testingToneUntil, session.isRunning, CMSampleBufferDataIsReady(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }
        let asbd = description.pointee
        let pcm: AVAudioPCMBuffer
        do {
            pcm = try decoder.decode(sampleBuffer)
            try enqueue(pcm)
        } catch {
            resetPlayback()
            lock.lock()
            state.error = error.localizedDescription
            lock.unlock()
            return
        }
        var peak: Float = 0
        if let channels = pcm.floatChannelData {
            for channel in 0..<Int(pcm.format.channelCount) {
                for index in 0..<Int(pcm.frameLength) { peak = max(peak, abs(channels[channel][index])) }
            }
        }
        lock.lock()
        state.peak = peak
        state.error = nil
        let first = state.receivedBuffers == 0
        state.sampleRate = asbd.mSampleRate
        state.channels = asbd.mChannelsPerFrame
        state.bits = asbd.mBitsPerChannel
        state.isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        state.isPCM = asbd.mFormatID == kAudioFormatLinearPCM
        state.receivedBuffers += 1
        state.lastSampleTime = CACurrentMediaTime()
        lock.unlock()
        if first {
            Log.audio.info("Receiving audio: \(asbd.mSampleRate) Hz, \(asbd.mChannelsPerFrame) channels, \(asbd.mBitsPerChannel) bits")
        }
    }

    private func resetPlayback() {
        renderQueue.reset()
        player.stop()
        playback.stop()
        playback.disconnectNodeOutput(player)
        comfort.disconnect(from: playback)
        playbackFormat = nil
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) throws {
        if playbackFormat != buffer.format || !playback.isRunning {
            resetPlayback()
            try comfort.connect(player: player, engine: playback, format: buffer.format, enabled: isComfortEnabled)
            playbackFormat = buffer.format
            playback.prepare()
            try playback.start()
            player.volume = volume
            lock.lock()
            state.outputSampleRate = playback.outputNode.outputFormat(forBus: 0).sampleRate
            state.outputLatencyMilliseconds = playback.outputNode.outputPresentationLatency * 1000
            state.outputName = Self.systemOutputName()
            lock.unlock()
        }
        let rate = buffer.format.sampleRate
        // Bound only samples awaiting render. Bluetooth presentation latency is
        // downstream and must not be counted as a stalled source queue.
        let count = Int(buffer.frameLength)
        let reservation = renderQueue.reserve(count, limit: Int(rate * 0.15))
        if reservation.overflow {
            player.stop()
            lock.lock()
            state.playbackResets += 1
            lock.unlock()
        }
        let epoch = reservation.epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
            guard let self else { return }
            guard self.renderQueue.complete(count, epoch: epoch) else { return }
            self.queue.async { [self] in
                guard self.renderQueue.isCurrent(epoch) else { return }
                self.lock.lock()
                self.state.playedBuffers += 1
                self.lock.unlock()
                // Do not stop when the last buffer renders: it may still be
                // traveling to Bluetooth headphones. Keep the player clock
                // running so the next capture buffer can follow continuously.
            }
        }
        // Start with 40 ms of queued samples; mute does not stop the audio clock.
        if !player.isPlaying && reservation.frames >= Int(rate * 0.04) { try player.playAudio() }
    }

    private static func systemOutputName() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &device) == noErr else { return "System output" }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return "System output" }
        return name.takeRetainedValue() as String
    }

}
