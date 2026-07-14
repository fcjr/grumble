import AVFoundation
import Accelerate

/// Captures microphone audio with AVAudioEngine and hands out deep-copied
/// buffers (tap buffers are reused by the engine after the callback returns),
/// plus a coarse 0...1 input level per buffer for metering.
final class AudioCapture {
    private let engine = AVAudioEngine()

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping (Float) -> Void
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Grumble", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No audio input device available."]
            )
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let copy = buffer.deepCopy() {
                onBuffer(copy)
            }
            onLevel(Self.level(of: buffer))
        }
        engine.prepare()
        try engine.start()
    }

    /// RMS level mapped from roughly -50 dB...-6 dB onto 0...1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, .leastNonzeroMagnitude))
        return max(0, min(1, (db + 50) / 44))
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            if let sData = s.mData, let dData = d.mData {
                memcpy(dData, sData, Int(s.mDataByteSize))
            }
        }
        return copy
    }
}
