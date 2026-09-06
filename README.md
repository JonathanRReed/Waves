# Waves

[![CI](https://github.com/JonathanRReed/Waves/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/JonathanRReed/Waves/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/JonathanRReed/Waves?label=release)](https://github.com/JonathanRReed/Waves/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Control each Mac app's volume, mute, boost, equalizer, and output device. Waves uses Core Audio process taps on macOS 14.2+, with no virtual audio driver or system extension.

Version [1.7.1 build 19](https://github.com/JonathanRReed/Waves/releases/tag/v1.7.1) is published. Release builds support Apple Silicon and Intel. Source changes on `main` are not automatically part of that release.

## Install

Download the signed and notarized `Waves.dmg` from [Releases](https://github.com/JonathanRReed/Waves/releases/latest), open it, and drag Waves to Applications. Or use [the Homebrew tap](https://github.com/JonathanRReed/homebrew-tap):

```bash
brew install --cask jonathanrreed/tap/waves
```

macOS may request audio-capture permission for process taps. Waves does not require Accessibility permission, an admin password, or a reboot.

## Start mixing

Open Waves, follow the setup items needing attention, and choose `Start Mixing`. The optional tour uses a real playing app. `End Tour` or Escape stops it without changing the saved mix. Help and `Settings > Setup` reopen setup or the tour without resetting preferences.

Each app shows whether it is visible, monitored, managed, or in an error state. Browser and Electron helper audio is attributed to its parent app. Apps that conflict with capture, such as some DAWs or conferencing tools, can be excluded.

| Control | Use |
| --- | --- |
| Volume, mute, boost | Set each app's level, including 2×, 3×, or 4× boost |
| Equalizer | Use a 3-band or 8-band curve per app, plus a separate shared curve |
| EQ presets | Start from Flat, Voice Focus, Warm, Bass Reduce, or Treble Soften |
| Adaptive Mix | Temporarily adjust gain by content, priority, strategy, and focus without moving manual sliders |
| Speech-aware focus | Let voice or meeting apps lower other audio only while speech is detected |
| Loudness Balance | Reduce level differences while respecting priorities |
| Output routing | Choose an output per app or change the system output |
| Per-device memory | Restore app levels for each output device |
| Call automation | Temporarily mute or resume selected media without saving that temporary state as user intent |

Routes recover after device changes, with recovery work kept outside realtime callbacks. Settings and Diagnostics show route health and manual recovery actions.

Waves is a mixer, not a recorder or audio-plugin host. It processes audio locally and does not save audio files.

## Profiles and layout

Create a profile from the sidebar's `+` button, name it, and choose its apps. A profile can just group apps, or `Capture current levels` can save volume, mute, and boost. Profiles with saved levels expose `Apply Levels`. Import and export profiles as JSON.

Pin apps, drag to reorder, or sort by activity, name, category, or manual order. The menu bar exposes profiles and output controls. Meters and the mixed waveform show audio activity.

The interface supports keyboard control, VoiceOver, Reduce Motion, Reduce Transparency, and Increase Contrast. macOS 26 uses system glass; macOS 14.2 and 15 use the native visual-effect backdrop.

## Shortcuts

In `Settings > Shortcuts & Automation`, enable shortcuts and record the combinations you need. New installs assign no global keys. Delete clears a recorded shortcut; migrated installs may retain older bindings.

Global actions control the frontmost app or show Waves. Add an app-specific mute binding under `App Shortcuts` or through the app's context menu. Only registered combinations are observed through the system hotkey API; no Accessibility permission is needed.

With the mixer list focused:

| Key | Action |
| --- | --- |
| Arrow keys | Select an app |
| `Space` or `M` | Mute |
| `=` or `-` | Adjust volume |
| `B` | Cycle boost |
| `P` | Pin |
| `E` | Open the app's EQ |
| `O` | Cycle output |
| `R` | Recover routes after automatic recovery is exhausted |

An orange shortcut conflict means another app has claimed the combination. App-specific shortcuts require that app to be running.

## Automation

URL automation is disabled by default. Enable it in `Settings > Shortcuts & Automation` before using:

```text
waves://set-volume?app=APP_ID&volume=0.5
waves://mute?app=APP_ID&muted=true
waves://apply-profile?name=Focus
waves://refresh
```

Volume ranges from 0.0 to 1.0. `apply-preset` remains a deprecated alias for `apply-profile`.

External socket control is a separate opt-in. It listens at `~/Library/Application Support/Waves/control.sock`, accepts only the same macOS user, and opens no network port. Bundled `wavesctl` and the separately versioned Stream Deck companion use protocol version 1 to list apps, set volume or mute, read icons, and watch state.

## Wave Link and route problems

Choose the per-app controller in `Settings > Mixer`. A verified parallel Wave Link path can make an app monitor-only in Waves, preventing a displayed control from claiming a level it cannot enforce.

With Wave Link 3 running, `Test Connection` checks access and free software channels. Each controlled app needs its own channel. Waves assigns a free channel when you first change that app's level.

Disable `Wave Link compatibility` only when a custom route already prevents a parallel monitored copy. Doing so also disables duplicate-route safeguards.

For missing apps, start playback, check `Show system processes`, and refresh with `⌘R`. For failed controls or device changes, inspect Diagnostics and use `Recover Routes` in the window, Setup, or Diagnostics.

## Privacy

Waves does not record or transmit audio and has no analytics or telemetry. It makes no network request until you request an update check or allow automatic checks. Checks fetch the signed appcast at `https://waves.jonathanrreed.com/appcast.xml` without an account, device identifier, audio, or diagnostic upload. Disable automatic checks in General.

`Copy Diagnostics` contains no audio samples, but can include app and device names or identifiers, version and OS details, permission and route state, and bounded error text. Review it before sharing.

[Privacy details](PRIVACY.md) · [Security reporting](SECURITY.md)

## Build and verify

```bash
git clone https://github.com/JonathanRReed/Waves.git
cd Waves
./script/build_and_run.sh
```

```bash
swift build
swift test
./script/build_and_run.sh --release-check
```

`--dmg` builds a local disk image. `--release-check` validates a local DMG; it does not establish public distribution eligibility. `--publication-check` requires Developer ID signing and a passing Gatekeeper assessment.

For an authorized distribution build with your signing certificate:

```bash
xcrun notarytool store-credentials waves-notary --apple-id <apple-id> --team-id <team-id>
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="waves-notary" ./script/build_and_run.sh --notarize
```

Notarization submits, staples, validates, and runs Gatekeeper checks. Follow [docs/RELEASE.md](docs/RELEASE.md) for the complete release procedure.

## Code guide

`Sources/Waves/` contains the SwiftUI app, features, services, stores, and settings. `Sources/WavesAudioCore/` defines audio models and backend protocols; `Tests/WavesTests/` contains tests.

The production `WorkspaceAudioControlBackend` uses Core Audio, while `PreviewAudioControlBackend` supports previews. `AppStore` coordinates intent, adaptive mixing, persistence, and device changes. `PerAppTapController` manages taps, `JSONPersistenceEngine` provides atomic schema-1 storage, and `ControlServer` bounds socket connections and output queues. `wavesctl` is a dependency-free local client.

## Contribute or report a problem

Read [CONTRIBUTING.md](CONTRIBUTING.md), keep changes focused, and run build, tests, and release checks before proposing code changes. For bugs, open an [issue](https://github.com/JonathanRReed/Waves/issues) with a reviewed `Copy Diagnostics` export.

## License

[MIT](LICENSE).
