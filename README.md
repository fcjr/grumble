# Grumble

Local, on-device dictation for macOS. Press **⌥+Space**, talk, and watch your
words stream live into whatever text field has focus. Press **⌥+Space** again to
stop. All transcription happens on-device via
[FluidAudio](https://github.com/FluidInference/FluidAudio) and NVIDIA's
Parakeet models running on CoreML — no audio ever leaves your Mac.

Grumble also records meetings: it detects when Zoom, Teams, or a browser
meeting is using your microphone, records both sides of the call, and produces
a speaker-tagged transcript with an optional local-LLM title and summary. See
[Meetings](#meetings).

## Install

Requires macOS 14.4+. Install with [Homebrew](https://brew.sh):

```sh
brew install --cask fcjr/fcjr/grumble
```

Or download [Grumble.dmg](https://github.com/fcjr/grumble/releases/latest/download/Grumble.dmg)
from the [latest release](https://github.com/fcjr/grumble/releases/latest) and
drag Grumble to Applications.

Or with [Nix](https://nixos.org) flakes:

```sh
nix profile install github:fcjr/grumble
```

Or in a [nix-darwin](https://github.com/nix-darwin/nix-darwin) or
[home-manager](https://github.com/nix-community/home-manager) flake config,
add the input and package:

```nix
{
  inputs.grumble.url = "github:fcjr/grumble";

  # then, in a nix-darwin module (links the app into /Applications/Nix Apps):
  { pkgs, inputs, ... }: {
    environment.systemPackages = [
      inputs.grumble.packages.${pkgs.system}.default
    ];
  }

  # or in a home-manager module:
  { pkgs, inputs, ... }: {
    home.packages = [ inputs.grumble.packages.${pkgs.system}.default ];
  }
}
```

Nix installs are updated through Nix, not Sparkle: Grumble detects that it's
running from the Nix store and disables the in-app updater (the store is
read-only), so update by bumping the flake input (`nix flake update grumble`).

## How it works

- A menu bar app (no Dock icon) registers a global ⌥+Space hotkey
  (customizable via menu bar icon → Change Hotkey…).
- While listening, microphone audio is fed to FluidAudio's streaming ASR
  engine (Parakeet Unified 0.6B by default — a true streaming variant of the
  Parakeet TDT 0.6B model with live partial token updates).
- Partial transcripts are typed into the focused text field as you speak.
  When the model revises earlier words, only the changed suffix is
  backspaced and retyped.

## Meetings

Grumble can record meetings and turn them into speaker-tagged transcripts,
entirely on-device:

- **Detection** — when a meeting app (Zoom, Teams, Webex, Slack, Discord,
  FaceTime) starts using the microphone, recording starts automatically.
  Browsers (Google Meet lives there) ask first via a notification. Policies
  are per-app and configurable from the Meetings window; recording can also
  be started manually from the menu bar.
- **Capture** — two tracks: your microphone (with Apple's echo canceller, so
  speaker playback doesn't bleed in) and system audio via a CoreAudio process
  tap (macOS 14.4+, needs the one-time System Audio Recording permission).
  Audio lands in `~/Library/Application Support/Grumble/Meetings/`.
- **Transcription** — after the meeting, each track is transcribed with the
  offline Parakeet TDT model. The mic track is you; the system track is
  diarized with NVIDIA's streaming Sortformer so each remote speaker gets
  their own label. Everything is merged into one timeline in a local SQLite
  database (GRDB, append-only migrations).
- **Titles, summaries, and names** — optionally, a local Qwen3-4B model
  (opt-in ~2.3 GB download on first use, via MLX) writes a title and summary
  and names speakers from context clues. Auto-applied names are marked and
  always editable; your edits are never overwritten.
- **Browsing** — menu bar → Meetings… lists every meeting with full-text
  search, per-speaker transcript with click-to-play audio, markdown export,
  audio retention settings, and delete.

Nothing about a meeting ever leaves your Mac: capture, diarization,
transcription, and summarization all run locally.

## Building

Requires macOS 14.4+, Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen),
and [just](https://github.com/casey/just) (`brew install xcodegen just`).

```sh
just run     # generate project, build, and launch
just open    # generate project and open in Xcode
just clean   # remove generated project and build artifacts
```

## First run

1. **Model download** — on first launch the selected model (~600 MB for the
   0.6B Parakeet Unified) is downloaded from HuggingFace and cached. The menu
   bar icon shows a download indicator while this happens.
2. **Microphone** — you'll be prompted the first time you start dictation.
3. **Accessibility** — required so Grumble can type into other apps. macOS
   will prompt; enable Grumble under System Settings → Privacy & Security →
   Accessibility.
4. **System audio** — needed for meetings, so the far side of a call can be
   captured. The first recording triggers the prompt; enable Grumble under
   System Settings → Privacy & Security → Screen & System Audio Recording.
   Recording can't start without it.
5. **Summarization model** — optional, and only downloaded (~2.3 GB) when you
   turn on meeting summaries from the Meetings window.

## Releasing

Push a tag like `v0.2.0` and CI does the rest: builds and signs the app
(version taken from the tag), notarizes the DMG, uploads the DMG and the
Sparkle update zip to a GitHub release, publishes the Homebrew cask to
[fcjr/homebrew-fcjr](https://github.com/fcjr/homebrew-fcjr), regenerates the
signed appcast at `grumble.computer/desktop/darwin/appcast.xml`, commits it
together with the flake's `nix/version.json` pin, and redeploys the site.

The same tag also releases to the Mac App Store, end to end: CI builds the
`GrumbleAppStore` target (sandboxed, no Sparkle — the store owns updates),
uploads it, creates the store version, attaches the build once Apple
finishes processing it, sets What's New from the tag annotation (falling
back to a stock message), and submits for review; the version releases
automatically after approval. Signing is cloud-managed: the export re-signs
the archive with an Apple Distribution certificate created on demand
through the App Store Connect API key, which therefore needs Admin access
(App Manager alone cannot use cloud-managed certificates). To run the same
flow locally: `APP_STORE_CONNECT_KEY_FILE=/path/to/AuthKey.p8
APP_STORE_CONNECT_KEY_ID=… APP_STORE_CONNECT_ISSUER_ID=… just appstore
appstore-submit`.

Repository secrets used: `MACOS_CERTIFICATE_P12` (base64 Developer ID .p12),
`MACOS_CERTIFICATE_PASSWORD`, `APP_STORE_CONNECT_API_KEY` (.p8 contents),
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`SPARKLE_PRIVATE_KEY`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`RELEASER_APP_ID` and `RELEASER_APP_PRIVATE_KEY` (GitHub App with write
access to the tap).

## Models

Switch models from the menu bar icon → Model:

| Model | Latency | Notes |
|---|---|---|
| Parakeet Unified 320 ms | lowest | re-encodes often, highest CPU |
| Parakeet Unified 640 ms | low | same accuracy as 320 ms, cheaper |
| Parakeet Unified 1120 ms | medium | **default** — best accuracy/latency balance |
| Parakeet Unified 2080 ms | high | highest throughput |
| Parakeet EOU 120M 160 ms | lowest | tiny model, fastest |

All of FluidAudio's true-streaming variants are currently English-only. The
multilingual Parakeet TDT v3 model only supports offline/sliding-window
transcription, so it can't stream partial tokens live.

## License

Apache 2.0 — see [LICENSE](LICENSE). © 2026 Left Shift Logical, LLC.
