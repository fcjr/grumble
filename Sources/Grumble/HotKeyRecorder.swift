import AppKit
import Carbon.HIToolbox

/// A small window that captures the next key combination pressed and returns
/// it as a HotKey. Esc (or clicking away) cancels.
@MainActor
final class HotKeyRecorder {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var completion: ((HotKey?) -> Void)?

    var isRecording: Bool { window != nil }

    func begin(completion: @escaping (HotKey?) -> Void) {
        guard window == nil else { return }
        self.completion = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Grumble"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .grumbleFaceplate
        window.isMovableByWindowBackground = true

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = .grumblePanelLabel(
            "Press the new hotkey", size: 15, color: .grumbleAmber)
        title.alignment = .center
        let hint = NSTextField(
            labelWithString: "Must include \u{2318}, \u{2303}, or \u{2325} \u{2014} Esc to cancel")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .grumbleBoneDim
        hint.alignment = .center

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finish(nil) }
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = HotKey.carbonModifiers(from: event.modifierFlags)
        if Int(event.keyCode) == kVK_Escape && modifiers == 0 {
            finish(nil)
            return
        }
        // Require a real chording modifier so plain typing keys can't be bound.
        let required = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
        guard modifiers & required != 0 else {
            NSSound.beep()
            return
        }
        finish(HotKey(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers))
    }

    private func finish(_ hotKey: HotKey?) {
        guard let window else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        self.window = nil
        window.close()
        let completion = self.completion
        self.completion = nil
        completion?(hotKey)
    }
}
