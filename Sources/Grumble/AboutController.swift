import AppKit

/// About window: app identity, version, and scrollable license
/// acknowledgements loaded from the bundled Acknowledgements.txt.
@MainActor
final class AboutController {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "About Grumble"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .grumbleFaceplate
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        let icon = NSImageView(
            image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: "")
        name.attributedStringValue = .grumblePanelLabel(
            "Grumble", size: 20, color: .grumbleBone)

        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let version = NSTextField(labelWithString: "Version \(shortVersion) (\(build))")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .grumbleBoneDim

        let copyright = NSTextField(
            labelWithString: "\u{00A9} 2026 Left Shift Logical, LLC \u{00B7} Apache License 2.0")
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .grumbleBoneDim

        let licensesLabel = NSTextField(labelWithString: "")
        licensesLabel.attributedStringValue = .grumblePanelLabel(
            "Licenses", size: 12, color: .grumbleAmber)

        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.white.withAlphaComponent(0.04)
        textView.textColor = .grumbleBoneDim
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        {
            textView.string = text
        } else {
            textView.string = "Acknowledgements are missing from this build."
        }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [icon, name, version, copyright])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 4
        header.setCustomSpacing(10, after: icon)
        header.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(header)
        content.addSubview(licensesLabel)
        content.addSubview(scroll)
        licensesLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            licensesLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            licensesLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: licensesLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
