import Carbon.HIToolbox
import Foundation

/// Registers a system-wide hotkey using the Carbon hotkey API, which works
/// from a background (LSUIElement) app without accessibility access.
final class HotKeyManager {
    var onHotKey: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Returns false when the combo is already registered by another app
    /// (e.g. Raycast also defaults to Option+Space).
    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4752_4D42), id: 1)  // "GRMB"
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            hotKeyRef = nil
            NSLog("Grumble: hotkey registration failed (status %d)", status)
        }
        return hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotKey() }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
