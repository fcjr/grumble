import AVFoundation
import AppKit
import Carbon.HIToolbox
import FluidAudio

@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case loadingModel
        case listening
        case finishing
    }

    enum ModelState: Equatable {
        case notLoaded
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    private(set) var modelState: ModelState = .notLoaded {
        didSet { onModelStateChange?(modelState) }
    }
    var onStateChange: ((State) -> Void)?
    var onModelStateChange: ((ModelState) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onPermissionsNeeded: (() -> Void)?
    var onSecureInput: (() -> Void)?

    private let audio = AudioCapture()
    private let injector = TextInjector()
    private var manager: (any StreamingAsrManager)?
    private var loadedVariant: StreamingModelVariant?
    private var loadTask: Task<any StreamingAsrManager, Error>?
    private var pumpTask: Task<Void, Never>?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var focusObserver: NSObjectProtocol?
    private var userInputMonitor: Any?
    private var lastPartialText = ""
    private var settleTask: Task<Void, Never>?
    /// How long the transcript must sit unchanged before the held-back
    /// frontier word is flushed to the screen.
    private static let settleDelay: UInt64 = 1_500_000_000
    /// Prolonged silence ends the session entirely.
    private static let autoStopDelay: UInt64 = 60_000_000_000
    /// Characters of the model transcript that are frozen on screen: the user
    /// typed, pressed a key, or clicked since they were injected, so Grumble
    /// must never backspace across them or re-inject them.
    private var injectionFloor = 0

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
    /// doesn't stall on a multi-hundred-megabyte download. Failure lands in
    /// modelState; retrying is just calling this again.
    func preload() {
        Task {
            _ = try? await loadManagerIfNeeded()
            if state == .loadingModel { state = .idle }
        }
    }

    private func start() async {
        guard state == .idle else { return }

        guard PermissionsController.allGranted() else {
            onPermissionsNeeded?()
            return
        }

        // Password fields turn on secure event input, which silently
        // swallows synthetic keystrokes - say so instead of typing nothing.
        guard !IsSecureEventInputEnabled() else {
            onSecureInput?()
            return
        }

        do {
            let manager = try await loadManagerIfNeeded()
            await manager.setPartialTranscriptCallback { [weak self] text in
                Task { @MainActor in
                    guard let self, self.state == .listening, text != self.lastPartialText
                    else { return }
                    self.lastPartialText = text
                    self.inject(Self.stablePrefix(of: text))
                    self.scheduleSettleFlush()
                }
            }
            try await manager.reset()
            injector.reset()
            injectionFloor = 0
            lastPartialText = ""

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
                },
                onConfigurationChange: { [weak self] in
                    // Input device changed or vanished mid-session; wrap up
                    // with the audio we have.
                    Task { @MainActor in await self?.stop() }
                }
            )
            installFocusObserver()
            installUserInputMonitor()
            state = .listening
        } catch {
            state = .idle
            if case .failed = modelState {
                onPermissionsNeeded?()
            } else {
                showAlert("Failed to start dictation: \(error.localizedDescription)")
            }
        }
    }

    private func stop() async {
        guard state == .listening, let manager else { return }
        state = .finishing
        teardownSession()
        do {
            let finalText = try await manager.finish()
            inject(finalText)
        } catch {
            NSLog("Grumble: finish error: \(error)")
        }
        state = .idle
    }

    /// Inject transcript text, honoring the frozen prefix: only the part of
    /// the transcript past the floor is diffed against the screen.
    private func inject(_ text: String) {
        guard text.count > injectionFloor else { return }
        injector.update(to: String(text.dropFirst(injectionFloor)))
    }

    /// End the session without injecting any more text - used when focus
    /// moves to another app, where the diff would mangle whatever is now
    /// focused. Whatever was already typed stays put.
    private func cancel() async {
        guard state == .listening else { return }
        state = .finishing
        teardownSession()
        try? await manager?.reset()
        injector.reset()
        state = .idle
    }

    private func teardownSession() {
        removeFocusObserver()
        removeUserInputMonitor()
        settleTask?.cancel()
        settleTask = nil
        audio.stop()
        bufferContinuation?.finish()
        bufferContinuation = nil
    }

    /// When the transcript stops changing (speaker paused), flush the
    /// held-back frontier word after a short settle, and end the session
    /// after a minute of continued silence.
    private func scheduleSettleFlush() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleDelay)
            guard let self, !Task.isCancelled, self.state == .listening else { return }
            self.inject(self.lastPartialText)
            try? await Task.sleep(nanoseconds: Self.autoStopDelay - Self.settleDelay)
            guard !Task.isCancelled, self.state == .listening else { return }
            await self.stop()
        }
    }

    /// While listening, watch for the user's own keystrokes and clicks
    /// (Grumble's synthetic events are tagged and ignored). Any real input
    /// means the caret or text may have changed under us - freeze what's on
    /// screen and only ever append from here on.
    private func installUserInputMonitor() {
        userInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.type == .keyDown, TextInjector.isOwnEvent(event) { return }
            Task { @MainActor in self?.userInterjected() }
        }
    }

    private func removeUserInputMonitor() {
        if let userInputMonitor {
            NSEvent.removeMonitor(userInputMonitor)
            self.userInputMonitor = nil
        }
    }

    private func userInterjected() {
        guard state == .listening else { return }
        injectionFloor += injector.typedCount
        injector.reset()
    }

    private func installFocusObserver() {
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                let activated =
                    note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if activated?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    await self.cancel()
                }
            }
        }
    }

    private func removeFocusObserver() {
        if let focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    private func loadManagerIfNeeded() async throws -> any StreamingAsrManager {
        let wanted = variant
        if let manager, loadedVariant == wanted {
            return manager
        }
        if let loadTask {
            return try await loadTask.value
        }
        if let old = manager {
            await old.cleanup()
            manager = nil
            loadedVariant = nil
        }
        state = .loadingModel
        modelState = .loading
        let task = Task { () throws -> any StreamingAsrManager in
            let newManager: any StreamingAsrManager
            if let unifiedConfig = wanted.unifiedConfig {
                // Construct directly so provisional partials can be enabled:
                // words land at buffer cadence and self-correct once the
                // chunk commits with full right context.
                let unified = StreamingUnifiedAsrManager(config: unifiedConfig)
                await unified.setProvisionalPartials(true)
                newManager = unified
            } else {
                newManager = wanted.createManager()
            }
            try await newManager.loadModels()
            return newManager
        }
        loadTask = task
        do {
            let newManager = try await task.value
            loadTask = nil
            manager = newManager
            loadedVariant = wanted
            modelState = .loaded
            return newManager
        } catch {
            loadTask = nil
            modelState = .failed(error.localizedDescription)
            if state == .loadingModel { state = .idle }
            throw error
        }
    }

    /// Hold back the trailing in-progress word while listening: the frontier
    /// of the transcript is decoded with the least context and thrashes the
    /// most, so typing it live reads as jumpy. Revisions to earlier words
    /// still stream through; the held word lands on the next partial or at
    /// finish().
    private static func stablePrefix(of text: String) -> String {
        guard let lastSpace = text.lastIndex(of: " ") else { return "" }
        return String(text[..<text.index(after: lastSpace)])
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Grumble"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
