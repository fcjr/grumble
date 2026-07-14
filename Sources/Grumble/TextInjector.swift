import AppKit
import CoreGraphics

/// Streams transcript text into the focused text field of whatever app is
/// frontmost, using synthetic keyboard events. As streaming partials revise
/// earlier words, only the divergent suffix is backspaced and retyped.
/// Requires accessibility access (System Settings > Privacy & Security > Accessibility).
@MainActor
final class TextInjector {
    private var typed = ""
    private let source = CGEventSource(stateID: .combinedSessionState)

    func reset() {
        typed = ""
    }

    func update(to text: String) {
        guard text != typed else { return }
        let old = Array(typed)
        let new = Array(text)
        var common = 0
        while common < old.count && common < new.count && old[common] == new[common] {
            common += 1
        }
        for _ in 0..<(old.count - common) {
            pressBackspace()
        }
        if common < new.count {
            type(String(new[common...]))
        }
        typed = text
    }

    private func pressBackspace() {
        postKey(CGKeyCode(51), down: true)
        postKey(CGKeyCode(51), down: false)
    }

    private func postKey(_ key: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        else { return }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        // CGEvent unicode payloads are limited; send a few characters per event
        // and never split a grapheme cluster across events.
        var chunk: [UniChar] = []

        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard
                    let event = CGEvent(
                        keyboardEventSource: source, virtualKey: 0, keyDown: down)
                else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }

        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 16 {
                flush()
            }
            chunk.append(contentsOf: units)
        }
        flush()
    }
}
