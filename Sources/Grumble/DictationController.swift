import AVFoundation
import AppKit
import FluidAudio

@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case loadingModel
        case listening
        case finishing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let audio = AudioCapture()
    private let injector = TextInjector()
    private var manager: (any StreamingAsrManager)?
    private var loadedVariant: StreamingModelVariant?
    private var pumpTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    private static let variantDefaultsKey = "modelVariant"

    var variant: StreamingModelVariant {
        get {
            UserDefaults.standard.string(forKey: Self.variantDefaultsKey)
                .flatMap(StreamingModelVariant.init(rawValue:)) ?? .parakeetUnified1120ms
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.variantDefaultsKey)
        }
    }

    func toggle() {
        switch state {
        case .idle:
            Task { await start() }
        case .listening:
            Task { await stop() }
        case .loadingModel, .finishing:
            break
        }
    }

    /// Download and load the model in the background so the first dictation
    /// doesn't stall on a multi-hundred-megabyte download.
    func preload() {
        Task {
            do {
                _ = try await loadManagerIfNeeded()
            } catch {
                showAlert("Failed to load speech model: \(error.localizedDescription)")
            }
            if state == .loadingModel { state = .idle }
        }
    }

    private func start() async {
        guard state == .idle else { return }

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            showAlert(
                "Grumble needs microphone access. Enable it in System Settings > Privacy & Security > Microphone."
            )
            return
        }

        do {
            let manager = try await loadManagerIfNeeded()
            await manager.setPartialTranscriptCallback { [weak self] text in
                Task { @MainActor in
                    guard let self, self.state == .listening else { return }
                    self.injector.update(to: text)
                }
            }
            try await manager.reset()
            injector.reset()

            let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
            bufferContinuation = continuation
            pumpTask = Task {
                for await buffer in stream {
                    do {
                        try await manager.appendAudio(buffer)
                        try await manager.processBufferedAudio()
                    } catch {
                        NSLog("Grumble: transcription error: \(error)")
                    }
                }
            }
            try audio.start(
                onBuffer: { buffer in
                    continuation.yield(buffer)
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.onLevel?(level) }
                }
            )
            state = .listening
        } catch {
            state = .idle
            showAlert("Failed to start dictation: \(error.localizedDescription)")
        }
    }

    private func stop() async {
        guard state == .listening, let manager else { return }
        state = .finishing
        audio.stop()
        bufferContinuation?.finish()
        bufferContinuation = nil
        await pumpTask?.value
        pumpTask = nil
        do {
            let finalText = try await manager.finish()
            injector.update(to: finalText)
        } catch {
            NSLog("Grumble: finish error: \(error)")
        }
        state = .idle
    }

    private func loadManagerIfNeeded() async throws -> any StreamingAsrManager {
        let wanted = variant
        if let manager, loadedVariant == wanted {
            return manager
        }
        if let old = manager {
            await old.cleanup()
            manager = nil
            loadedVariant = nil
        }
        state = .loadingModel
        do {
            let newManager = wanted.createManager()
            try await newManager.loadModels()
            manager = newManager
            loadedVariant = wanted
            return newManager
        } catch {
            state = .idle
            throw error
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Grumble"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
