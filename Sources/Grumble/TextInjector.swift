import AppKit
import CoreGraphics

/// Streams transcript text into the focused text field of whatever app is
/// frontmost, using synthetic keyboard events. Updates set a target string;
/// a typing loop walks the on-screen text toward the target at a steady
/// cadence, so rapid partial-transcript updates coalesce instead of landing
/// as bursts. When streaming partials revise earlier words, only the
/// divergent suffix is backspaced and retyped.
/// Requires accessibility access (System Settings > Privacy & Security > Accessibility).
@MainActor
final class TextInjector {
    private var typed = ""
    private var target = ""
    private var typingTask: Task<Void, Never>?
    private let source = CGEventSource(stateID: .combinedSessionState)

    /// Seconds between keystrokes; deletions run a bit faster than typing.
    private static let typeDelay: UInt64 = 14_000_000
    private static let deleteDelay: UInt64 = 9_000_000

    func reset() {
        typingTask?.cancel()
        typingTask = nil
        typed = ""
        target = ""
    }

    func update(to text: String) {
        target = text
        guard typingTask == nil else { return }
        typingTask = Task { @MainActor [weak self] in
            await self?.runTypingLoop()
        }
    }

    private func runTypingLoop() async {
        while !Task.isCancelled, typed != target {
            let typedChars = Array(typed)
            let targetChars = Array(target)
            var common = 0
            while common < typedChars.count && common < targetChars.count
                && typedChars[common] == targetChars[common]
            {
                common += 1
            }

            if typedChars.count > common {
                pressBackspace()
                typed = String(typedChars.dropLast())
                try? await Task.sleep(nanoseconds: Self.deleteDelay)
            } else if targetChars.count > common {
                let next = targetChars[common]
                type(String(next))
                typed.append(next)
                try? await Task.sleep(nanoseconds: Self.typeDelay)
            }
        }
        typingTask = nil
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
        var units = Array(text.utf16)
        for down in [true, false] {
            guard
                let event = CGEvent(
                    keyboardEventSource: source, virtualKey: 0, keyDown: down)
            else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.post(tap: .cghidEventTap)
        }
    }
}
