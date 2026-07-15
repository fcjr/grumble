# Grumble

Local, on-device dictation for macOS. Press **⌥+Space**, talk, and watch your
words stream live into whatever text field has focus. Press **⌥+Space** again to
stop. All transcription happens on-device via
[FluidAudio](https://github.com/FluidInference/FluidAudio) and NVIDIA's
Parakeet models running on CoreML — no audio ever leaves your Mac.

## Install

Requires macOS 14+. Install with [Homebrew](https://brew.sh):

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

## Building

Requires macOS 14+, Xcode, [xcodegen](https://github.com/yonaskolb/XcodeGen),
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

## Releasing

Push a tag like `v0.2.0` and CI does the rest: builds and signs the app
(version taken from the tag), notarizes the DMG, uploads the DMG and the
Sparkle update zip to a GitHub release, publishes the Homebrew cask to
[fcjr/homebrew-fcjr](https://github.com/fcjr/homebrew-fcjr), regenerates the
signed appcast at `grumble.computer/desktop/darwin/appcast.xml`, commits it
together with the flake's `nix/version.json` pin, and redeploys the site.

The same tag also builds the Mac App Store variant (`GrumbleAppStore`
target: sandboxed, no Sparkle — the store owns updates) and uploads it to
App Store Connect. Signing is cloud-managed: the export re-signs the archive
with an Apple Distribution certificate and provisioning profile created on
demand through the App Store Connect API key, which therefore needs the App
Manager role. The upload only delivers the build; attach it to a version and
submit for review in App Store Connect. To upload from a local machine
instead: `APP_STORE_CONNECT_KEY_FILE=/path/to/AuthKey.p8
APP_STORE_CONNECT_KEY_ID=… APP_STORE_CONNECT_ISSUER_ID=… just appstore`.

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
