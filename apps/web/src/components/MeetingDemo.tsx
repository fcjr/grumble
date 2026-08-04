import { useEffect, useRef, useState } from "react";

type Line = { speaker: string; you?: boolean; time: string; text: string };

const TITLE = "Q3 Roadmap Sync";

const LINES: Line[] = [
  { speaker: "You", you: true, time: "00:04", text: "so we're cutting the migration from this quarter" },
  { speaker: "Dana", time: "00:09", text: "and moving it where, exactly" },
  { speaker: "You", you: true, time: "00:12", text: "next quarter. obviously." },
  { speaker: "Marcus", time: "00:16", text: "that is what we said last quarter" },
];

const SUMMARY =
  "Migration slips to Q4. Dana owns the timeline doc, Marcus remains unconvinced.";

type Phase = "recording" | "processing" | "done";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const BARS = [0.4, 0.75, 1, 0.55, 0.85, 0.35, 0.7, 0.95, 0.5, 0.8, 0.45, 0.65];

export function MeetingDemo() {
  const [phase, setPhase] = useState<Phase>("recording");
  const [elapsed, setElapsed] = useState(0);
  const [revealed, setRevealed] = useState(0);
  const [summarized, setSummarized] = useState(false);
  const runToken = useRef(0);
  const instant = useRef(false);

  const run = async () => {
    const token = ++runToken.current;
    const alive = () => runToken.current === token;
    do {
      if (instant.current) {
        setPhase("done");
        setElapsed(18);
        setRevealed(LINES.length);
        setSummarized(true);
        return;
      }
      setPhase("recording");
      setElapsed(0);
      setRevealed(0);
      setSummarized(false);
      for (let s = 1; s <= 18; s++) {
        await sleep(90);
        if (!alive()) return;
        setElapsed(s);
      }
      await sleep(400);
      if (!alive()) return;
      setPhase("processing");
      await sleep(1400);
      if (!alive()) return;
      setPhase("done");
      for (let i = 1; i <= LINES.length; i++) {
        await sleep(520);
        if (!alive()) return;
        setRevealed(i);
      }
      await sleep(700);
      if (!alive()) return;
      setSummarized(true);
      await sleep(4200);
    } while (alive());
  };

  useEffect(() => {
    instant.current = window.matchMedia(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    run();
    return () => {
      runToken.current++;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const recording = phase === "recording";
  const clock = `0:${String(elapsed).padStart(2, "0")}`;

  return (
    <button
      type="button"
      onClick={run}
      className="group w-full cursor-pointer rounded-2xl border border-white/8 bg-faceplate p-6 text-left transition-colors hover:border-amber/25 focus-visible:border-amber/40 focus-visible:outline-none"
    >
      <div className="flex items-center justify-between gap-4 border-b border-white/8 pb-4">
        <span className="flex items-center gap-2.5">
          <span
            className={`h-2.5 w-2.5 rounded-full transition-colors ${
              recording ? "rec-dot-live bg-needle" : "bg-white/15"
            }`}
          />
          <span
            className={`panel-label text-sm transition-colors ${
              recording ? "text-needle" : "text-bone-dim"
            }`}
          >
            {phase === "recording"
              ? "Recording · Zoom"
              : phase === "processing"
                ? "Transcribing"
                : TITLE}
          </span>
        </span>
        <span className="font-mono text-sm text-bone-dim">{clock}</span>
      </div>

      <div className="min-h-56 py-4">
        {recording ? (
          <div className="flex min-h-48 items-center justify-center gap-2">
            {BARS.map((scale, i) => (
              <span
                key={i}
                className="level-bar w-2 rounded-full bg-amber/70"
                style={{
                  height: `${(scale * 6).toFixed(2)}rem`,
                  animationDelay: `${i * 0.09}s`,
                }}
              />
            ))}
          </div>
        ) : phase === "processing" ? (
          <div className="flex min-h-48 flex-col items-center justify-center gap-3">
            <span className="h-1 w-40 overflow-hidden rounded-full bg-white/8">
              <span className="progress-sweep block h-full w-1/3 rounded-full bg-amber" />
            </span>
            <span className="panel-label text-xs text-bone-dim">
              Two tracks · separating speakers
            </span>
          </div>
        ) : (
          <div className="space-y-3">
            {LINES.slice(0, revealed).map((line) => (
              <div key={line.time} className="line-in flex gap-3 text-sm">
                <span className="w-11 shrink-0 pt-0.5 font-mono text-xs text-bone-dim/70">
                  {line.time}
                </span>
                <span>
                  <span
                    className={`panel-label mr-2 text-xs ${
                      line.you ? "text-amber" : "text-bone"
                    }`}
                  >
                    {line.speaker}
                  </span>
                  <span className="leading-relaxed text-bone-dim">
                    {line.text}
                  </span>
                </span>
              </div>
            ))}
            {summarized && (
              <p className="line-in mt-4 border-l-2 border-amber/40 pl-3 text-sm leading-relaxed text-bone-dim">
                <span className="panel-label mr-2 text-xs text-amber">
                  Summary
                </span>
                {SUMMARY}
              </p>
            )}
          </div>
        )}
      </div>

      <div className="flex items-center justify-between gap-2 border-t border-white/8 pt-4 text-xs text-bone-dim">
        <span className="panel-label">On-device · mic + system audio</span>
        <span className="panel-label text-amber-dim transition-colors group-hover:text-amber">
          Replay
        </span>
      </div>
    </button>
  );
}
