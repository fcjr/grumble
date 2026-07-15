import AppKit

/// A small floating pill shown near the bottom of the screen while dictation
/// is active. Non-activating and click-through, so focus stays in the text
/// field being dictated into. Styled as a Grumble faceplate: panel-label
/// type, glowing state dot, and a live VU meter while listening.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let meter = LevelMeterView()
    private var showToken = 0

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

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.grumbleFaceplate.withAlphaComponent(0.96).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        meter.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(dot)
        card.addSubview(label)
        card.addSubview(meter)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: 0.5),
            meter.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            meter.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            meter.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        panel.contentView = card
    }

    /// Show a message briefly, then hide - unless something else has taken
    /// over the overlay in the meantime.
    func flash(_ text: String, color: NSColor, duration: TimeInterval = 2.2) {
        show(text, color: color, pulsing: false)
        let token = showToken
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.showToken == token else { return }
            self.hide()
        }
    }

    func show(_ text: String, color: NSColor, pulsing: Bool) {
        showToken += 1
        label.attributedStringValue = .grumblePanelLabel(text, size: 12, color: .grumbleBone)
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.shadowColor = color.cgColor
        dot.layer?.shadowOpacity = 0.85
        dot.layer?.shadowRadius = 4
        dot.layer?.shadowOffset = .zero
        meter.isHidden = !pulsing
        if !pulsing { meter.setLevel(0) }
        if pulsing {
            startPulse()
        } else {
            stopPulse()
        }
        layout()
        panel.orderFrontRegardless()
    }

    func hide() {
        showToken += 1
        stopPulse()
        meter.setLevel(0)
        panel.orderOut(nil)
    }

    func setLevel(_ level: Float) {
        guard panel.isVisible, !meter.isHidden else { return }
        meter.setLevel(level)
    }

    private func layout() {
        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }
        let fitting = panel.contentView?.fittingSize ?? .zero
        let width = max(fitting.width, 128)
        let height: CGFloat = 36
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
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        dot.layer?.removeAnimation(forKey: "pulse")
    }
}

/// Five amber bars that bounce with microphone level, VU-meter style.
final class LevelMeterView: NSView {
    private var bars: [CALayer] = []
    private let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.75, 0.5]
    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 3
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 14

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap,
            height: maxHeight + 2
        )
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in weights {
            let bar = CALayer()
            bar.backgroundColor = NSColor.grumbleAmber.cgColor
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        setLevel(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        positionBars(level: 0, animated: false)
    }

    func setLevel(_ level: Float) {
        positionBars(level: CGFloat(level), animated: true)
    }

    private func positionBars(level: CGFloat, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.09)
        let midY = bounds.midY
        for (index, bar) in bars.enumerated() {
            let liveliness = level > 0.02 ? CGFloat.random(in: 0...0.12) : 0
            let scaled = min(1, level * weights[index] + liveliness)
            let height = minHeight + (maxHeight - minHeight) * scaled
            bar.frame = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
        }
        CATransaction.commit()
    }
}
