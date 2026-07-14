import AVFoundation

/// Captures microphone audio with AVAudioEngine and hands out deep-copied
/// buffers (tap buffers are reused by the engine after the callback returns).
final class AudioCapture {
    private let engine = AVAudioEngine()

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
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
        }
        engine.prepare()
        try engine.start()
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
