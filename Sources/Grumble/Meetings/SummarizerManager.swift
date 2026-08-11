import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Owns the opt-in summarization model (Qwen3.5-4B, 4-bit, ~3.1 GB). Meetings
/// work end to end without it - transcripts only - and the first summary
/// request offers the download. Once installed, the model loads at launch
/// and every finished meeting gets a title, summary, and speaker-name
/// proposals automatically.
@MainActor
final class SummarizerManager: ObservableObject {
    static let shared = SummarizerManager()

    static let modelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
    /// Records *which* model was installed, not just that one was. A plain
    /// bool would make everyone who installed an earlier model silently
    /// re-download the new one at launch, without the consent prompt.
    private static let installedModelKey = "meetingSummarizerInstalledModel"

    /// Grumble owns its model storage instead of inheriting the Hugging Face
    /// default (~/.cache/huggingface/hub, or wherever HF_HOME happens to
    /// point). Weights this big should sit somewhere the app can account for
    /// and prune, not in a shared cache it would never be safe to delete from.
    static let modelsDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Grumble/Models")

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled

    /// Set once loading succeeds; handed to the pipeline.
    private(set) var summarizer: QwenMeetingSummarizer?
    /// Called when the summarizer becomes available so the pipeline can be
    /// wired up.
    var onReady: ((QwenMeetingSummarizer) -> Void)?

    var isInstalled: Bool {
        UserDefaults.standard.string(forKey: Self.installedModelKey) == Self.modelID
    }

    /// Load the model at launch when it was installed previously.
    func loadIfInstalled() {
        guard isInstalled, summarizer == nil else { return }
        Task { await load() }
    }

    /// Download (first time) and load the model.
    func install() {
        guard state != .ready, summarizer == nil else { return }
        if case .downloading = state { return }
        Task { await load() }
    }

    private func load() async {
        state = isInstalled ? .downloading(1) : .downloading(0)
        do {
            let configuration = ModelConfiguration(
                id: Self.modelID, extraEOSTokens: ["<|im_end|>"])
            let hub = HubClient(cache: HubCache(cacheDirectory: Self.modelsDirectory))
            let container = try await loadModelContainer(
                from: #hubDownloader(hub),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(progress.fractionCompleted)
                    }
                })
            UserDefaults.standard.set(Self.modelID, forKey: Self.installedModelKey)
            let summarizer = QwenMeetingSummarizer(container: container)
            self.summarizer = summarizer
            state = .ready
            // Only once the replacement is known good, so a failed or
            // interrupted download never costs someone their working model.
            Self.pruneStaleModels()
            onReady?(summarizer)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Drop every model in our directory except the one in use. Covers both
    /// the "models--org--repo" layout used here and the nested "models/org/repo"
    /// tree that shipped up to 0.1.10, so upgrading reclaims the old weights
    /// rather than leaving a few gigabytes stranded forever.
    private static func pruneStaleModels() {
        let keep = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: modelsDirectory.path) else {
            return
        }
        for entry in entries where entry != keep && entry != ".metadata" {
            try? fm.removeItem(at: modelsDirectory.appendingPathComponent(entry))
        }
    }
}

/// Qwen3.5-4B behind the MeetingSummarizer interface: one structured-output
/// run per meeting producing a title, summary, and speaker-name proposals
/// from context clues.
final class QwenMeetingSummarizer: MeetingSummarizer {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func summarize(transcript: String, speakerLabels: [String]) async throws -> MeetingSummary {
        // Keep well inside the context window: drop the middle of very long
        // transcripts (openings carry introductions, endings carry wrap-ups
        // and action items).
        let capped = Self.cap(transcript, to: 24_000)

        let instructions = """
            You are a meeting-notes engine inside an app. You always respond with a single \
            JSON object and nothing else. No markdown, no headings, no commentary, no text \
            before or after the JSON.
            """

        let prompt = """
            Analyze this meeting transcript. Speakers are labeled Me (the computer's owner) \
            and Speaker 1, Speaker 2, and so on (other participants).

            \(capped)

            Respond with ONLY a JSON object in exactly this shape:
            {"title": "short specific meeting title, under 10 words",
             "summary": "2-5 sentences: what was discussed, decisions, action items",
             "speakers": {"Speaker 1": {"name": "RealName", "confident": true}}}

            The "speakers" object maps speaker labels (including "Me") to real names that are \
            clear from context clues such as introductions or being addressed by name. Omit \
            speakers whose names never appear. Set "confident" to true only when the name is \
            unambiguous.
            """

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 1200, temperature: 0.2),
            additionalContext: ["enable_thinking": false]
        )
        // Qwen3.5 reasons by default and its template only honours the
        // enable_thinking flag above, not Qwen3's /no_think token. Strip any
        // reasoning that slips through before parsing.
        let raw = try await session.respond(to: prompt)
        if ProcessInfo.processInfo.environment["GRUMBLE_DEBUG_LLM"] != nil {
            NSLog("Grumble: LLM raw response: %@", String(raw.prefix(4000)))
        }
        let cleaned = Self.stripThinking(raw)
        return try Self.parse(cleaned, speakerLabels: speakerLabels)
    }

    static func cap(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return head + "\n[... middle of transcript omitted ...]\n" + tail
    }

    static func stripThinking(_ text: String) -> String {
        guard let start = text.range(of: "<think>"),
            let end = text.range(of: "</think>")
        else { return text }
        var out = text
        out.removeSubrange(start.lowerBound..<end.upperBound)
        return out
    }

    /// Pull the first JSON object out of the response and map speaker labels
    /// ("Speaker 1", "Me") back to slots ('spk0', 'me').
    static func parse(_ text: String, speakerLabels: [String]) throws -> MeetingSummary {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
            start < end,
            let data = String(text[start...end]).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(
                domain: "Grumble", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "The model returned no usable JSON."])
        }

        let title = (object["title"] as? String ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let summary = (object["summary"] as? String ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)

        var proposals: [String: SpeakerNameProposal] = [:]
        if let speakers = object["speakers"] as? [String: Any] {
            for (label, value) in speakers {
                guard let dict = value as? [String: Any],
                    let name = dict["name"] as? String, !name.isEmpty
                else { continue }
                let confident = dict["confident"] as? Bool ?? false
                if let slot = slot(forLabel: label) {
                    proposals[slot] = SpeakerNameProposal(name: name, confident: confident)
                }
            }
        }

        guard !title.isEmpty || !summary.isEmpty else {
            throw NSError(
                domain: "Grumble", code: 21,
                userInfo: [NSLocalizedDescriptionKey: "The model returned an empty result."])
        }
        return MeetingSummary(title: title, summary: summary, speakerNames: proposals)
    }

    /// "Me" -> 'me', "Speaker N" -> 'spk(N-1)'.
    private static func slot(forLabel label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "me" { return "me" }
        if trimmed.lowercased().hasPrefix("speaker "),
            let n = Int(trimmed.dropFirst("speaker ".count)), n >= 1
        {
            return "spk\(n - 1)"
        }
        return nil
    }
}
