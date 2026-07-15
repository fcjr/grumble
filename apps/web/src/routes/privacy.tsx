import { Link, createFileRoute } from "@tanstack/react-router";
import { Mark } from "../components/Mark";

export const Route = createFileRoute("/privacy")({
  component: Privacy,
});

const REPO = "https://github.com/fcjr/grumble";

const SECTIONS = [
  {
    title: "No data collection",
    body: "Grumble does not collect, store, or transmit any personal data. There are no accounts, no analytics, no telemetry, and no third-party tracking of any kind.",
  },
  {
    title: "Your voice stays on your Mac",
    body: "Audio from your microphone is transcribed entirely on-device using a local speech model. Audio is processed in memory, is never written to disk, and never leaves your computer. Transcribed text is typed directly into the app you are using; Grumble keeps no copy of it.",
  },
  {
    title: "Network access",
    body: "Grumble connects to the network for exactly one purpose: downloading the speech model from Hugging Face on first launch (or when you switch models). The direct-download version also checks grumble.computer for app updates via Sparkle; the Mac App Store version does not, since the App Store handles updates. Neither request includes any personal information.",
  },
  {
    title: "Permissions",
    body: "Grumble asks for microphone access to hear you and accessibility access to type into the focused text field. Both are used only while dictation is active and only for those purposes.",
  },
] as const;

function Privacy() {
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
          <p className="panel-label mb-4 text-sm text-amber">Privacy policy</p>
          <h1 className="panel-label text-5xl leading-none text-bone">
            Nothing to see here. Literally.
          </h1>
          <p className="mt-6 max-w-xl text-lg leading-relaxed text-bone-dim">
            Grumble is built so that there is nothing to collect. Everything
            happens on your Mac.
          </p>
        </section>

        <section className="grid gap-4">
          {SECTIONS.map((section) => (
            <div
              key={section.title}
              className="rounded-2xl border border-white/8 bg-faceplate p-6"
            >
              <h2 className="panel-label mb-3 text-lg text-bone">
                {section.title}
              </h2>
              <p className="text-sm leading-relaxed text-bone-dim">
                {section.body}
              </p>
            </div>
          ))}
        </section>

        <section className="mt-8 rounded-2xl border border-white/8 bg-faceplate px-6 py-5">
          <p className="text-center text-sm text-bone-dim">
            Grumble is open source, so you can verify all of this yourself:{" "}
            <a
              href={REPO}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              read the code
            </a>
            . Questions? Open an issue on GitHub.
          </p>
        </section>

        <p className="mt-8 text-center text-xs text-bone-dim">
          Last updated July 15, 2026
        </p>
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
