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
final class MeetingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: MeetingsViewModel?
    private weak var controller: MeetingsController?

    init(controller: MeetingsController) {
        self.controller = controller
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let controller, let store = controller.store else { return }

        let model = MeetingsViewModel(store: store, controller: controller)
        let hosting = NSHostingController(rootView: MeetingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Meetings"
        window.setContentSize(NSSize(width: 900, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.model = model
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window is only ordered out, so the player would otherwise keep
    /// playing with nothing on screen to stop it.
    func windowWillClose(_ notification: Notification) {
        model?.playback.stop()
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
    @Published var speakers: [MeetingSpeaker] = [] {
        didSet {
            speakerIndex = [:]
            for (offset, speaker) in speakers.enumerated() {
                if let id = speaker.id { speakerIndex[id] = offset }
            }
        }
    }
    @Published var segments: [MeetingSegment] = []
    /// Whether the selected meeting still has both raw tracks on disk, so the
    /// audio export button knows there is something to write out.
    @Published private(set) var selectedHasAudio = false
    /// Mirrors the controller so the window's record button tracks recordings
    /// started from the menu bar or by the detector too.
    @Published private(set) var isRecording = false
    /// The transcript line the playhead is inside. The playhead itself moves
    /// four times a second; republishing that would redraw every row each
    /// tick, where this changes only when the spoken line does.
    @Published private(set) var activeSegmentID: Int64?
    @Published private(set) var isExportingAudio = false
    @Published var audioExportError: String?

    /// Speaker id to position in `speakers`. Every transcript row looks up its
    /// speaker twice to draw, so a linear scan per row shows up on long
    /// meetings.
    private var speakerIndex: [Int64: Int] = [:]

    let store: MeetingStore
    weak var controller: MeetingsController?
    private var changeObserver: NSObjectProtocol?
    let playback = MeetingPlayback()
    private var positionObserver: AnyCancellable?

    init(store: MeetingStore, controller: MeetingsController) {
        self.store = store
        self.controller = controller
        changeObserver = NotificationCenter.default.addObserver(
            forName: .grumbleMeetingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        positionObserver = playback.$positionMs.sink { [weak self] ms in
            self?.updateActiveSegment(at: ms)
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
        isRecording = controller?.isRecording ?? false
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
            selectedHasAudio = false
            playback.unload()
            return
        }
        speakers = (try? store.speakers(meetingId: selectedID)) ?? []
        segments = (try? store.segments(meetingId: selectedID)) ?? []
        if let meeting = selected {
            selectedHasAudio = Self.hasAudio(meeting)
            playback.load(meeting: meeting)
        }
    }

    /// Nothing is highlighted until playback has moved off the start, so a
    /// meeting that is merely selected doesn't sit there with its first line
    /// lit up.
    private func updateActiveSegment(at positionMs: Int) {
        var id: Int64?
        if playback.isPlaying || positionMs > 0 {
            id = segments.last { $0.startMs <= positionMs && positionMs < $0.endMs }?.id
        }
        if id != activeSegmentID { activeSegmentID = id }
    }

    /// A meeting still being recorded has half-written tracks, so it does not
    /// count as exportable yet.
    private static func hasAudio(_ meeting: Meeting) -> Bool {
        guard meeting.state != .recording else { return false }
        let dir = MeetingSession.meetingsRoot().appendingPathComponent(meeting.audioDir)
        return ["mic.caf", "system.caf"].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    func speakerLabel(for id: Int64) -> String {
        guard let index = speakerIndex[id] else { return "Speaker" }
        return speakers[index].label
    }

    func speakerColor(for id: Int64) -> Color {
        guard let index = speakerIndex[id] else { return .secondary }
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

    /// Write the meeting out as one mixed m4a, the same stitched timeline the
    /// player uses, so the file matches what playback sounds like.
    func exportAudio(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = meeting.displayTitle + ".m4a"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExportingAudio = true
        let audioDir = meeting.audioDir
        Task {
            let error = await MeetingPlayback.exportMix(audioDir: audioDir, to: url)
            isExportingAudio = false
            audioExportError = error
        }
    }

    /// Start or stop a recording from the window. A recording started here
    /// gets selected, so the meeting being recorded is what is on screen.
    func toggleRecording() {
        guard let controller else { return }
        let wasRecording = controller.isRecording
        controller.toggleRecording()
        refresh()
        if !wasRecording, controller.isRecording, let newest = meetings.first?.id {
            selectedID = newest
            loadDetail()
        }
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
    @Published private(set) var isPlaying = false
    /// Where the playhead is, and how long the mix runs, both in milliseconds.
    /// They are tracked even before the player exists so the transport bar can
    /// show a position and accept a scrub on a meeting that has never played.
    @Published private(set) var positionMs = 0
    @Published private(set) var durationMs = 0
    private var player: AVPlayer?
    /// The showing meeting, whose audio has not been parsed yet.
    private var pendingDir: String?
    private var isPreparing = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Set while a drag is in flight: the periodic observer would otherwise
    /// keep yanking the playhead back to where the audio still is.
    private var isScrubbing = false

    /// Note which meeting is showing without touching its audio. Building the
    /// composition has to parse both track files, which is far too slow to do
    /// while someone is arrowing down the meeting list; the work is deferred
    /// to the first play instead.
    func load(meeting: Meeting) {
        guard meeting.audioDir != pendingDir else { return }
        unload()
        pendingDir = meeting.audioDir
        // The recorded duration stands in until the composition is built and
        // reports the real one.
        durationMs = meeting.durationSeconds * 1000
    }

    func playFrom(ms: Int) {
        positionMs = ms
        if let player {
            player.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000))
            player.play()
            isPlaying = true
            return
        }
        guard let dir = pendingDir, !isPreparing else { return }
        isPreparing = true
        Task {
            let prepared = await Self.makePlayer(audioDir: dir)
            isPreparing = false
            // The selection may have moved on while the audio was loading.
            guard pendingDir == dir else { return }
            player = prepared
            guard let prepared else { return }
            observe(prepared)
            if let item = prepared.currentItem,
                let duration = try? await item.asset.load(.duration), duration.isNumeric
            {
                durationMs = Int(duration.seconds * 1000)
            }
            _ = await prepared.seek(to: CMTime(value: CMTimeValue(ms), timescale: 1000))
            prepared.play()
            isPlaying = true
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            // Play on a finished mix starts over rather than replaying the
            // last instant of it.
            playFrom(ms: positionMs >= durationMs ? 0 : positionMs)
        }
    }

    /// Drag the playhead. Nothing reaches the player until the drag ends, and
    /// a scrub before the first play just moves `positionMs`, which is where
    /// the next play begins.
    func beginScrub() {
        isScrubbing = true
    }

    func scrub(toMs ms: Int) {
        positionMs = ms
    }

    func endScrub() {
        isScrubbing = false
        player?.seek(to: CMTime(value: CMTimeValue(positionMs), timescale: 1000))
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Stop and release the player but keep track of which meeting is
    /// showing, so reopening the window can start playback again without
    /// needing the selection to change first.
    func stop() {
        player?.pause()
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player = nil
        isPlaying = false
    }

    func unload() {
        stop()
        pendingDir = nil
        positionMs = 0
        durationMs = 0
    }

    /// Follow the playhead for the transport bar, and reset it when the mix
    /// runs out so the play button does not sit there claiming to be playing.
    private func observe(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.positionMs = max(0, Int(time.seconds * 1000))
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.positionMs = self?.durationMs ?? 0
            }
        }
    }

    private static func makePlayer(audioDir: String) async -> AVPlayer? {
        guard let composition = await mixedComposition(audioDir: audioDir) else { return nil }
        return AVPlayer(playerItem: AVPlayerItem(asset: composition))
    }

    /// Stitches the mic and system tracks back onto one timeline. The awaits
    /// are what matter: `loadTracks` and `load(.duration)` demux the file on
    /// their own queues, so the main thread stays free while they run.
    private static func mixedComposition(audioDir: String) async -> AVComposition? {
        let dir = MeetingSession.meetingsRoot().appendingPathComponent(audioDir)
        let meta = MeetingSessionMeta.load(from: dir)
        let composition = AVMutableComposition()
        for (file, key) in [("mic.caf", "mic"), ("system.caf", "system")] {
            let url = dir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let offsetMs = meta?.startOffsetMs[key] ?? 0
            try? track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetTrack,
                at: CMTime(value: CMTimeValue(offsetMs), timescale: 1000)
            )
        }
        guard !composition.tracks.isEmpty else { return nil }
        return composition
    }

    /// Write the mix out as an m4a. Returns nil on success, or a message to
    /// show when it fails.
    static func exportMix(audioDir: String, to url: URL) async -> String? {
        guard let composition = await mixedComposition(audioDir: audioDir) else {
            return "This meeting has no audio left on this Mac."
        }
        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else {
            return "Could not start the export."
        }
        // The save panel has already taken the user's overwrite confirmation,
        // but the export refuses to write over an existing file itself.
        try? FileManager.default.removeItem(at: url)
        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: url, as: .m4a)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        session.outputURL = url
        session.outputFileType = .m4a
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            return session.error?.localizedDescription ?? "The export failed."
        }
        return nil
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
                    model.toggleRecording()
                } label: {
                    Label(
                        model.isRecording ? "Stop Recording" : "Record Meeting",
                        systemImage: model.isRecording ? "stop.fill" : "record.circle"
                    )
                    .foregroundStyle(model.isRecording ? Color.red : Color.primary)
                }
                .help(
                    model.isRecording
                        ? "Stop recording and start transcribing"
                        : "Start recording a meeting")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Meeting Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showingSettings) {
                    MeetingSettingsView()
                }
                .help("Meeting settings")
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
                    + "or start one yourself."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            Button(model.isRecording ? "Stop Recording" : "Record a Meeting") {
                model.toggleRecording()
            }
            .padding(.top, 4)
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

/// Pinned above the transcript so the playhead stays reachable from anywhere
/// in a long one. It observes the player directly: the position ticks four
/// times a second, and nothing else should redraw for that.
struct TransportBar: View {
    @ObservedObject var playback: MeetingPlayback

    var body: some View {
        let total = max(playback.durationMs, 1)
        return HStack(spacing: 12) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(playback.isPlaying ? "Pause" : "Play")
            stamp(playback.positionMs, of: total)
            Slider(
                value: Binding(
                    get: { Double(playback.positionMs) },
                    set: { playback.scrub(toMs: Int($0)) }
                ),
                in: 0...Double(total)
            ) { editing in
                if editing {
                    playback.beginScrub()
                } else {
                    playback.endScrub()
                }
            }
            .help("Scrub through the recording")
            stamp(total, of: total)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Both readouts are formatted against the total, so the elapsed side
    /// doesn't switch shape (and resize the slider) on the way past an hour.
    private func stamp(_ ms: Int, of totalMs: Int) -> some View {
        let seconds = max(0, ms / 1000)
        let text =
            totalMs >= 3_600_000
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

struct MeetingDetailView: View {
    @ObservedObject var model: MeetingsViewModel
    let meeting: Meeting
    @State private var editedTitle: String = ""
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedHasAudio {
                TransportBar(playback: model.playback)
                Divider()
            }
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.copyTranscript(meeting)
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(model.segments.isEmpty)
                .help("Copy the transcript as markdown")
                Button {
                    model.exportMarkdown(meeting)
                } label: {
                    Label("Export Markdown", systemImage: "square.and.arrow.up")
                }
                .disabled(model.segments.isEmpty)
                .help("Save the transcript as a markdown file")
                Button {
                    model.exportAudio(meeting)
                } label: {
                    if model.isExportingAudio {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export Audio", systemImage: "waveform")
                    }
                }
                .disabled(!model.selectedHasAudio || model.isExportingAudio)
                .help(model.isExportingAudio ? "Exporting audio" : "Save the recording as an m4a file")
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this meeting and its recording")
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
        .alert(
            "Audio Export Failed",
            isPresented: Binding(
                get: { model.audioExportError != nil },
                set: { if !$0 { model.audioExportError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.audioExportError ?? "")
        }
        .onAppear { editedTitle = meeting.title ?? "" }
        .onChange(of: meeting.id) { editedTitle = meeting.title ?? "" }
    }

    private var detail: some View {
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
            Text("Transcript")
                .font(.headline)
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
            // Lazy: a long meeting runs to a couple of thousand segments, and
            // a plain VStack would build and lay out every row before the
            // first frame can be shown.
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.segments) { segment in
                    SegmentRow(model: model, segment: segment)
                }
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
    @State private var autoStop = MeetingDetector.stopsAutomatically
    @State private var retention = MeetingAudioRetention.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Detect meetings automatically", isOn: $autoDetect)
                .onChange(of: autoDetect) { MeetingDetector.isEnabled = autoDetect }

            Toggle("Stop recording when the meeting ends", isOn: $autoStop)
                .onChange(of: autoStop) { MeetingDetector.stopsAutomatically = autoStop }

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

    private var isSpeaking: Bool {
        segment.id != nil && segment.id == model.activeSegmentID
    }

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
        // Negative padding so the highlight is wider than the text without
        // moving the text itself as it comes and goes.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSpeaking ? Color.accentColor.opacity(0.18) : .clear)
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        )
        .animation(.easeInOut(duration: 0.15), value: isSpeaking)
        .help("Click to play from here")
    }

    static func stamp(_ ms: Int) -> String {
        let seconds = ms / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
