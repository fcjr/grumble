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
        let category = UNNotificationCategory(
            identifier: Self.askCategoryID, actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])

        detector.onAutoStart = { [weak self] bundleID in
            guard let self else { return }
            guard self.state == .idle else {
                // Already recording, most likely started by hand before the
                // meeting app opened the mic: adopt it so end detection has
                // something to track.
                if self.detector.activeMeetingBundleID == nil {
                    self.detector.adoptMeeting(bundleID: bundleID)
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
        detector.onMeetingEnd = { [weak self] in
            guard let self, case .recording = self.state else { return }
            self.stopRecording(automatic: true)
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
            detector.adoptMeeting(bundleID: sourceBundleID)
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
        detector.adoptMeeting(bundleID: nil)
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
        detector.adoptMeeting(bundleID: nil)
        detector.suppressCurrentCaptures()
        state = .idle
        if let store, let meeting = try? store.meeting(audioDir: audioDir) {
            try? store.deleteMeeting(meeting)
        }
        onActivity?()
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
        let actionID = response.actionIdentifier
        Task { @MainActor in
            if let bundleID,
                actionID == Self.recordActionID || actionID == UNNotificationDefaultActionIdentifier
            {
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
