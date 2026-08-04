import { Link, createFileRoute } from "@tanstack/react-router";
import { Mark } from "../components/Mark";

export const Route = createFileRoute("/support")({
  component: Support,
});

const REPO = "https://github.com/fcjr/grumble";
const SUPPORT_EMAIL = "support@grumble.computer";

const FAQS = [
  {
    question: "Dictation starts, but nothing gets typed.",
    answer:
      "Grumble needs accessibility access to type into the focused text field. Open System Settings, go to Privacy & Security, then Accessibility, and make sure Grumble is enabled. If it is already enabled and still not working, toggle it off and back on, then restart Grumble.",
  },
  {
    question: "The hotkey does not do anything.",
    answer:
      "The default hotkey is ⌥+Space. Another app may have claimed it; you can change Grumble's hotkey from the menu bar icon under Settings. Also check that Grumble is running: you should see its icon in the menu bar.",
  },
  {
    question: "Does my audio ever leave my Mac?",
    answer:
      "No. Dictation and meeting transcription both run entirely on-device using local models. Dictation audio is processed in memory and never written to disk. Meeting recordings are saved on your Mac, under Application Support, and are never sent anywhere. See the privacy policy for details.",
  },
  {
    question: "How do I record a meeting?",
    answer:
      "Usually you do not have to do anything: when a meeting app such as Zoom, Teams, Webex, Slack, Discord, or FaceTime starts using your microphone, Grumble begins recording on its own. Browser meetings, like Google Meet, send a notification asking first. You can also start and stop a recording yourself from the menu bar icon with Record Meeting.",
  },
  {
    question: "Grumble says it could not start the meeting recording.",
    answer:
      "Recording a meeting captures the other side of the call through system audio, which needs its own permission. Open System Settings, go to Privacy & Security, then Screen & System Audio Recording, enable Grumble, and restart the app. Meeting recording also requires macOS 14.4 or later.",
  },
  {
    question: "How do I stop Grumble from recording certain apps?",
    answer:
      "Open Meetings… from the menu bar icon and go to Meeting Settings. Each detected app can be set to record automatically, ask first, or never record. To turn detection off completely, uncheck Auto-Record Meetings in the menu bar or Detect meetings automatically in Meeting Settings.",
  },
  {
    question: "Where do meeting recordings live, and how do I delete them?",
    answer:
      "Audio is written to ~/Library/Application Support/Grumble/Meetings and transcripts go into a local database beside it. Any meeting can be removed with Delete Meeting and Audio in the Meetings window. Under Meeting Settings, Keep raw audio decides whether recordings are kept forever, aged out after 7 or 30 days, or deleted as soon as the transcript is ready. Transcripts and summaries stay until you delete the meeting.",
  },
  {
    question: "Why do meeting titles and summaries need another download?",
    answer:
      "Summaries are optional and use a separate local language model, roughly 2.3 GB, which is only downloaded when you turn them on from the Meetings window. Transcripts with speaker labels work without it. Once downloaded, summarization runs offline like everything else.",
  },
  {
    question: "Why does Grumble download something on first launch?",
    answer:
      "The speech model is downloaded once from Hugging Face on first launch (or when you switch models). After that, dictation works fully offline.",
  },
  {
    question: "What Macs does Grumble support?",
    answer:
      "Grumble requires macOS 14 or later on Apple Silicon (M1 or newer). Intel Macs are not supported. Meeting recording additionally needs macOS 14.4 or later, which is where the system audio capture it relies on was introduced.",
  },
  {
    question: "How do I update Grumble?",
    answer:
      "The direct-download version checks for updates automatically and can update itself from the menu bar. The Mac App Store version is updated through the App Store like any other app.",
  },
] as const;

function Support() {
  return (
    <div className="min-h-screen">
      <header className="mx-auto flex max-w-5xl items-center justify-between px-6 py-6">
        <Link to="/" className="flex items-center gap-3">
          <Mark className="h-7 w-9" />
          <span className="panel-label text-lg text-bone">Grumble</span>
        </Link>
        <a
          href={REPO}
          className="panel-label text-sm text-bone-dim transition-colors hover:text-amber focus-visible:text-amber"
        >
          GitHub
        </a>
      </header>

      <main className="mx-auto max-w-3xl px-6 pb-24">
        <section className="py-16">
          <p className="panel-label mb-4 text-sm text-amber">Support</p>
          <h1 className="panel-label text-5xl leading-none text-bone">
            Something not working?
          </h1>
          <p className="mt-6 max-w-xl text-lg leading-relaxed text-bone-dim">
            Check the answers below first. If you are still stuck, email{" "}
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              {SUPPORT_EMAIL}
            </a>{" "}
            and a human will get back to you.
          </p>
        </section>

        <section className="grid gap-4">
          {FAQS.map((faq) => (
            <div
              key={faq.question}
              className="rounded-2xl border border-white/8 bg-faceplate p-6"
            >
              <h2 className="panel-label mb-3 text-lg text-bone">
                {faq.question}
              </h2>
              <p className="text-sm leading-relaxed text-bone-dim">
                {faq.answer}
              </p>
            </div>
          ))}
        </section>

        <section className="mt-8 rounded-2xl border border-white/8 bg-faceplate px-6 py-5">
          <p className="text-center text-sm text-bone-dim">
            Found a bug? Email{" "}
            <a
              href={`mailto:${SUPPORT_EMAIL}`}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              {SUPPORT_EMAIL}
            </a>{" "}
            or{" "}
            <a
              href={`${REPO}/issues`}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              open an issue on GitHub
            </a>
            .
          </p>
        </section>
      </main>

      <footer className="border-t border-white/8">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-2 px-6 py-6 text-xs text-bone-dim">
          <span>© 2026 Left Shift Logical, LLC</span>
          <span>
            Built on{" "}
            <a
              href="https://github.com/FluidInference/FluidAudio"
              className="text-amber-dim transition-colors hover:text-amber"
            >
              FluidAudio
            </a>{" "}
            and NVIDIA Parakeet
          </span>
        </div>
      </footer>
    </div>
  );
}
