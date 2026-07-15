import AVFoundation
import AppKit
import ApplicationServices

/// Setup window shown while Grumble is missing permissions. Walks through
/// Microphone and Accessibility with buttons that open the exact System
/// Settings pane, and polls until both are granted. Floats above other apps,
/// but drops below System Settings whenever that is the active app so the
/// user can actually reach the toggles.
@MainActor
final class PermissionsController {
    static func allGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
    }

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var micRow: PermissionRow!
    private var axRow: PermissionRow!

    func showIfNeeded() {
        if !Self.allGranted() { show() }
    }

    func show() {
        if let window {
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 0),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Grumble Setup"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .grumbleFaceplate
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let heading = NSTextField(labelWithString: "")
        heading.attributedStringValue = .grumblePanelLabel(
            "Grumble needs two permissions", size: 16, color: .grumbleAmber)

        let blurb = NSTextField(
            wrappingLabelWithString:
                "Grumble listens on the hotkey and types what you say into the app you're using. macOS asks you to allow both explicitly."
        )
        blurb.font = .systemFont(ofSize: 12)
        blurb.textColor = .grumbleBoneDim
        blurb.preferredMaxLayoutWidth = 414

        micRow = PermissionRow(
            title: "Microphone",
            detail: "So Grumble can hear you dictate."
        ) { [weak self] in self?.micAction() }

        axRow = PermissionRow(
            title: "Accessibility",
            detail: "So Grumble can type into other apps. Not listed? Add it with +."
        ) { [weak self] in self?.axAction() }

        let footer = NSTextField(
            labelWithString: "This window closes itself once both are on.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .grumbleBoneDim

        let stack = NSStackView(views: [heading, blurb, micRow, axRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(10, after: heading)
        stack.setCustomSpacing(20, after: blurb)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            micRow.widthAnchor.constraint(equalToConstant: 414),
            axRow.widthAnchor.constraint(equalTo: micRow.widthAnchor),
        ])

        self.window = window
        refresh()
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // Stay on top of everything except System Settings: drop to normal
        // level while System Settings is the active app so its window can
        // cover ours, then float again when the user comes back.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, let window = self.window else { return }
                let activated =
                    (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                if activated == "com.apple.systempreferences" {
                    window.level = .normal
                } else {
                    window.level = .floating
                    window.orderFrontRegardless()
                }
            }
        }
    }

    private func refresh() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micRow.update(
            granted: micStatus == .authorized,
            buttonTitle: micStatus == .notDetermined ? "Allow\u{2026}" : "Open Settings\u{2026}"
        )
        axRow.update(granted: AXIsProcessTrusted(), buttonTitle: "Open Settings\u{2026}")

        if Self.allGranted() {
            pollTimer?.invalidate()
            pollTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.close()
            }
        }
    }

    private func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        window?.close()
        window = nil
    }

    private func micAction() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        default:
            openSettings(
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func axAction() {
        openSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// x-apple.systempreferences: won't re-navigate if System Settings is
    /// already open, so quit it first and reopen at the right pane.
    private func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences")
        if running.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        running.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One permission line: status dot, name, one-line reason, action button.
@MainActor
final class PermissionRow: NSView {
    private let dot = NSView()
    private let button = NSButton(title: "", target: nil, action: nil)
    private let action: () -> Void

    init(title: String, detail: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "")
        titleLabel.attributedStringValue = .grumblePanelLabel(
            title, size: 13, color: .grumbleBone)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .grumbleBoneDim

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = #selector(buttonPressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(text)
        addSubview(button)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(granted: Bool, buttonTitle: String) {
        dot.layer?.backgroundColor =
            (granted ? NSColor.systemGreen : NSColor.grumbleNeedle).cgColor
        button.isHidden = granted
        if !granted { button.title = buttonTitle }
    }

    @objc private func buttonPressed() {
        action()
    }
}
