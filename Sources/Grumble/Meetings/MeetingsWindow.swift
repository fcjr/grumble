import AVFoundation
import AppKit
import Combine
import GRDB
import SwiftUI

extension Notification.Name {
    /// Posted whenever meeting data changes so open UI refreshes.
    static let grumbleMeetingsChanged = Notification.Name("GrumbleMeetingsChanged")
}

/// The Meetings browser window, opened from the menu bar. Grumble stays a
/// menu bar app; this is an ordinary titled window hosting SwiftUI.
@MainActor
final class MeetingsWindowController {
    private var window: NSWindow?
    private weak var controller: MeetingsController?

    init(controller: MeetingsController) {
        self.controller = controller
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let controller, let store = controller.store else { return }

        let view = MeetingsView(
            model: MeetingsViewModel(store: store, controller: controller))
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Meetings"
        window.setContentSize(NSSize(width: 900, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View model

@MainActor
final class MeetingsViewModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var query: String = "" {
        didSet { refresh() }
    }
    @Published var selectedID: Int64?
    @Published var speakers: [MeetingSpeaker] = []
    @Published var segments: [MeetingSegment] = []

    let store: MeetingStore
    weak var controller: MeetingsController?
    private var changeObserver: NSObjectProtocol?
    let playback = MeetingPlayback()

    init(store: MeetingStore, controller: MeetingsController) {
        self.store = store
        self.controller = controller
        changeObserver = NotificationCenter.default.addObserver(
            forName: .grumbleMeetingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    var selected: Meeting? {
        meetings.first { $0.id == selectedID }
    }

    func refresh() {
        meetings = (try? store.meetings(matching: query)) ?? []
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) {
            selectedID = meetings.first?.id
        }
        loadDetail()
    }

    func loadDetail() {
        guard let selectedID else {
            speakers = []
            segments = []
            playback.unload()
            return
        }
        speakers = (try? store.speakers(meetingId: selectedID)) ?? []
        segments = (try? store.segments(meetingId: selectedID)) ?? []
        if let meeting = selected {
            playback.load(meeting: meeting)
        }
    }

    func speakerLabel(for id: Int64) -> String {
        speakers.first { $0.id == id }?.label ?? "Speaker"
    }

    func speakerColor(for id: Int64) -> Color {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return .secondary }
        if speakers[index].slot == "me" { return Color(nsColor: .grumbleAmber) }
        let palette: [Color] = [.blue, .green, .purple, .pink, .teal]
        return palette[index % palette.count]
    }

    func rename(speaker: MeetingSpeaker, to name: String) {
        guard let id = speaker.id else { return }
        try? store.renameSpeaker(id: id, to: name)
        refresh()
    }

    func setTitle(_ title: String) {
        guard var meeting = selected else { return }
        meeting.title = title.isEmpty ? nil : title
        try? store.update(meeting)
        refresh()
    }

    func delete(_ meeting: Meeting) {
        try? store.deleteMeeting(meeting)
        playback.unload()
        refresh()
    }

    func copyTranscript(_ meeting: Meeting) {
        guard let markdown = try? store.markdown(for: meeting) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func exportMarkdown(_ meeting: Meeting) {
        guard let markdown = try? store.markdown(for: meeting) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.displayTitle + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    func retry(_ meeting: Meeting) {
        try? store.setState(audioDir: meeting.audioDir, .queued)
        let pipeline = controller?.pipeline
        Task { await pipeline?.enqueue(audioDir: meeting.audioDir) }
        refresh()
    }
}

// MARK: - Playback

/// Plays a meeting by mixing the two raw tracks into one composition at
/// their recorded offsets.
@MainActor
final class MeetingPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    private var loadedDir: String?

    func load(meeting: Meeting) {
        guard meeting.audioDir != loadedDir else { return }
        unload()
        let dir = MeetingSession.meetingsRoot().appendingPathComponent(meeting.audioDir)
        let meta = MeetingSessionMeta.load(from: dir)
        let composition = AVMutableComposition()
        for (file, key) in [("mic.caf", "mic"), ("system.caf", "system")] {
            let url = dir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let assetTrack = asset.tracks(withMediaType: .audio).first,
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let offsetMs = meta?.startOffsetMs[key] ?? 0
            try? track.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: assetTrack,
                at: CMTime(value: CMTimeValue(offsetMs), timescale: 1000)
            )
        }
        guard !composition.tracks.isEmpty else { return }
        player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        loadedDir = meeting.audioDir
    }

    func playFrom(ms: Int) {
        guard let player else { return }
        player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000))
        player.play()
    }

    func pause() {
        player?.pause()
    }

    func unload() {
        player?.pause()
        player = nil
        loadedDir = nil
    }
}

// MARK: - Views

struct MeetingsView: View {
    @ObservedObject var model: MeetingsViewModel

    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let meeting = model.selected {
                MeetingDetailView(model: model, meeting: meeting)
            } else {
                emptyState
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search meetings")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Meeting Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showingSettings) {
                    MeetingSettingsView()
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private var list: some View {
        List(selection: $model.selectedID) {
            ForEach(model.meetings) { meeting in
                MeetingRow(meeting: meeting)
                    .tag(meeting.id ?? -1)
            }
        }
        .onChange(of: model.selectedID) { model.loadDetail() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No meetings yet")
                .font(.title3)
            Text(
                "Grumble records automatically when a meeting app uses your microphone, "
                    + "or start one from the menu bar."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    @ObservedObject private var center = MeetingProgressCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.displayTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.month().day().hour().minute())
                if meeting.durationSeconds > 0 {
                    Text("·")
                    Text(Self.duration(meeting.durationSeconds))
                }
                stateBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch meeting.state {
        case .recording:
            Label("Recording", systemImage: "record.circle")
                .foregroundStyle(.red)
        case .queued, .transcribing:
            if let progress = center.progress(for: meeting), let fraction = progress.fraction {
                Label(
                    "Transcribing \(Int(fraction * 100))%", systemImage: "waveform")
            } else {
                Label(meeting.state == .queued ? "Queued" : "Transcribing", systemImage: "waveform")
            }
        case .summarizing:
            Label("Summarizing", systemImage: "sparkles")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .done:
            EmptyView()
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MeetingDetailView: View {
    @ObservedObject var model: MeetingsViewModel
    let meeting: Meeting
    @State private var editedTitle: String = ""
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if meeting.state == .failed {
                    failureBox
                }
                if let summary = meeting.summary, !summary.isEmpty {
                    summaryBox(summary)
                } else if meeting.state == .done, !model.segments.isEmpty {
                    SummarizeControl(model: model, meeting: meeting)
                }
                participants
                transcript
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.copyTranscript(meeting)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(model.segments.isEmpty)
                Button {
                    model.exportMarkdown(meeting)
                } label: {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                }
                .disabled(model.segments.isEmpty)
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete this meeting?", isPresented: $confirmingDelete
        ) {
            Button("Delete Meeting and Audio", role: .destructive) {
                model.delete(meeting)
            }
        } message: {
            Text("The recording, transcript, and summary are removed from this Mac.")
        }
        .onAppear { editedTitle = meeting.title ?? "" }
        .onChange(of: meeting.id) { editedTitle = meeting.title ?? "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(meeting.displayTitle, text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .onSubmit { model.setTitle(editedTitle) }
            HStack(spacing: 8) {
                Text(meeting.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                if meeting.durationSeconds > 0 {
                    Text("·")
                    Text(MeetingRow.duration(meeting.durationSeconds))
                }
                if let source = meeting.sourceBundleId {
                    Text("·")
                    Text(MeetingsController.appName(for: source))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var failureBox: some View {
        HStack {
            Label(
                meeting.errorMessage ?? "Processing failed.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            Spacer()
            Button("Retry") { model.retry(meeting) }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryBox(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Summary", systemImage: "sparkles")
                .font(.headline)
            Text(summary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var participants: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Participants")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(model.speakers) { speaker in
                    SpeakerChip(model: model, speaker: speaker)
                }
            }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                if model.playback.player != nil {
                    Button {
                        model.playback.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .controlSize(.small)
                }
            }
            if model.segments.isEmpty {
                if meeting.state == .queued || meeting.state == .transcribing
                    || meeting.state == .summarizing
                {
                    MeetingProgressView(meeting: meeting)
                } else {
                    Text(transcriptPlaceholder)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.segments) { segment in
                SegmentRow(model: model, segment: segment)
            }
        }
    }

    private var transcriptPlaceholder: String {
        switch meeting.state {
        case .recording: return "Recording. The transcript appears when the meeting ends."
        case .queued, .transcribing: return "Transcribing on this Mac. This usually takes a moment."
        case .summarizing: return "Summarizing."
        case .failed: return "No transcript."
        case .done: return "No speech was detected in this recording."
        }
    }
}

/// Live post-processing status: which stage is running, how far through it
/// is, and roughly how much longer. Falls back to an indeterminate bar with
/// elapsed time when there is no basis for an estimate, and says so plainly
/// when a stage has run far past expectations rather than sitting silent.
struct MeetingProgressView: View {
    let meeting: Meeting
    @ObservedObject private var center = MeetingProgressCenter.shared
    /// Redraws the estimate as it counts down; the progress model derives
    /// everything from the stage start, so there is nothing else to poll.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = center.progress(for: meeting) {
                HStack(spacing: 8) {
                    Text(progress.label)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(remaining(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if progress.isStalled {
                    Label(
                        "This is taking much longer than expected. If it doesn't finish, "
                            + "quit and reopen Grumble to retry.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                // Queued behind another meeting, or the app restarted and
                // has not picked this one back up yet.
                HStack(spacing: 8) {
                    Text(meeting.state == .summarizing ? "Summarizing" : "Waiting to transcribe")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                ProgressView().progressViewStyle(.linear)
            }
            Text("Everything runs on this Mac, so it depends on how busy your machine is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onReceive(tick) { now = $0 }
    }

    private func remaining(_ progress: MeetingProgress) -> String {
        _ = now
        if let seconds = progress.estimatedSecondsRemaining, seconds > 0 {
            return "about \(Self.humanized(seconds)) left"
        }
        let elapsed = Date().timeIntervalSince(progress.stageStartedAt)
        return "\(Self.humanized(elapsed)) elapsed"
    }

    static func humanized(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1))s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}

/// Auto-record master switch, per-app recording policies, and audio
/// retention.
struct MeetingSettingsView: View {
    @State private var autoDetect = MeetingDetector.isEnabled
    @State private var retention = MeetingAudioRetention.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Detect meetings automatically", isOn: $autoDetect)
                .onChange(of: autoDetect) { MeetingDetector.isEnabled = autoDetect }

            Picker("Keep raw audio", selection: $retention) {
                ForEach(MeetingAudioRetention.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .onChange(of: retention) { MeetingAudioRetention.current = retention }

            Divider()

            Text("When an app uses the microphone")
                .font(.headline)
            ForEach(MeetingDetector.knownApps, id: \.self) { bundleID in
                AppPolicyRow(bundleID: bundleID)
            }
            Text(
                "Transcripts and summaries are always kept. Only the audio files "
                    + "are affected by retention."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 320)
        }
        .padding(16)
    }
}

struct AppPolicyRow: View {
    let bundleID: String
    @State private var policy: MeetingDetector.Policy

    init(bundleID: String) {
        self.bundleID = bundleID
        _policy = State(initialValue: MeetingDetector.policy(for: bundleID))
    }

    var body: some View {
        Picker(MeetingsController.appName(for: bundleID), selection: $policy) {
            Text("Record automatically").tag(MeetingDetector.Policy.auto)
            Text("Ask first").tag(MeetingDetector.Policy.ask)
            Text("Never record").tag(MeetingDetector.Policy.never)
        }
        .onChange(of: policy) { MeetingDetector.setPolicy(policy, for: bundleID) }
    }
}

/// Entry point for the opt-in summarization model: offers the download the
/// first time, shows progress, and runs summarization once the model is
/// ready.
struct SummarizeControl: View {
    @ObservedObject var model: MeetingsViewModel
    let meeting: Meeting
    @ObservedObject private var manager = SummarizerManager.shared
    @State private var confirmingDownload = false
    @State private var requested = false

    var body: some View {
        HStack(spacing: 10) {
            switch manager.state {
            case .notInstalled:
                Button {
                    confirmingDownload = true
                } label: {
                    Label("Generate Summary\u{2026}", systemImage: "sparkles")
                }
                Text("Uses a local model. Nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 160)
                Text("Downloading summarization model\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .ready:
                Button {
                    requested = true
                    summarize()
                } label: {
                    Label("Generate Summary", systemImage: "sparkles")
                }
                .disabled(requested)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Retry") { manager.install() }
            }
        }
        .confirmationDialog(
            "Download the summarization model?", isPresented: $confirmingDownload
        ) {
            Button("Download (about 3.1 GB)") {
                requested = true
                manager.install()
            }
        } message: {
            Text(
                "Titles, summaries, and speaker naming run on a local Qwen3.5-4B model. "
                    + "It downloads once and everything stays on this Mac.")
        }
        .onChange(of: manager.state) {
            if manager.state == .ready, requested {
                summarize()
            }
        }
        .onChange(of: meeting.id) { requested = false }
    }

    private func summarize() {
        guard let meetingId = meeting.id else { return }
        let pipeline = model.controller?.pipeline
        Task { await pipeline?.summarize(meetingId: meetingId) }
    }
}

struct SpeakerChip: View {
    @ObservedObject var model: MeetingsViewModel
    let speaker: MeetingSpeaker
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        Button {
            name = speaker.displayName ?? ""
            renaming = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.speakerColor(for: speaker.id ?? -1))
                    .frame(width: 8, height: 8)
                Text(speaker.label)
                if speaker.namedBy == "auto" {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("Named automatically from the conversation. Click to correct.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speaker name")
                    .font(.headline)
                TextField("Name", text: $name)
                    .frame(width: 200)
                    .onSubmit { commit() }
                HStack {
                    Spacer()
                    Button("Save") { commit() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    private func commit() {
        model.rename(speaker: speaker, to: name)
        renaming = false
    }
}

struct SegmentRow: View {
    @ObservedObject var model: MeetingsViewModel
    let segment: MeetingSegment

    var body: some View {
        Button {
            model.playback.playFrom(ms: segment.startMs)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.stamp(segment.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.speakerLabel(for: segment.speakerId))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.speakerColor(for: segment.speakerId))
                    Text(segment.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Click to play from here")
    }

    static func stamp(_ ms: Int) -> String {
        let seconds = ms / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
