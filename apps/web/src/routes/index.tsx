import { Link, createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { DictationDemo } from "../components/DictationDemo";
import { Mark } from "../components/Mark";
import { MeetingDemo } from "../components/MeetingDemo";

export const Route = createFileRoute("/")({
  component: Landing,
});

const DOWNLOAD =
  "https://github.com/fcjr/grumble/releases/latest/download/Grumble.dmg";
const REPO = "https://github.com/fcjr/grumble";

const BREW_COMMAND = "brew install --cask fcjr/fcjr/grumble";

function BrewCommand() {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      aria-label="Copy Homebrew install command"
      onClick={() => {
        navigator.clipboard.writeText(BREW_COMMAND).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 2000);
        });
      }}
      className="group mt-4 flex flex-wrap items-center gap-3 rounded-xl border border-white/8 bg-faceplate px-4 py-2.5 text-left font-mono text-sm text-bone-dim transition-colors hover:border-amber/25 focus-visible:border-amber/25"
    >
      <span>
        <span className="select-none text-amber-dim">$ </span>
        {BREW_COMMAND}
      </span>
      <span className="panel-label text-xs text-amber-dim transition-colors group-hover:text-amber">
        {copied ? "Copied!" : "Copy"}
      </span>
    </button>
  );
}

function Landing() {
  return (
    <div className="min-h-screen">
      <header className="mx-auto flex max-w-5xl items-center justify-between px-6 py-6">
        <div className="flex items-center gap-3">
          <Mark className="h-7 w-9" />
          <span className="panel-label text-lg text-bone">Grumble</span>
        </div>
        <nav className="flex items-center gap-6">
          <a
            href="#meetings"
            className="panel-label text-sm text-bone-dim transition-colors hover:text-amber focus-visible:text-amber"
          >
            Meetings
          </a>
          <a
            href={REPO}
            className="panel-label text-sm text-bone-dim transition-colors hover:text-amber focus-visible:text-amber"
          >
            GitHub
          </a>
        </nav>
      </header>

      <main className="mx-auto max-w-5xl px-6">
        <section className="grid items-center gap-12 py-16 md:grid-cols-[1.1fr_1fr] md:py-24">
          <div>
            <p className="panel-label mb-4 text-sm text-amber">
              On-device dictation for macOS
            </p>
            <h1 className="panel-label text-6xl leading-none text-bone md:text-7xl">
              Grumble in.
              <br />
              Sentence out.
            </h1>
            <p className="mt-6 max-w-md text-lg leading-relaxed text-bone-dim">
              Press <span className="keycap">⌥+Space</span>, talk, and watch
              your words stream live into whatever text field has focus. All
              transcription happens on your Mac. No audio ever leaves it.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-4">
              <a
                href={DOWNLOAD}
                download
                className="panel-label rounded-xl bg-amber px-6 py-3 text-lg text-faceplate-deep transition-colors hover:bg-amber-hi focus-visible:bg-amber-hi"
              >
                Download for macOS
              </a>
              <span className="text-sm text-bone-dim">
                macOS 14+ · Apple Silicon
              </span>
            </div>
            <BrewCommand />
          </div>
          <DictationDemo />
        </section>

        <section className="grid gap-4 pb-16 md:grid-cols-3">
          {[
            {
              title: "Private by construction",
              body: "NVIDIA's Parakeet model runs on the Neural Engine via CoreML. Your voice is transcribed on-device. Nothing is sent anywhere, ever.",
            },
            {
              title: "Streams as you speak",
              body: "Words land in the text field while you're still talking. When the model revises, only the changed suffix is retyped. It's like watching yourself type, but faster.",
            },
            {
              title: "Works in every app",
              body: "Grumble types wherever your cursor is: editors, browsers, chat boxes, terminals. One hotkey to start and stop, changeable any time.",
            },
          ].map((feature) => (
            <div
              key={feature.title}
              className="rounded-2xl border border-white/8 bg-faceplate p-6 transition-[transform,border-color] duration-300 hover:-translate-y-1 hover:border-amber/25 motion-reduce:transition-none motion-reduce:hover:translate-y-0"
            >
              <h2 className="panel-label mb-3 text-lg text-bone">
                {feature.title}
              </h2>
              <p className="text-sm leading-relaxed text-bone-dim">
                {feature.body}
              </p>
            </div>
          ))}
        </section>

        <section
          id="meetings"
          className="grid items-center gap-12 border-t border-white/8 py-16 md:grid-cols-[1fr_1.1fr] md:py-24"
        >
          <div className="order-2 md:order-1">
            <MeetingDemo />
          </div>
          <div className="order-1 md:order-2">
            <p className="panel-label mb-4 text-sm text-amber">Meetings</p>
            <h2 className="panel-label text-5xl leading-none text-bone md:text-6xl">
              It takes
              <br />
              the notes too.
            </h2>
            <p className="mt-6 max-w-md text-lg leading-relaxed text-bone-dim">
              When Zoom, Teams, or a Meet tab picks up your microphone, Grumble
              starts recording. Both sides of the call, one speaker-tagged
              transcript, still nothing leaving your Mac.
            </p>
            <ul className="mt-8 space-y-4">
              {[
                {
                  title: "Starts without being asked",
                  body: "Meeting apps record automatically; browsers ask first. Every app has its own policy, and you can flip any of them off.",
                },
                {
                  title: "Knows who said what",
                  body: "Your mic and the system audio are captured as separate tracks, then the far side is split per speaker so the transcript reads like a script.",
                },
                {
                  title: "Titles and summaries, locally",
                  body: "An optional local model writes the title and summary and even guesses speaker names. Opt in once, run offline forever.",
                },
              ].map((item) => (
                <li key={item.title} className="border-l-2 border-amber/40 pl-4">
                  <h3 className="panel-label text-sm text-bone">
                    {item.title}
                  </h3>
                  <p className="mt-1.5 text-sm leading-relaxed text-bone-dim">
                    {item.body}
                  </p>
                </li>
              ))}
            </ul>
          </div>
        </section>

        <section className="mb-16 rounded-2xl border border-white/8 bg-faceplate px-6 py-5">
          <p className="text-center text-sm text-bone-dim">
            First launch downloads the speech model once (~600 MB), then
            Grumble works entirely offline. Meeting summaries are opt-in and
            pull down a second model only if you ask for them. Free and open
            source, so you can{" "}
            <a
              href={REPO}
              className="text-amber transition-colors hover:text-amber-hi"
            >
              read the code
            </a>
            .
          </p>
        </section>
      </main>

      <footer className="border-t border-white/8">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-2 px-6 py-6 text-xs text-bone-dim">
          <span>© 2026 Left Shift Logical, LLC</span>
          <span className="flex gap-4">
            <Link
              to="/support"
              className="text-amber-dim transition-colors hover:text-amber"
            >
              Support
            </Link>
            <Link
              to="/privacy"
              className="text-amber-dim transition-colors hover:text-amber"
            >
              Privacy
            </Link>
          </span>
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
