import AppKit
import Foundation
import UserNotifications

/// Owns the meeting feature end to end: the store, the recorder session, the
/// detector, and the post-processing pipeline. The app delegate talks to this
/// and nothing else about meetings.
@MainActor
final class MeetingsController: NSObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date, sourceBundleID: String?)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    /// Something processed or changed state; menus and windows should
    /// refresh.
    var onActivity: (() -> Void)?

    let store: MeetingStore?
    private(set) var pipeline: MeetingPipeline?
    private let detector = MeetingDetector()
    private var session: MeetingSession?

    private static let askCategoryID = "GRUMBLE_MEETING_ASK"
    private static let recordActionID = "RECORD"
    private static let endCategoryID = "GRUMBLE_MEETING_END"
    private static let keepActionID = "KEEP"
    /// How long the "still in a meeting?" prompt stands before the recording
    /// stops on its own.
    private static let stopConfirmDelay: TimeInterval = 30

    /// A browser-triggered stop waiting out `stopConfirmDelay`, and the
    /// trigger apps it is waiting on.
    private var pendingStop: Task<Void, Never>?
    private var pendingStopTriggers: Set<String> = []

    override init() {
        do {
            let store = try MeetingStore()
            self.store = store
            self.pipeline = MeetingPipeline(store: store)
        } catch {
            NSLog("Grumble: meeting database unavailable: \(error)")
            self.store = nil
            self.pipeline = nil
        }
        super.init()

        guard pipeline != nil else { return }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(
            identifier: Self.recordActionID, title: "Record", options: [])
        let askCategory = UNNotificationCategory(
            identifier: Self.askCategoryID, actions: [record], intentIdentifiers: [])
        let keep = UNNotificationAction(
            identifier: Self.keepActionID, title: "Keep Recording", options: [])
        let endCategory = UNNotificationCategory(
            identifier: Self.endCategoryID, actions: [keep], intentIdentifiers: [])
        center.setNotificationCategories([askCategory, endCategory])

        detector.onAutoStart = { [weak self] bundleID in
            guard let self else { return }
            guard self.state == .idle else {
                // Already recording, most likely started by hand before the
                // meeting app opened the mic: adopt it so end detection has
                // something to track.
                if self.detector.activeTriggerIDs.isEmpty {
                    self.detector.adoptMeeting(seed: bundleID)
                }
                return
            }
            self.startRecording(sourceBundleID: bundleID)
            guard self.isRecording else { return }
            self.notify(
                title: "Recording meeting",
                body: "Grumble is recording \(Self.appName(for: bundleID)). "
                    + "Stop or discard from the menu bar.")
        }
        detector.onAsk = { [weak self] bundleID in
            guard let self, self.state == .idle else { return }
            self.askToRecord(bundleID: bundleID)
        }
        detector.onMeetingEnd = { [weak self] triggerIDs in
            guard let self, case .recording = self.state else { return }
            // A browser letting go of the mic is a weak signal: it could be a
            // tab switch or a device change as easily as the end of the call.
            // Native meeting apps are trusted to mean it.
            if !triggerIDs.isEmpty, triggerIDs.allSatisfy(MeetingDetector.isBrowser) {
                self.confirmStop(triggerIDs: triggerIDs)
            } else {
                self.stopRecording(automatic: true)
            }
        }

        SummarizerManager.shared.onReady = { [weak self] summarizer in
            let pipeline = self?.pipeline
            Task { await pipeline?.setSummarizer(summarizer) }
        }
        SummarizerManager.shared.loadIfInstalled()

        Task { [pipeline, store] in
            await pipeline?.setOnActivity { [weak self] in
                Task { @MainActor in self?.onActivity?() }
            }
            await pipeline?.resumePending()
            if let store { MeetingAudioRetention.enforce(store: store) }
        }
        detector.start()
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording(sourceBundleID: MeetingDetector.currentMeetingApp())
        case .recording:
            stopRecording()
        }
    }

    func startRecording(sourceBundleID: String?) {
        guard state == .idle, let store else { return }
        do {
            let session = try MeetingSession(sourceBundleID: sourceBundleID)
            try session.start()
            self.session = session
            try store.createMeeting(
                audioDir: session.dir.lastPathComponent,
                startedAt: session.startedAt,
                sourceBundleId: sourceBundleID
            )
            detector.adoptMeeting(seed: sourceBundleID)
            clearPendingStop()
            state = .recording(startedAt: session.startedAt, sourceBundleID: sourceBundleID)
        } catch {
            session?.discard()
            session = nil
            showAlert("Couldn't start the meeting recording: \(error.localizedDescription)")
        }
        onActivity?()
    }

    /// `automatic` marks the stop as coming from the detector; a stop the
    /// user asked for also blocks auto-record until the meeting app releases
    /// the mic, so it doesn't start straight back up.
    func stopRecording(automatic: Bool = false) {
        guard case .recording = state, let session else { return }
        session.stop()
        let audioDir = session.dir.lastPathComponent
        self.session = nil
        clearPendingStop(audioDir: audioDir)
        detector.releaseMeeting()
        if !automatic { detector.suppressCurrentCaptures() }
        state = .idle
        try? store?.setState(audioDir: audioDir, .queued)
        Task { [pipeline] in await pipeline?.enqueue(audioDir: audioDir) }
        onActivity?()
    }

    func discardRecording() {
        guard case .recording = state, let session else { return }
        let audioDir = session.dir.lastPathComponent
        session.discard()
        self.session = nil
        clearPendingStop(audioDir: audioDir)
        detector.releaseMeeting()
        detector.suppressCurrentCaptures()
        state = .idle
        if let store, let meeting = try? store.meeting(audioDir: audioDir) {
            try? store.deleteMeeting(meeting)
        }
        onActivity?()
    }

    // MARK: - Stop confirmation

    /// A browser released the mic. Ask before ending the recording, and stop
    /// once the prompt has stood unanswered for `stopConfirmDelay`.
    private func confirmStop(triggerIDs: Set<String>) {
        guard let audioDir = session?.dir.lastPathComponent else { return }
        clearPendingStop()
        pendingStopTriggers = triggerIDs
        pendingStop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stopConfirmDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingStop = nil
            self.pendingStopTriggers = []
            self.clearStopPrompt(audioDir: audioDir)
            guard self.session?.dir.lastPathComponent == audioDir else { return }
            // Back on the mic while the prompt stood: the meeting carried on,
            // so hand end detection back to the detector.
            if self.resumeTracking(triggerIDs) { return }
            self.stopRecording(automatic: true)
        }

        requestNotificationAuthorization { [weak self] granted in
            guard let self, self.session?.dir.lastPathComponent == audioDir else { return }
            guard granted else {
                // Nowhere to ask: stop as we always did.
                self.clearPendingStop()
                self.stopRecording(automatic: true)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Still in a meeting?"
            let name = triggerIDs.first.map { Self.appName(for: $0) }
            content.body =
                (name.map { "\($0) stopped using the microphone. " } ?? "")
                + "Grumble stops recording in \(Int(Self.stopConfirmDelay)) seconds."
            content.categoryIdentifier = Self.endCategoryID
            content.userInfo = ["audioDir": audioDir]
            let request = UNNotificationRequest(
                identifier: Self.stopPromptID(audioDir), content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// "Keep Recording": drop the pending stop. If a trigger app is back on
    /// the mic the detector takes over again, otherwise the recording runs
    /// until the user stops it.
    private func keepRecording(audioDir: String?) {
        guard let audioDir, session?.dir.lastPathComponent == audioDir else { return }
        let triggers = pendingStopTriggers
        clearPendingStop(audioDir: audioDir)
        _ = resumeTracking(triggers)
        onActivity?()
    }

    /// Re-adopt the meeting if one of its apps is capturing again. Returns
    /// whether it was.
    private func resumeTracking(_ triggerIDs: Set<String>) -> Bool {
        guard let back = MeetingDetector.capturing(among: triggerIDs).first else { return false }
        detector.adoptMeeting(seed: back)
        return true
    }

    private func clearPendingStop(audioDir: String? = nil) {
        pendingStop?.cancel()
        pendingStop = nil
        pendingStopTriggers = []
        if let audioDir { clearStopPrompt(audioDir: audioDir) }
    }

    private func clearStopPrompt(audioDir: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.stopPromptID(audioDir)])
    }

    private static func stopPromptID(_ audioDir: String) -> String {
        "grumble-end-\(audioDir)"
    }

    // MARK: - Ask flow

    private func askToRecord(bundleID: String) {
        requestNotificationAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                // No notification permission: fall back to an alert.
                let alert = NSAlert()
                alert.messageText = "Record this meeting?"
                alert.informativeText =
                    "\(Self.appName(for: bundleID)) is using your microphone. "
                    + "Grumble can record and transcribe the meeting on this Mac."
                alert.addButton(withTitle: "Record")
                alert.addButton(withTitle: "Not Now")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    self.startRecording(sourceBundleID: bundleID)
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Record this meeting?"
            content.body =
                "\(Self.appName(for: bundleID)) is using your microphone. "
                + "Grumble can record and transcribe it on this Mac."
            content.categoryIdentifier = Self.askCategoryID
            content.userInfo = ["bundleID": bundleID]
            let request = UNNotificationRequest(
                identifier: "grumble-ask-\(bundleID)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func notify(title: String, body: String) {
        requestNotificationAuthorization { granted in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func requestNotificationAuthorization(_ completion: @escaping @MainActor (Bool) -> Void)
    {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    Task { @MainActor in completion(granted) }
                }
            case .authorized, .provisional:
                Task { @MainActor in completion(true) }
            default:
                Task { @MainActor in completion(false) }
            }
        }
    }

    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName")
                as? String
        {
            return name
        }
        return bundleID
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Grumble"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension MeetingsController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let bundleID = userInfo["bundleID"] as? String
        let audioDir = userInfo["audioDir"] as? String
        let actionID = response.actionIdentifier
        let categoryID = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            let acted =
                actionID == UNNotificationDefaultActionIdentifier
                || actionID == Self.recordActionID || actionID == Self.keepActionID
            if categoryID == Self.endCategoryID {
                if acted { self.keepRecording(audioDir: audioDir) }
            } else if let bundleID, acted {
                self.startRecording(sourceBundleID: bundleID)
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
