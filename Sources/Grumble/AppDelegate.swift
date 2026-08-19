import AppKit
import ApplicationServices
import FluidAudio
import ServiceManagement

#if !APPSTORE
    import Sparkle
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private let dictation = DictationController()
    private let meetings = MeetingsController()
    private lazy var meetingsWindow = MeetingsWindowController(controller: meetings)

    private var stateItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var meetingStateItem: NSMenuItem!
    private var meetingToggleItem: NSMenuItem!
    private var meetingDiscardItem: NSMenuItem!
    private var autoRecordItem: NSMenuItem!
    private var meetingTimer: Timer?
    private var iconTimer: Timer?
    private var iconPhase: CGFloat = 0
    private var loginItem: NSMenuItem!
    private var modelMenu: NSMenu!
    private var micMenu: NSMenu!
    private lazy var overlay = OverlayController()
    private let permissions = PermissionsController()
    private let about = AboutController()
    private let hotKeyRecorder = HotKeyRecorder()
    #if !APPSTORE
        // Sparkle can't replace a bundle in the read-only Nix store (and nix-darwin
        // copies into "Nix Apps" get overwritten on the next rebuild), so Nix owns
        // updates there - never start the updater or schedule checks.
        private static let isNixInstall: Bool = {
            let resolved = (Bundle.main.bundlePath as NSString).resolvingSymlinksInPath
            return resolved.hasPrefix("/nix/store") || resolved.contains("/Nix Apps/")
        }()
        private let updaterController: SPUStandardUpdaterController? =
            isNixInstall
            ? nil
            : SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    private var currentHotKey = HotKey.load()
    private var lastState: DictationController.State = .idle

    private static let modelChoices: [(StreamingModelVariant, String)] = [
        (.parakeetUnified320ms, "Parakeet Unified — 320 ms (lowest latency)"),
        (.parakeetUnified640ms, "Parakeet Unified — 640 ms (efficient)"),
        (.parakeetUnified1120ms, "Parakeet Unified — 1120 ms (best balance)"),
        (.parakeetUnified2080ms, "Parakeet Unified — 2080 ms (best accuracy)"),
        (.parakeetEou160ms, "Parakeet EOU 120M — 160 ms (fastest, tiny)"),
    ]

    private var hotKeyRegistered = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Utility mode for scripted checks of the system-audio TCC grant
        // (also used to verify the sandboxed build can create process taps).
        if CommandLine.arguments.contains("--probe-system-audio") {
            let granted = SystemTrackRecorder.probeAccess()
            print("system-audio-probe: \(granted ? "granted" : "denied")")
            exit(granted ? 0 : 1)
        }

        // Utility mode: record a short live meeting session (both tracks),
        // run it through the full pipeline, and print the result. Exercises
        // capture and processing without any UI.
        if let idx = CommandLine.arguments.firstIndex(of: "--record-test"),
            let seconds = CommandLine.arguments.indices.contains(idx + 1)
                ? Int(CommandLine.arguments[idx + 1]) : nil
        {
            Task { @MainActor in
                do {
                    let session = try MeetingSession(sourceBundleID: nil)
                    try session.start()
                    print("record-test: capturing \(seconds)s into \(session.dir.path)")
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                    session.stop()
                    let store = try MeetingStore()
                    let pipeline = MeetingPipeline(store: store)
                    await pipeline.enqueue(audioDir: session.dir.lastPathComponent)
                    while (try? store.meeting(audioDir: session.dir.lastPathComponent))??
                        .state != .done
                    {
                        if let m = try? store.meeting(audioDir: session.dir.lastPathComponent),
                            m.state == .failed
                        {
                            print("record-test: FAILED \(m.errorMessage ?? "")")
                            exit(1)
                        }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    if let meeting = try store.meeting(audioDir: session.dir.lastPathComponent),
                        let id = meeting.id
                    {
                        for segment in try store.segments(meetingId: id) {
                            let speakers = try store.speakers(meetingId: id)
                            let slot =
                                speakers.first { $0.id == segment.speakerId }?.slot ?? "?"
                            print("record-test: [\(slot)] \(segment.text)")
                        }
                    }
                    print("record-test: done")
                    exit(0)
                } catch {
                    print("record-test: error \(error)")
                    exit(1)
                }
            }
            return
        }

        // Utility mode: run the summarizer over an existing meeting and
        // print the result (downloads the model on first use).
        if let idx = CommandLine.arguments.firstIndex(of: "--summarize-meeting"),
            let meetingId = CommandLine.arguments.indices.contains(idx + 1)
                ? Int64(CommandLine.arguments[idx + 1]) : nil
        {
            Task { @MainActor in
                do {
                    let store = try MeetingStore()
                    let pipeline = MeetingPipeline(store: store)
                    let manager = SummarizerManager.shared
                    manager.onReady = { summarizer in
                        Task {
                            await pipeline.setSummarizer(summarizer)
                            await pipeline.summarize(meetingId: meetingId)
                            if let meeting = try? store.meeting(id: meetingId) {
                                print("title: \(meeting.title ?? "-")")
                                print("summary: \(meeting.summary ?? "-")")
                            }
                            for speaker in (try? store.speakers(meetingId: meetingId)) ?? [] {
                                print(
                                    "speaker \(speaker.slot): \(speaker.displayName ?? "-") (\(speaker.namedBy ?? "-"))"
                                )
                            }
                            exit(0)
                        }
                    }
                    manager.install()
                    while true {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        if case .downloading(let f) = manager.state {
                            print(String(format: "model download: %.0f%%", f * 100))
                        }
                        if case .failed(let message) = manager.state {
                            print("summarize: FAILED \(message)")
                            exit(1)
                        }
                    }
                } catch {
                    print("summarize: error \(error)")
                    exit(1)
                }
            }
            return
        }

        // A DMG install and a dev build would otherwise both grab the hotkey
        // and both type into the focused field.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.leftshift.grumble"
        ).filter { $0.processIdentifier != ownPID }
        if !others.isEmpty {
            NSLog("Grumble: another instance is already running; quitting this one.")
            NSApp.terminate(nil)
            return
        }

        // In-process icon lookups (Sparkle dialogs, NSAlert) resolve to the
        // generic placeholder on macOS 26 even though LaunchServices has the
        // real icon - pin it explicitly.
        NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = buildMenu()

        dictation.onStateChange = { [weak self] state in
            self?.updateUI(for: state)
        }
        dictation.onLevel = { [weak self] level in
            self?.overlay.setLevel(level)
        }
        updateUI(for: .idle)

        hotKey.onHotKey = { [weak self] in
            self?.dictation.toggle()
        }
        hotKeyRegistered = hotKey.register(currentHotKey)

        dictation.onPermissionsNeeded = { [weak self] in
            self?.permissions.show()
        }
        permissions.hotKeyDisplay = { [weak self] in
            self?.currentHotKey.displayString ?? ""
        }
        permissions.onChangeHotKey = { [weak self] in
            self?.changeHotKey()
        }
        permissions.hotKeyConflict = { [weak self] in
            !(self?.hotKeyRegistered ?? true)
        }
        permissions.modelState = { [weak self] in
            self?.dictation.modelState ?? .notLoaded
        }
        permissions.onRetryModel = { [weak self] in
            self?.dictation.preload()
        }
        dictation.onModelStateChange = { [weak self] modelState in
            if case .failed = modelState {
                self?.permissions.show()
            }
        }
        dictation.onSecureInput = { [weak self] in
            self?.overlay.flash(
                "Secure field \u{2014} dictation unavailable", color: .grumbleNeedle)
        }

        meetings.onStateChange = { [weak self] _ in
            self?.refreshMeetingUI()
        }
        meetings.onActivity = {
            NotificationCenter.default.post(name: .grumbleMeetingsChanged, object: nil)
        }

        // Launch at login defaults to on; register once so turning it off
        // later sticks.
        let defaultedKey = "didDefaultLaunchAtLogin"
        if !UserDefaults.standard.bool(forKey: defaultedKey) {
            UserDefaults.standard.set(true, forKey: defaultedKey)
            try? SMAppService.mainApp.register()
        }

        if CommandLine.arguments.contains("--setup") || !hotKeyRegistered {
            permissions.show()
        } else {
            permissions.showIfNeeded()
        }
        if CommandLine.arguments.contains("--about") {
            about.show()
        }
        #if !APPSTORE
            if CommandLine.arguments.contains("--check-updates"), updaterController != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.updaterController?.checkForUpdates(nil)
                }
            }
        #endif
        dictation.preload()
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        autoRecordItem.state = MeetingDetector.isEnabled ? .on : .off
        rebuildMicMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        stateItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        toggleItem = NSMenuItem(
            title: "Start Dictation  (\(currentHotKey.displayString))",
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        meetingStateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        meetingStateItem.isEnabled = false
        meetingStateItem.isHidden = true
        menu.addItem(meetingStateItem)

        meetingToggleItem = NSMenuItem(
            title: "Record Meeting", action: #selector(toggleMeetingRecording), keyEquivalent: "")
        meetingToggleItem.target = self
        menu.addItem(meetingToggleItem)

        meetingDiscardItem = NSMenuItem(
            title: "Discard Recording", action: #selector(discardMeetingRecording),
            keyEquivalent: "")
        meetingDiscardItem.target = self
        meetingDiscardItem.isHidden = true
        menu.addItem(meetingDiscardItem)

        let meetingsItem = NSMenuItem(
            title: "Meetings\u{2026}", action: #selector(openMeetings), keyEquivalent: "")
        meetingsItem.target = self
        menu.addItem(meetingsItem)

        autoRecordItem = NSMenuItem(
            title: "Auto-Record Meetings", action: #selector(toggleAutoRecord), keyEquivalent: "")
        autoRecordItem.target = self
        menu.addItem(autoRecordItem)

        menu.addItem(.separator())

        modelMenu = NSMenu()
        for (variant, title) in Self.modelChoices {
            let item = NSMenuItem(title: title, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = variant.rawValue
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        menu.setSubmenu(modelMenu, for: modelItem)
        menu.addItem(modelItem)
        refreshModelCheckmarks()

        micMenu = NSMenu()
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.toolTip = "Takes effect from the next dictation or recording."
        menu.setSubmenu(micMenu, for: micItem)
        menu.addItem(micItem)
        rebuildMicMenu()

        let hotKeyItem = NSMenuItem(
            title: "Change Hotkey\u{2026}", action: #selector(changeHotKey), keyEquivalent: "")
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)

        loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let setupItem = NSMenuItem(
            title: "Setup\u{2026}", action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        // App Store builds have no updater UI - the store handles updates.
        #if !APPSTORE
            if let updaterController {
                let updateItem = NSMenuItem(
                    title: "Check for Updates\u{2026}",
                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                    keyEquivalent: "")
                updateItem.target = updaterController
                menu.addItem(updateItem)
            } else {
                let updateItem = NSMenuItem(
                    title: "Updates Managed by Nix", action: nil, keyEquivalent: "")
                updateItem.isEnabled = false
                menu.addItem(updateItem)
            }
        #endif

        let aboutItem = NSMenuItem(
            title: "About Grumble", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Grumble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    private func updateUI(for state: DictationController.State) {
        lastState = state
        let tint: NSColor?
        switch state {
        case .idle:
            stateItem.title = "Idle"
            toggleItem.title = "Start Dictation  (\(currentHotKey.displayString))"
            toggleItem.isEnabled = true
            tint = nil
            overlay.hide()
        case .loadingModel:
            stateItem.title = "Loading model\u{2026}"
            toggleItem.isEnabled = false
            tint = .tertiaryLabelColor
            overlay.hide()
        case .listening:
            stateItem.title = "Listening\u{2026}"
            toggleItem.title = "Stop Dictation  (\(currentHotKey.displayString))"
            toggleItem.isEnabled = true
            tint = .grumbleAmber
            overlay.show("Listening", color: .grumbleNeedle, pulsing: true)
        case .finishing:
            stateItem.title = "Finishing\u{2026}"
            toggleItem.isEnabled = false
            tint = .tertiaryLabelColor
            overlay.show("Finishing", color: .grumbleAmber, pulsing: false)
        }
        if let button = statusItem.button {
            // While a meeting records (and dictation isn't coloring the
            // mark), the waveform ripples in amber - motion plus a bright
            // tint, because a recording must never be invisible and the
            // static needle-red read as near-black at menu bar size.
            let recordingIndicator = tint == nil && meetings.isRecording
            if recordingIndicator {
                startIconAnimation()
            } else {
                stopIconAnimation()
                button.image = .grumbleMenuBarMark
                button.contentTintColor = tint
            }
        }
    }

    private func startIconAnimation() {
        guard iconTimer == nil else { return }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { return }
                self.iconPhase += 0.3
                button.image = .grumbleMenuBarMark(phase: self.iconPhase)
                // Gentle brightness pulse on top of the ripple, slower than
                // the wave so it reads as breathing, not blinking.
                let pulse = 0.75 + 0.25 * sin(self.iconPhase * 0.5)
                button.contentTintColor = .grumbleAmber.withAlphaComponent(pulse)
            }
        }
    }

    private func stopIconAnimation() {
        iconTimer?.invalidate()
        iconTimer = nil
        iconPhase = 0
    }

    private func refreshMeetingUI() {
        switch meetings.state {
        case .idle:
            meetingTimer?.invalidate()
            meetingTimer = nil
            meetingStateItem.isHidden = true
            meetingDiscardItem.isHidden = true
            meetingToggleItem.title = "Record Meeting"
        case .recording(let startedAt, let sourceBundleID):
            meetingStateItem.isHidden = false
            meetingDiscardItem.isHidden = false
            meetingToggleItem.title = "Stop Recording"
            let source = sourceBundleID.map(MeetingsController.appName(for:))
            let updateElapsed = { [weak self] in
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                let stamp = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
                self.meetingStateItem.title =
                    source.map { "Recording \($0)  \(stamp)" } ?? "Recording Meeting  \(stamp)"
            }
            updateElapsed()
            meetingTimer?.invalidate()
            meetingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in updateElapsed() }
            }
        }
        updateUI(for: lastState)
    }

    /// Rebuilt on every menu open: devices come and go. The choice is stored
    /// by UID and applies from the next dictation session; if the chosen
    /// device is unplugged, it stays listed (dimmed) and capture falls back
    /// to the system default until it returns.
    private func rebuildMicMenu() {
        micMenu.removeAllItems()
        let preferred = AudioInputDevices.preferred

        let defaultItem = NSMenuItem(
            title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = preferred == nil ? .on : .off
        micMenu.addItem(defaultItem)
        micMenu.addItem(.separator())

        var sawPreferred = false
        for device in AudioInputDevices.available() {
            let item = NSMenuItem(
                title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            if device.uid == preferred?.uid {
                item.state = .on
                sawPreferred = true
            }
            micMenu.addItem(item)
        }
        if let preferred, !sawPreferred {
            // action: nil leaves it disabled under autoenablesItems.
            let item = NSMenuItem(
                title: "\(preferred.name) (not connected)", action: nil, keyEquivalent: "")
            item.state = .on
            micMenu.addItem(item)
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        AudioInputDevices.preferred = sender.representedObject as? AudioInputDevices.Device
        rebuildMicMenu()
    }

    private func refreshModelCheckmarks() {
        let current = dictation.variant.rawValue
        for item in modelMenu.items {
            item.state = (item.representedObject as? String == current) ? .on : .off
        }
    }

    @objc private func toggleDictation() {
        dictation.toggle()
    }

    @objc private func toggleMeetingRecording() {
        meetings.toggleRecording()
    }

    @objc private func discardMeetingRecording() {
        meetings.discardRecording()
    }

    @objc private func openMeetings() {
        meetingsWindow.show()
    }

    @objc private func toggleAutoRecord() {
        MeetingDetector.isEnabled.toggle()
    }

    @objc private func openSetup() {
        permissions.show()
    }

    @objc private func openAbout() {
        about.show()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Grumble: failed to toggle launch at login: \(error)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func changeHotKey() {
        guard !hotKeyRecorder.isRecording else { return }
        // Unregister while recording so pressing the current combo is captured
        // by the recorder instead of toggling dictation.
        hotKey.unregister()
        hotKeyRecorder.begin { [weak self] newHotKey in
            guard let self else { return }
            if let newHotKey {
                self.currentHotKey = newHotKey
                newHotKey.save()
            }
            self.hotKeyRegistered = self.hotKey.register(self.currentHotKey)
            self.updateUI(for: self.lastState)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let variant = StreamingModelVariant(rawValue: raw)
        else { return }
        dictation.variant = variant
        refreshModelCheckmarks()
        dictation.preload()
    }

}
