import CoreAudio
import Foundation

/// Enumerates input-capable audio devices and remembers the user's choice.
/// Selection is stored by device UID (stable across reconnects and reboots,
/// unlike AudioDeviceID); the name is stored alongside it so the menu can
/// still show a disconnected device. No stored choice means "follow the
/// system default input".
enum AudioInputDevices {
    struct Device: Equatable {
        let uid: String
        let name: String
    }

    private static let uidDefaultsKey = "inputDeviceUID"
    private static let nameDefaultsKey = "inputDeviceName"

    /// The saved device, or nil for the system default.
    static var preferred: Device? {
        get {
            guard let uid = UserDefaults.standard.string(forKey: uidDefaultsKey) else {
                return nil
            }
            return Device(
                uid: uid,
                name: UserDefaults.standard.string(forKey: nameDefaultsKey) ?? uid)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uid, forKey: uidDefaultsKey)
                UserDefaults.standard.set(newValue.name, forKey: nameDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: uidDefaultsKey)
                UserDefaults.standard.removeObject(forKey: nameDefaultsKey)
            }
        }
    }

    /// All devices currently able to capture audio.
    static func available() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id),
                let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    /// AudioDeviceID for the saved choice, or nil when unset or currently
    /// disconnected (callers fall back to the system default).
    static func preferredDeviceID() -> AudioDeviceID? {
        guard let uid = preferred?.uid else { return nil }
        return allDeviceIDs().first { id in
            hasInput(id) && stringProperty(id, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr
        else { return false }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
            let value
        else { return nil }
        return value.takeRetainedValue() as String
    }
}
