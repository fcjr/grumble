import AVFoundation
import Accelerate
import CoreAudio

/// Captures microphone audio from an AUHAL input unit bound to a single
/// device, handing out fresh buffers plus a coarse 0...1 input level per
/// buffer for metering.
///
/// AVAudioEngine is deliberately avoided here: its input path spins up a
/// private aggregate ("CADefaultDeviceAggregate") around the system-default
/// devices, which opens the default microphone even when capture is pinned
/// elsewhere - flipping Bluetooth headphones into the degraded HFP profile
/// while their mic isn't even wanted.
final class AudioCapture {
    /// Frames handed downstream per buffer. AUHAL delivers the device's
    /// native IO slices (typically ~10 ms), but FluidAudio's AudioConverter
    /// resamples every delivered buffer independently (a fresh stateless
    /// converter per call), so each buffer boundary is a filter edge. Slices
    /// are accumulated to the same 4096-frame cadence the old AVAudioEngine
    /// tap produced; per-slice delivery would make those resampling seams
    /// ~8x more frequent and audibly degrade the features the recognizer
    /// sees. Levels still go out per slice, so the meter stays live.
    private static let chunkFrames: AVAudioFrameCount = 4096

    private var unit: AudioUnit?
    private var format: AVAudioFormat?
    private var staging: AVAudioPCMBuffer?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var onConfigurationChange: (() -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws {
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onConfigurationChange = onConfigurationChange

        let pinned = AudioInputDevices.preferredDeviceID()
        guard let device = pinned ?? Self.defaultInputDevice() else {
            throw Self.error("No audio input device available.")
        }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Self.error("Audio input is unavailable.")
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "create audio unit")
        guard let unit = newUnit else { throw Self.error("Audio input is unavailable.") }
        self.unit = unit

        // Input-only: enable the input element, disable the output element,
        // then bind the unit to exactly the wanted device.
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &enable, UInt32(MemoryLayout<UInt32>.size)), "enable input")
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &disable, UInt32(MemoryLayout<UInt32>.size)), "disable output")
        var deviceID = device
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)), "bind device")

        // Capture at the device rate (AUHAL doesn't resample) in standard
        // deinterleaved float32, mirroring what the old engine tap produced.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                &hardware, &size), "read device format")
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
            let format = AVAudioFormat(
                standardFormatWithSampleRate: hardware.mSampleRate,
                channels: min(hardware.mChannelsPerFrame, 2))
        else {
            cleanup()
            throw Self.error("No audio input device available.")
        }
        self.format = format
        var client = format.streamDescription.pointee
        try check(
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "set client format")

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
                Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")

        try check(AudioUnitInitialize(unit), "initialize audio unit")
        do {
            try check(AudioOutputUnitStart(unit), "start capture")
        } catch {
            AudioUnitUninitialize(unit)
            cleanup()
            throw error
        }

        // End the session when the capture device disappears, and - when
        // following the system default - when the default moves, so the next
        // session picks up the new device (same contract as the old
        // AVAudioEngineConfigurationChange handling).
        listen(to: device, selector: kAudioDevicePropertyDeviceIsAlive)
        if pinned == nil {
            listen(
                to: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultInputDevice)
        }
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
        }
        // Render callbacks have stopped; hand the partial chunk downstream so
        // finish() transcribes right up to the moment dictation ended.
        if let chunk = staging, chunk.frameLength > 0 {
            staging = nil
            onBuffer?(chunk)
        }
        cleanup()
    }

    private func render(
        _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
        _ inBusNumber: UInt32,
        _ inNumberFrames: UInt32
    ) -> OSStatus {
        guard let unit, let format,
            let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames)
        else { return noErr }
        slice.frameLength = inNumberFrames
        let status = AudioUnitRender(
            unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
            slice.mutableAudioBufferList)
        guard status == noErr else { return status }
        onLevel?(Self.level(of: slice))
        accumulate(slice)
        return noErr
    }

    /// Copy a rendered slice into the staging chunk, handing full chunks
    /// downstream. Only touched from the render thread (and from stop(),
    /// after the unit has stopped).
    private func accumulate(_ slice: AVAudioPCMBuffer) {
        guard let format, let sliceData = slice.floatChannelData else { return }
        var copied: AVAudioFrameCount = 0
        while copied < slice.frameLength {
            if staging == nil {
                staging = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames)
            }
            guard let chunk = staging, let chunkData = chunk.floatChannelData else { return }
            let count = min(Self.chunkFrames - chunk.frameLength, slice.frameLength - copied)
            for channel in 0..<Int(format.channelCount) {
                memcpy(
                    chunkData[channel] + Int(chunk.frameLength),
                    sliceData[channel] + Int(copied),
                    Int(count) * MemoryLayout<Float>.size)
            }
            chunk.frameLength += count
            copied += count
            if chunk.frameLength == Self.chunkFrames {
                staging = nil
                onBuffer?(chunk)
            }
        }
    }

    private func listen(to id: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onConfigurationChange?()
        }
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
            listeners.append((id, address, block))
        }
    }

    private func cleanup() {
        for (id, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        listeners = []
        if let unit {
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        format = nil
        staging = nil
        onBuffer = nil
        onLevel = nil
        onConfigurationChange = nil
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            cleanup()
            throw Self.error("Audio capture failed (\(what): \(status)).")
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "Grumble", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// RMS level mapped from roughly -50 dB...-6 dB onto 0...1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, .leastNonzeroMagnitude))
        return max(0, min(1, (db + 50) / 44))
    }
}
