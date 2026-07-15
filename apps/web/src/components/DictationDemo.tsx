import { useEffect, useRef, useState } from "react";
import { Mark } from "./Mark";

type Op = { erase?: number; text: string; pause?: number };

const UTTERANCES: Op[][] = [
  [
    { text: "okay remind me to " },
    { text: "by", pause: 300 },
    {
      erase: 2,
      text: "buy oat milk, espresso beans, and whatever cheese looks the most dramatic",
    },
  ],
  [
    { text: "tell the group chat " },
    { text: "their", pause: 320 },
    { erase: 5, text: "they're going to love this" },
  ],
  [
    { text: "the meeting could have been " },
    { text: "a male", pause: 340 },
    { erase: 6, text: "an email. the email could have been a grumble" },
  ],
  [
    { text: "note to self: stop saying note to self " },
    { text: "aloud", pause: 320 },
    { erase: 5, text: "out loud" },
  ],
  [{ text: "dear diary, today I talked to my computer and it actually listened" }],
];

type Status = "standby" | "listening" | "done";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function charDelay(ch: string) {
  if (ch === "." || ch === ":") return 180;
  if (ch === ",") return 120;
  if (ch === " ") return 30 + Math.random() * 50;
  return 20 + Math.random() * 35;
}

function finalText(ops: Op[]) {
  return ops.reduce((t, op) => (op.erase ? t.slice(0, -op.erase) : t) + op.text, "");
}

export function DictationDemo() {
  const [text, setText] = useState("");
  const [status, setStatus] = useState<Status>("standby");
  const [pressed, setPressed] = useState(false);
  const runToken = useRef(0);
  const nextUtterance = useRef(Math.floor(Math.random() * UTTERANCES.length));
  const instant = useRef(false);

  const run = async () => {
    const token = ++runToken.current;
    const alive = () => runToken.current === token;
    const press = async () => {
      setPressed(true);
      await sleep(240);
      if (alive()) setPressed(false);
    };
    do {
      const ops = UTTERANCES[nextUtterance.current++ % UTTERANCES.length];
      if (instant.current) {
        setText(finalText(ops));
        setStatus("done");
        return;
      }
      setText("");
      setStatus("standby");
      await sleep(900);
      if (!alive()) return;
      await press();
      if (!alive()) return;
      setStatus("listening");
      await sleep(400);
      for (const op of ops) {
        if (op.erase) {
          await sleep(160);
          for (let i = 0; i < op.erase; i++) {
            if (!alive()) return;
            setText((t) => t.slice(0, -1));
            await sleep(18);
          }
        }
        for (const ch of op.text) {
          if (!alive()) return;
          setText((t) => t + ch);
          await sleep(charDelay(ch));
        }
        if (op.pause) await sleep(op.pause);
      }
      if (!alive()) return;
      await sleep(300);
      await press();
      if (!alive()) return;
      setStatus("done");
      await sleep(3200);
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

  const listening = status === "listening";

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
              listening ? "rec-dot-live bg-needle" : "bg-white/15"
            }`}
          />
          <span
            className={`panel-label text-sm transition-colors ${
              listening ? "text-needle" : "text-bone-dim"
            }`}
          >
            {status === "listening"
              ? "Listening"
              : status === "done"
                ? "Transcribed"
                : "Standby"}
          </span>
        </span>
        <Mark className={`h-6 w-8 ${listening ? "demo-live" : ""}`} />
      </div>

      <div className="min-h-32 py-4 font-mono text-base leading-relaxed text-bone">
        {text}
        <span
          className={`demo-cursor -mb-0.5 inline-block h-5 w-0.5 align-baseline ${
            listening ? "bg-amber" : "bg-bone-dim/50"
          }`}
        />
      </div>

      <div className="flex items-center gap-1.5 border-t border-white/8 pt-4 text-sm text-bone-dim">
        <span className={`keycap ${pressed ? "keycap-pressed" : ""}`}>⌥</span>
        <span>+</span>
        <span className={`keycap ${pressed ? "keycap-pressed" : ""}`}>
          Space
        </span>
      </div>
    </button>
  );
}
