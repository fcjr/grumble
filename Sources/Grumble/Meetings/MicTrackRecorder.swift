import AVFoundation
import CoreAudio

/// Records the chosen input device - the menu's Microphone selection, or the
/// system default - to an AAC-in-CAF file for a meeting session. Runs its own
/// AVAudioEngine so it never touches the dictation capture path.
///
/// Voice processing is enabled by default so Apple's echo canceller subtracts
/// speaker playback from the mic - without it, a meeting played through
/// speakers bleeds every remote voice into the "me" track and ruins the
/// two-track diarization. VoiceProcessingIO is a duplex unit: it needs a
/// rendered output path and one explicit mono client format on both sides or
/// it silently delivers zeroed buffers, so the first second of audio is
/// checked for liveness and capture restarts raw if it is digital silence.
final class MicTrackRecorder {
    enum RecorderError: Error, LocalizedError {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let e): return "Mic capture failed to start: \(e.localizedDescription)"
            case .fileCreationFailed(let e): return "Mic track file creation failed: \(e.localizedDescription)"
            case .formatUnsupported: return "The input device format can't be recorded."
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer - the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    /// Coarse 0...1 mic level per buffer, for the recording indicator.
    var onLevel: ((Float) -> Void)?

    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        try attach(voiceProcessing: true)
        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
    }

    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The voice unit makes macOS treat the session like a call
                // and duck other audio - the meeting playing through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                NSLog("Grumble: mic voice processing unavailable (\(error)); recording raw")
                voice = false
            }
        }
        pinPreferredDevice(input)

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.formatUnsupported
        }

        // One explicit mono client format. With voice processing this is the
        // boundary format on both sides of the duplex unit - inheriting a
        // multichannel route format yields digital silence. Raw capture
        // downmixes to the same shape; speech models want mono anyway.
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
        else { throw RecorderError.formatUnsupported }

        do {
            file = try AVAudioFile(
                forWriting: url!,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: monoFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                ],
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output or the input side never produces audio. The mixer has no
            // sources - the connection exists solely as a formatted output
            // path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }
    }

    /// Point the input node at the microphone chosen in the menu. Pinning has
    /// to happen after setVoiceProcessingEnabled, which swaps the node's audio
    /// unit out from under us. Unlike dictation this path can't avoid
    /// AVAudioEngine - it needs the duplex echo canceller - so the private
    /// default-device aggregate is still opened alongside; the choice only
    /// decides which device is recorded.
    private func pinPreferredDevice(_ input: AVAudioInputNode) {
        guard var device = AudioInputDevices.preferredDeviceID(), let unit = input.audioUnit
        else { return }
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("Grumble: could not pin mic track to the chosen device (\(status))")
        }
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. An unsupported
    /// route delivers callbacks full of digital zeros; the only recovery is
    /// restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }

            var peak: Float = 0
            let frames = Int(buffer.frameLength)
            if let data = buffer.floatChannelData?[0] {
                for i in 0..<frames { peak = max(peak, abs(data[i])) }
            }
            self.onLevel?(min(1, peak * 3))

            if !self.livenessSettled {
                self.livenessPeak = max(self.livenessPeak, peak)
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                NSLog("Grumble: mic track write failed: \(error)")
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard
                let mono = AVAudioPCMBuffer(
                    pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity)
            else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                var peak: Float = 0
                if let data = mono.floatChannelData?[0] {
                    for i in 0..<Int(mono.frameLength) { peak = max(peak, abs(data[i])) }
                }
                self.onLevel?(min(1, peak * 3))
                try file.write(from: mono)
            } catch {
                NSLog("Grumble: mic track write failed: \(error)")
            }
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        NSLog("Grumble: voice processing delivered silence; restarting mic raw")
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        firstBufferAt = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        do {
            try attach(voiceProcessing: false)
        } catch {
            NSLog("Grumble: mic raw fallback failed: \(error); session continues without mic track")
            file = nil
        }
    }
}
