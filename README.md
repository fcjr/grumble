# Grumble

Local, on-device dictation for macOS. Press **⌥+Space**, talk, and watch your
words stream live into whatever text field has focus. Press **⌥+Space** again to
stop. All transcription happens on-device via
[FluidAudio](https://github.com/FluidInference/FluidAudio) and NVIDIA's
Parakeet models running on CoreML — no audio ever leaves your Mac.

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
