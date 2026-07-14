import AppKit

/// Grumble identity ("the settling waveform": amber grumble in, bone sentence
/// out, needle-red full stop) on a warm charcoal faceplate.
extension NSColor {
    static let grumbleNeedle = NSColor(srgbRed: 212 / 255, green: 85 / 255, blue: 58 / 255, alpha: 1)
    static let grumbleAmber = NSColor(srgbRed: 232 / 255, green: 163 / 255, blue: 61 / 255, alpha: 1)
    static let grumbleFaceplate = NSColor(srgbRed: 30 / 255, green: 24 / 255, blue: 19 / 255, alpha: 1)
    static let grumbleBone = NSColor(srgbRed: 239 / 255, green: 230 / 255, blue: 214 / 255, alpha: 1)
    static let grumbleBoneDim = NSColor(srgbRed: 168 / 255, green: 154 / 255, blue: 133 / 255, alpha: 1)
}

extension NSFont {
    /// Condensed all-caps "panel label" face used for UI labels.
    static func grumblePanelLabel(size: CGFloat) -> NSFont {
        NSFont(name: "AvenirNextCondensed-DemiBold", size: size)
            ?? .systemFont(ofSize: size, weight: .semibold)
    }
}

extension NSAttributedString {
    static func grumblePanelLabel(_ text: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.grumblePanelLabel(size: size),
                .kern: size * 0.14,
                .foregroundColor: color,
            ]
        )
    }
}

extension NSImage {
    /// The settling-waveform mark as a menu bar template image, drawn in code
    /// so it stays crisp at any scale and adapts to menu bar appearance.
    @MainActor static let grumbleMenuBarMark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            func addQuad(_ path: NSBezierPath, cp: NSPoint, to end: NSPoint) {
                let s = path.currentPoint
                path.curve(
                    to: end,
                    controlPoint1: NSPoint(
                        x: s.x + 2 * (cp.x - s.x) / 3, y: s.y + 2 * (cp.y - s.y) / 3),
                    controlPoint2: NSPoint(
                        x: end.x + 2 * (cp.x - end.x) / 3, y: end.y + 2 * (cp.y - end.y) / 3)
                )
            }

            NSColor.black.set()

            let grumble = NSBezierPath()
            grumble.lineWidth = 1.7
            grumble.lineCapStyle = .round
            grumble.move(to: NSPoint(x: 2.5, y: 13.5))
            addQuad(grumble, cp: NSPoint(x: 4.1, y: 17.1), to: NSPoint(x: 5.75, y: 13.5))
            addQuad(grumble, cp: NSPoint(x: 7.4, y: 10.3), to: NSPoint(x: 9, y: 13.5))
            addQuad(grumble, cp: NSPoint(x: 10.6, y: 17.3), to: NSPoint(x: 12.25, y: 13.5))
            addQuad(grumble, cp: NSPoint(x: 13.9, y: 10.7), to: NSPoint(x: 15.5, y: 13.5))
            grumble.stroke()

            let settling = NSBezierPath()
            settling.lineWidth = 1.7
            settling.lineCapStyle = .round
            settling.move(to: NSPoint(x: 2.5, y: 9))
            addQuad(settling, cp: NSPoint(x: 4.4, y: 11), to: NSPoint(x: 6.3, y: 9))
            addQuad(settling, cp: NSPoint(x: 8.2, y: 7.1), to: NSPoint(x: 10.1, y: 9))
            addQuad(settling, cp: NSPoint(x: 12, y: 10.9), to: NSPoint(x: 13.9, y: 9))
            settling.stroke()

            let sentence = NSBezierPath()
            sentence.lineWidth = 1.7
            sentence.lineCapStyle = .round
            sentence.move(to: NSPoint(x: 2.5, y: 4.5))
            sentence.line(to: NSPoint(x: 11, y: 4.5))
            sentence.stroke()
            NSBezierPath(ovalIn: NSRect(x: 13.2, y: 3.3, width: 2.4, height: 2.4)).fill()

            return true
        }
        image.isTemplate = true
        return image
    }()
}
