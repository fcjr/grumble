import AppKit

/// A small floating pill shown near the bottom of the screen while dictation
/// is active. Non-activating and click-through, so focus stays in the text
/// field being dictated into.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(dot)
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        panel.contentView = effect
    }

    func show(_ text: String, color: NSColor, pulsing: Bool) {
        label.stringValue = text
        dot.layer?.backgroundColor = color.cgColor
        if pulsing {
            startPulse()
        } else {
            stopPulse()
        }
        layout()
        panel.orderFrontRegardless()
    }

    func hide() {
        stopPulse()
        panel.orderOut(nil)
    }

    private func layout() {
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let fitting = panel.contentView?.fittingSize ?? .zero
        let width = max(fitting.width, 120)
        let height: CGFloat = 34
        panel.setFrame(
            NSRect(
                x: screen.visibleFrame.midX - width / 2,
                y: screen.visibleFrame.minY + 24,
                width: width,
                height: height
            ),
            display: true
        )
    }

    private func startPulse() {
        guard dot.layer?.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        dot.layer?.removeAnimation(forKey: "pulse")
    }
}
