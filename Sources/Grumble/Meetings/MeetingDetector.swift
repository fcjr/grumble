import CoreAudio
import Foundation

/// Watches which processes are capturing the microphone via the CoreAudio
/// process-object API (macOS 14.4+) and decides when a meeting starts and
/// ends. A known meeting app capturing the mic for 3 continuous seconds is a
/// meeting; the meeting is over when every app that joined it has released
/// the mic for 8 seconds.
/// Browsers capturing the mic imply a web meeting (Google Meet has no native
/// app) but only ever "ask" - a mic-using tab could be anything.
@MainActor
final class MeetingDetector {
    enum Policy: String {
        case auto, ask, never
    }

    /// A meeting app started capturing and policy says record automatically.
    var onAutoStart: ((String) -> Void)?
    /// An app started capturing and policy says ask first.
    var onAsk: ((String) -> Void)?
    /// The app that triggered the current meeting released the mic.
    var onMeetingEnd: (() -> Void)?

    private static let startDebounce: TimeInterval = 3
    private static let endDebounce: TimeInterval = 8

    /// Native meeting apps that default to auto-record.
    private static let meetingApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
    ]

    /// Browser bundle-id prefixes that default to ask-first.
    private static let browserPrefixes: [String] = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    private static let enabledKey = "meetingAutoDetect"
    private static let policiesKey = "meetingAppPolicies"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Effective policy for a bundle id: user override first, then the
    /// built-in lists, then never.
    static func policy(for bundleID: String) -> Policy {
        let overrides = UserDefaults.standard.dictionary(forKey: policiesKey) as? [String: String]
        if let raw = overrides?[bundleID], let policy = Policy(rawValue: raw) {
            return policy
        }
        if meetingApps.contains(bundleID) { return .auto }
        if browserPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return .ask }
        return .never
    }

    static func setPolicy(_ policy: Policy, for bundleID: String) {
        var overrides =
            UserDefaults.standard.dictionary(forKey: policiesKey) as? [String: String] ?? [:]
        overrides[bundleID] = policy.rawValue
        UserDefaults.standard.set(overrides, forKey: policiesKey)
    }

    /// Bundle ids worth offering policy control for in the UI.
    static var knownApps: [String] {
        (Array(meetingApps) + browserPrefixes).sorted()
    }

    private var listenerQueue = DispatchQueue(label: "com.leftshift.grumble.mic-watch")
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var listenedProcesses: Set<AudioObjectID> = []
    private var startTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    /// Apps keeping the current meeting alive: the one that triggered it
    /// plus anything that joined the mic later. Set by the controller through
    /// `adoptMeeting` and sticky until the end debounce fires, so brief
    /// mute/unmute cycles don't split one meeting into many.
    private(set) var activeTriggerIDs: Set<String> = []
    /// Bundle ids already asked about this capture session, so one "ask"
    /// notification doesn't repeat every property change.
    private var asked: Set<String> = []
    /// Bundle ids that must not trigger another start until they release the
    /// mic, because a start attempt for them didn't produce a recording.
    private var suppressed: Set<String> = []

    func start() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listenerBlock = block
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        refresh()
    }

    func stop() {
        if let listenerBlock {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, listenerBlock)
            var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
            for process in listenedProcesses {
                AudioObjectRemovePropertyListenerBlock(
                    process, &inputAddress, listenerQueue, listenerBlock)
            }
        }
        listenerBlock = nil
        listenedProcesses = []
        startTask?.cancel()
        endTask?.cancel()
    }

    /// Re-evaluate who is capturing the mic and drive the state machine.
    private func refresh() {
        guard let listenerBlock else { return }

        let processes = Self.processObjects()

        // Keep an IsRunningInput listener on every live process object so
        // capture starts and stops wake us without polling.
        var inputAddress = Self.address(kAudioProcessPropertyIsRunningInput)
        let current = Set(processes)
        for process in current.subtracting(listenedProcesses) {
            AudioObjectAddPropertyListenerBlock(
                process, &inputAddress, listenerQueue, listenerBlock)
        }
        listenedProcesses = current

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var capturing: Set<String> = []
        for process in processes {
            guard Self.isRunningInput(process), Self.pid(of: process) != ownPID,
                let bundleID = Self.bundleID(of: process), !bundleID.isEmpty
            else { continue }
            capturing.insert(bundleID)
        }

        asked.formIntersection(capturing)
        suppressed.formIntersection(capturing)

        if !activeTriggerIDs.isEmpty {
            // A meeting app that joins the mic mid-meeting - a huddle that
            // outlives the call it started in, a handoff between apps - holds
            // the recording open too. Only auto-record apps qualify: a
            // browser tab that grabs the mic for something unrelated must not
            // be able to keep a recording running indefinitely.
            activeTriggerIDs.formUnion(
                capturing.subtracting(activeTriggerIDs).filter {
                    Self.policy(for: $0) == .auto
                })

            if !activeTriggerIDs.isDisjoint(with: capturing) {
                endTask?.cancel()
                endTask = nil
            } else if endTask == nil {
                endTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.endDebounce * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.endTask = nil
                    // The debounce runs on notifications alone, and a missed
                    // one would end a live meeting. Confirm against the real
                    // state before stopping anything.
                    let capturing = Self.currentlyCapturingBundleIDs(
                        excludingPID: ProcessInfo.processInfo.processIdentifier)
                    guard self.activeTriggerIDs.isDisjoint(with: capturing) else {
                        self.refresh()
                        return
                    }
                    self.activeTriggerIDs = []
                    self.onMeetingEnd?()
                }
            }
            return
        }

        guard Self.isEnabled else { return }

        let autoCandidate = capturing.first {
            Self.policy(for: $0) == .auto && !suppressed.contains($0)
        }
        let askCandidate = capturing.first {
            Self.policy(for: $0) == .ask && !asked.contains($0) && !suppressed.contains($0)
        }
        guard autoCandidate != nil || askCandidate != nil else {
            startTask?.cancel()
            startTask = nil
            return
        }
        guard startTask == nil else { return }

        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.startDebounce * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.startTask = nil

            // Re-check after the debounce: the capture must still be live.
            let stillCapturing = Self.currentlyCapturingBundleIDs(excludingPID: ownPID)
            if let auto = stillCapturing.first(where: {
                Self.policy(for: $0) == .auto && !self.suppressed.contains($0)
            }) {
                self.onAutoStart?(auto)
                // The controller adopts the meeting once the recording is
                // really running. If it isn't - the recorder failed to start -
                // don't retry this app until it releases the mic.
                if self.activeTriggerIDs.isEmpty { self.suppressed.insert(auto) }
            } else if let ask = stillCapturing.first(where: {
                Self.policy(for: $0) == .ask && !self.asked.contains($0)
                    && !self.suppressed.contains($0)
            }) {
                self.asked.insert(ask)
                self.onAsk?(ask)
            }
        }
    }

    /// Called by the controller when a recording starts, so end detection
    /// tracks the apps hosting the meeting: `seed` (the app that triggered
    /// it, if any) plus any meeting app already capturing.
    func adoptMeeting(seed: String?) {
        var ids = Self.currentlyCapturingBundleIDs(
            excludingPID: ProcessInfo.processInfo.processIdentifier
        ).filter { Self.policy(for: $0) == .auto }
        if let seed { ids.insert(seed) }
        activeTriggerIDs = ids
        endTask?.cancel()
        endTask = nil
    }

    /// The recording stopped; forget its trigger apps.
    func releaseMeeting() {
        activeTriggerIDs = []
        endTask?.cancel()
        endTask = nil
    }

    /// Don't auto-start for anything holding the mic right now until it lets
    /// go. The controller calls this when the user stops or discards a
    /// recording by hand: the meeting app usually keeps capturing, and
    /// starting a fresh recording seconds later isn't what they asked for.
    func suppressCurrentCaptures() {
        suppressed.formUnion(
            Self.currentlyCapturingBundleIDs(
                excludingPID: ProcessInfo.processInfo.processIdentifier))
        startTask?.cancel()
        startTask = nil
    }

    /// The app most plausibly hosting a meeting right now, for tagging
    /// manual recordings.
    static func currentMeetingApp() -> String? {
        let capturing = currentlyCapturingBundleIDs(
            excludingPID: ProcessInfo.processInfo.processIdentifier)
        return capturing.first { policy(for: $0) == .auto }
            ?? capturing.first { policy(for: $0) == .ask }
    }

    // MARK: - CoreAudio property plumbing

    private static func address(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func currentlyCapturingBundleIDs(excludingPID: Int32) -> Set<String> {
        var out: Set<String> = []
        for process in processObjects() {
            guard isRunningInput(process), pid(of: process) != excludingPID,
                let bundleID = bundleID(of: process), !bundleID.isEmpty
            else { continue }
            out.insert(bundleID)
        }
        return out
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else {
            return []
        }
        return list
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String
    }

    private static func pid(of process: AudioObjectID) -> Int32 {
        var address = address(kAudioProcessPropertyPID)
        var value: Int32 = -1
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else {
            return -1
        }
        return value
    }
}
