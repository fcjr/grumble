import AppKit
import Carbon.HIToolbox

/// A global hotkey combination, stored as a Carbon key code + modifier mask.
struct HotKey: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotKey(
        keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))

    private static let keyCodeKey = "hotKeyKeyCode"
    private static let modifiersKey = "hotKeyModifiers"

    static func load() -> HotKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else { return .default }
        return HotKey(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            carbonModifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeKey)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: Self.modifiersKey)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "\u{2303}" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "\u{2325}" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "\u{21E7}" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "\u{2318}" }
        return result + keyName
    }

    private var keyName: String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "\u{21A9}"
        case kVK_Tab: return "\u{21E5}"
        case kVK_Delete: return "\u{232B}"
        case kVK_ForwardDelete: return "\u{2326}"
        case kVK_Escape: return "\u{238B}"
        case kVK_LeftArrow: return "\u{2190}"
        case kVK_RightArrow: return "\u{2192}"
        case kVK_UpArrow: return "\u{2191}"
        case kVK_DownArrow: return "\u{2193}"
        case kVK_Home: return "\u{2196}"
        case kVK_End: return "\u{2198}"
        case kVK_PageUp: return "\u{21DE}"
        case kVK_PageDown: return "\u{21DF}"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return Self.layoutKeyName(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    /// Resolve a key code to its character using the current keyboard layout.
    private static func layoutKeyName(for keyCode: UInt32) -> String? {
        guard
            let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutPointer = TISGetInputSourceProperty(
                inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
