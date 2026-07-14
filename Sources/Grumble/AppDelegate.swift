import AppKit
import ApplicationServices
import FluidAudio

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyManager()
    private let dictation = DictationController()

    private var stateItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var modelMenu: NSMenu!
    private lazy var overlay = OverlayController()
    private let hotKeyRecorder = HotKeyRecorder()
    private var currentHotKey = HotKey.load()
    private var lastState: DictationController.State = .idle

    private static let modelChoices: [(StreamingModelVariant, String)] = [
        (.parakeetUnified320ms, "Parakeet Unified — 320 ms (lowest latency)"),
        (.parakeetUnified640ms, "Parakeet Unified — 640 ms (efficient)"),
        (.parakeetUnified1120ms, "Parakeet Unified — 1120 ms (best balance)"),
        (.parakeetUnified2080ms, "Parakeet Unified — 2080 ms (best accuracy)"),
        (.parakeetEou160ms, "Parakeet EOU 120M — 160 ms (fastest, tiny)"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = buildMenu()

        dictation.onStateChange = { [weak self] state in
            self?.updateUI(for: state)
        }
        updateUI(for: .idle)

        hotKey.onHotKey = { [weak self] in
            self?.dictation.toggle()
        }
        hotKey.register(currentHotKey)

        promptForAccessibilityIfNeeded()
        dictation.preload()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

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

        let hotKeyItem = NSMenuItem(
            title: "Change Hotkey\u{2026}", action: #selector(changeHotKey), keyEquivalent: "")
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Grumble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    private func updateUI(for state: DictationController.State) {
        lastState = state
        let symbol: String
        let tint: NSColor?
        switch state {
        case .idle:
            stateItem.title = "Idle"
            toggleItem.title = "Start Dictation  (\(currentHotKey.displayString))"
            toggleItem.isEnabled = true
            symbol = "mic"
            tint = nil
            overlay.hide()
        case .loadingModel:
            stateItem.title = "Loading model\u{2026}"
            toggleItem.isEnabled = false
            symbol = "arrow.down.circle"
            tint = nil
            overlay.hide()
        case .listening:
            stateItem.title = "Listening\u{2026}"
            toggleItem.title = "Stop Dictation  (\(currentHotKey.displayString))"
            toggleItem.isEnabled = true
            symbol = "mic.fill"
            tint = .systemRed
            overlay.show("Listening\u{2026}", color: .systemRed, pulsing: true)
        case .finishing:
            stateItem.title = "Finishing\u{2026}"
            toggleItem.isEnabled = false
            symbol = "mic.fill"
            tint = nil
            overlay.show("Finishing\u{2026}", color: .systemOrange, pulsing: false)
        }
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: "Grumble")
            button.contentTintColor = tint
        }
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
            self.hotKey.register(self.currentHotKey)
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

    private func promptForAccessibilityIfNeeded() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog(
                "Grumble: accessibility access not granted yet; text injection will not work until it is enabled."
            )
        }
    }
}
