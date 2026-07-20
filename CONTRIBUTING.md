# Contributing to Waves

Thanks for your interest in improving Waves! It's a native macOS per-app audio
mixer built with Swift 6 and SwiftUI, using Core Audio process taps.

## Getting set up

- macOS 14.2 or newer and a recent Xcode toolchain (Swift 6).
- Build and run:
  ```bash
  ./script/build_and_run.sh
  ```
- Run the tests:
  ```bash
  swift test
  ```
- Validate a signed bundle + DMG locally:
  ```bash
  ./script/build_and_run.sh --release-check
  ```

## Before opening a pull request

- `swift build`, `swift test`, and `./script/build_and_run.sh --release-check`
  should all pass.
- Keep changes focused; prefer small, reviewable PRs.
- Cover logic changes with tests where practical. The realtime sample math
  lives in `WavesAudioCore/Audio/TapDSP.swift` and is unit-tested — please keep
  it that way.
- Match the surrounding code style (2-space indentation, no trailing
  whitespace).

## Design principles

Waves aims to feel like a built-in macOS utility. Please keep changes aligned
with [`docs/DESIGN.md`](docs/DESIGN.md) and
[`docs/PRODUCT.md`](docs/PRODUCT.md):

- **Native and quiet.** Prefer standard controls and system materials over
  custom chrome; reserve the cyan accent for live signal and actions.
- **Honest routing.** Never imply control the app doesn't actually have. Surface
  visible / monitored / managed states truthfully.
- **Dense but accessible.** Maintain keyboard operation, VoiceOver labels, and
  Reduce Motion support.

## Touching Core Audio

Changes to `WorkspaceAudioControlBackend.swift` (process taps, aggregate
devices, the IO render path) are the highest-risk area. Please test on real
hardware and describe what you verified, especially around device switching and
app termination.
