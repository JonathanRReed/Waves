# Waves

[![CI](https://github.com/JonathanRReed/Waves/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/JonathanRReed/Waves/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/JonathanRReed/Waves?label=release)](https://github.com/JonathanRReed/Waves/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/JonathanRReed/Waves/total)](https://github.com/JonathanRReed/Waves/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black)
![Signed & Notarized](https://img.shields.io/badge/signed-Developer%20ID%20%C2%B7%20notarized-success)

Waves is a native macOS per-app audio mixer. It uses local Core Audio process taps on macOS 14.2 or newer to route selected app audio through per-app volume, mute, boost, equalizer, and adaptive mixing controls before playback.

## Release status

Version **1.4.4** is the latest published, signed, and notarized release. Version
**1.5.0 build 13** is in development and is not available from the download or
Homebrew links below. Its publication remains gated on packaged-app validation,
signed release evidence, and remote Wave Link plus physical Stream Deck tests.

## Features

### Core Audio Control
- **Per-App Volume Control**: Adjust volume levels individually for each running application
- **Mute/Unmute Apps**: Quickly mute or unmute specific applications
- **Volume Boost**: Enhance audio output with 2×, 3×, or 4× boost
- **Audio-Aware Discovery**: Uses Core Audio process output state when available, with a manageable running-app fallback
- **Browser & Electron support**: Attributes audio from helper subprocesses (Chrome, Helium, Brave, Edge, Arc, and Electron apps play through a sandboxed "Audio Service" helper) back to the parent app, so they show as **Live** and are fully controllable — including picture-in-picture / popout video

### Equalizer and Adaptive Mixing
- **Per-App Equalizer**: Choose a simple 3-band curve or an advanced 8-band curve for each app
- **EQ Presets**: Start from Flat, Voice Focus, Warm, Bass Reduce, or Treble Soften
- **Shared Equalizer**: Shape all audio managed by Waves with a second independent curve
- **Adaptive Mix**: Temporarily adjusts gain from each app's content type, assigned priority, strategy, and focus mode without moving manual sliders
- **Speech-Aware Focus**: Voice and meeting apps must carry actual speech before they can lower another app
- **Loudness Balance**: Smooths large loudness differences between active apps while respecting the selected priority policy

### Device Management
- **Per-App Output Routing**: Send each app to a chosen output device
- **Global Output Switching**: Change the system output device from the menu-bar panel
- **Device Auto-Restore**: Automatically re-establishes audio routes when switching output devices
- **Per-Device Volume Memory**: Remember volume settings for each app across different audio devices
- **Wave Link Coexistence**: Recognizes verified active Wave Link Core Audio output, conservatively yields affected ordinary routes when public APIs cannot attribute its targets, and never wraps Wave Link's own mixed output
- **Asynchronous Route Recovery**: Rebuilds changed audio geometry outside realtime callbacks and exposes progress or a global recovery action

### Automation and Integration
- **Keyboard Shortcuts**: Assign global hotkeys for the app in front and app-specific volume or mute actions. The focused mixer also has complete keyboard control. No Accessibility permission is required
- **URL Scheme Automation**: Opt-in custom URL schemes for integration with other tools
- **External Control**: Opt-in, same-user Unix socket protocol for the bundled `wavesctl` tool and the separately versioned Stream Deck companion. Protocol version 1 remains stable
- **Session-Only Call Automation**: Automatically mute or resume configured media during conferencing without turning temporary mute into durable user intent

### Profiles & Organization
- **Profiles**: Group the apps you use together — like **Work** (Slack, Teams, browsers) or **Gaming** (Discord, Steam) — and switch between them from the sidebar or menu bar
- **Optional saved levels**: A profile can be a pure grouping, or capture each app's volume, mute, and boost so applying it restores the mix
- **Profile Sharing**: Export and import profiles as JSON files
- **Quick Pin**: One-click pin any app to the top of the menu bar; pins survive the app (and Waves) quitting and relaunching
- **Drag-to-Reorder**: Customize the order of your app list
- **Smart Sorting**: Sort apps by activity, name, category, or manual order

### User Interface
- **Dynamic Menu Bar Icon**: Menu bar icon changes based on volume and mute state
- **Live Mixed-Waveform Visualizer**: A flowing header ribbon showing the combined audio energy of every playing app — alive when sound flows, calm when silent
- **Real-time Audio Levels**: Per-app level meters for audio activity
- **Liquid Glass**: Genuine `glassEffect` / `.glassProminent` on the floating layer on macOS 26 (Tahoe), with native button styling and a real `NSVisualEffectView` window backdrop on macOS 14.2–15; content cards stay tonal (not glass); honors Reduce Transparency, Reduce Motion, and Increase Contrast
- **Empty State UI**: Helpful guidance when no audio apps are detected
- **Setup Checklist**: Settings-based setup status for permissions, output device visibility, and route health
- **Accessible Route State**: Full and compact controls expose labels, values, hints, actions, focus order, VoiceOver rotors, status announcements, and Reduce Motion behavior

## How Waves compares

Waves controls per-app audio with macOS Core Audio **process taps** — so unlike
**Background Music**, **eqMac**, or **SoundSource**, it installs **no virtual
audio driver, no system extension, and needs no reboot or admin password**;
deleting the app leaves nothing behind. A few newer tools (FineTune, Fader) use
the same driver-free approach, so against those Waves leads on other fronts:

- **Truly free and MIT-licensed** — per-app volume, mute, and up to 4× boost are
  free; eqMac paywalls its per-app mixer and SoundSource is paid.
- **Broad reach** — macOS 14.2+ **and Intel**, where comparable driver-free
  tools require macOS 15+.
- **Honest routing** — every app shows whether it's visible, monitored, managed,
  or errored, with an in-app diagnostics export, so you always know exactly what
  Waves is (and isn't) controlling.
- **Accessibility** — full keyboard operation and VoiceOver rotors.
- **Reliability escape hatch** — any app that dislikes being tapped (DAWs,
  conferencing/echo-cancellation apps, other audio tools) can be excluded in one
  click.
- **Private** — audio is processed locally and never recorded, transmitted, or
  used for telemetry. macOS may still ask for audio-capture permission because
  Core Audio process taps share that privacy gate.

Waves is intentionally a **focused mixer, not a plugin suite or recorder**. Its
built-in per-app EQ covers quick mix shaping. For parametric mastering or
audio capture-to-file, a dedicated tool such as eqMac or Audio Hijack is a
better fit.

## System Requirements

- macOS 14.2 or later (Apple Silicon or Intel — release builds are universal)
- Audio capture permission when macOS prompts for Core Audio process taps
- No Accessibility permission — Waves never asks for it

## Installation

### Download (recommended)

Download the latest signed and notarized `Waves.dmg` from
[GitHub Releases](https://github.com/JonathanRReed/Waves/releases/latest), open
it, and drag **Waves** to **Applications**. The disk image uses a focused Finder
layout with one clear installation action. If Waves is opened from the disk
image or another temporary location, it explains why Applications is preferred
before continuing. It never moves or copies itself without your action.

### Homebrew

```bash
brew install --cask jonathanrreed/tap/waves
```

The cask lives in [`JonathanRReed/homebrew-tap`](https://github.com/JonathanRReed/homebrew-tap).

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/JonathanRReed/Waves.git
cd Waves
```

2. Build and launch the app bundle:
```bash
./script/build_and_run.sh
```

3. Build a local DMG:
```bash
./script/build_and_run.sh --dmg
```

4. Run local release validation:
```bash
./script/build_and_run.sh --release-check
```

5. Check whether the build is acceptable for public distribution:
```bash
./script/build_and_run.sh --publication-check
```

6. Notarize a public distribution build:
```bash
xcrun notarytool store-credentials waves-notary --apple-id <apple-id> --team-id <team-id>
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="waves-notary" ./script/build_and_run.sh --notarize
```

`--release-check` creates a locally verified DMG. `--publication-check` fails unless the app has a Developer ID Application signature and passes Gatekeeper assessment. `--notarize` requires a Developer ID Application certificate and a stored notarytool profile, then submits, staples, validates, and runs Gatekeeper assessment on the DMG.

See `docs/RELEASE.md` for the full release checklist.

## Usage

### Quick Start

1. Launch Waves. The guided setup explains local processing before the first
   audio request, then macOS may present its audio-capture permission prompt.
   Waves never asks for Accessibility permission.
2. Follow only the readiness items that need attention. Healthy checks stay out
   of the way, and route recovery is clearly presented as optional when the core
   mixer is already usable.
3. Choose **Start Mixing**, or take the optional 60-second tour on a real playing
   app. **End Tour** and Escape stop the tour immediately without changing your
   saved mix.
4. Adjust per-app volume, mute, output, EQ, and boost from the mixer. Accepted
   controls advance the tour, while failed or unavailable controls leave the
   current explanation in place.
5. Replay **Guided Setup**, **What's New**, or the mixer tour later from Help or
   **Settings ▸ Setup**. Replaying setup keeps profiles, levels, equalizers,
   privacy choices, and preferences intact.
6. Use the mute button to silence specific applications.
7. Pin important apps to keep them easily accessible.

### Keyboard Shortcuts

Enable them in **Settings ▸ Shortcuts & Automation**, then click any shortcut to record your own.
Press Delete while recording to remove it.

New installs have no global chord assigned. In **Global Shortcuts**, record the
combinations you want for frontmost-app volume, frontmost-app mute, and Show
Waves. Existing installs may retain migrated legacy bindings.

You can also give one specific app its own mute shortcut, so it works no matter
what is in front — add it under **App Shortcuts**, or right-click the app in the
mixer and choose **Assign Mute Shortcut**. Nothing is bound by default, so
nothing collides with a launcher or key remapper; hyper (⌃⌥⇧⌘) combinations
record correctly.

Waves registers only the combinations you assign, through the system's own
hot-key API. It needs no Accessibility permission and never observes any other
keystroke.

While the mixer list is focused, use the arrow keys to select an app. Press
Space or M to mute, = or - to adjust volume, B to cycle boost, P to pin, E to
open that app's equalizer, O to cycle output, or R to run global route recovery
when the selected route has exhausted automatic recovery. Capability-gated
routes, including conservative Wave Link handoff, ignore controls Waves must not
claim.

### URL Scheme Automation

URL scheme automation is disabled by default for security. Enable it in
**Settings ▸ Shortcuts & Automation** before using these commands:

- `waves://set-volume?app=APP_ID&volume=0.5` - Set volume for an app (0.0 to 1.0)
- `waves://mute?app=APP_ID&muted=true` - Mute or unmute an app
- `waves://apply-profile?name=Focus` - Apply a named profile (`apply-preset` still works as a deprecated alias)
- `waves://refresh` - Refresh the audio session

External socket control is a separate opt-in in the same pane. It listens only
at `~/Library/Application Support/Waves/control.sock`, requires the same macOS
user, and never opens a network port. The repository's `wavesctl` executable
uses protocol version 1 to list apps, change volume or mute, read icons, and
watch state changes.

### Profiles

1. In the main window's sidebar, click the **+** next to "Profiles"
2. Name it (e.g. Work, Gaming) and choose which apps belong
3. Optionally turn on **Capture current levels** to also save each app's volume, mute, and boost
4. Select the profile in the sidebar to focus its apps, or switch to it from the menu bar; profiles that carry levels show an **Apply Levels** button

### Device Switching

When switching audio devices:
- Managed routes are re-established automatically when the output device changes
- Enable "Per-device volume memory" to remember app volumes per device

## Settings

- **General**: Launch at login, appearance, update consent, and general behavior
- **Mixer**: App visibility, sorting, call automation, route behavior, and per-device volume memory
- **Profiles**: Create, edit, delete, export, import, and select a startup profile
- **Shortcuts & Automation**: Global and app-specific hotkeys, URL automation, and protocol-v1 external control
- **Setup**: Permission, output, route, and login-item readiness with non-destructive repair actions
- **Diagnostics**: Current device and route health, Recover Routes, refresh, and bounded diagnostic copy
- **Help**: Current keyboard, automation, profile, routing, and troubleshooting guidance

## Troubleshooting

### No audio apps detected
- Ensure audio applications are actually playing sound
- Check if "Show system processes" is enabled in Settings
- Try refreshing the app list (⌘R)

### Volume changes not applying
- Read the route status first. Wave Link-owned routes are intentionally monitor-only and must be adjusted in Wave Link
- Use Recover Routes from the main window status action, Setup, or Diagnostics to re-establish Waves-managed routing
- Check the current route and permission details in Diagnostics
- Ensure macOS 14.2+ is installed for per-app routing

### Keyboard shortcuts not working
- Verify "Enable keyboard shortcuts" is on in Settings ▸ Shortcuts & Automation
- A combination another app already claimed is marked in orange there — record a different one
- An app shortcut only fires while that app is running
- No permission is involved; Waves never asks for Accessibility

### Device switching issues
- Managed routes re-establish automatically. If one did not, use Recover Routes from Setup or Diagnostics
- Check that your audio device is properly connected

## Architecture

### Core Components

- **WavesAudioCore**: Core audio models and backend protocols
- **Waves**: SwiftUI application with UI components
- **WorkspaceAudioControlBackend**: Production audio backend using Core Audio
- **PreviewAudioControlBackend**: Preview backend for development/testing

### Key Modules

- **AppStore**: Main-actor observable facade over focused intent, adaptive-mix, persistence, and device-change coordinators
- **AudioControlBackend**: Protocol for audio operations
- **PerAppTapController**: Manages per-app audio routing taps
- **JSONPersistenceEngine**: Internal atomic schema-1 storage shared by the existing persistence protocols
- **ControlServer**: Same-user protocol-v1 Unix socket with bounded connection and output queues
- **wavesctl**: Dependency-free command-line client for testing and trusted local automation

## Development

### Project Structure

```
Waves/
├── Sources/
│   ├── Waves/              # Main application
│   │   ├── App/           # App delegate and setup
│   │   ├── Features/      # Feature modules (Mixer, Settings, etc.)
│   │   ├── Services/      # Services (Audio, Persistence, etc.)
│   │   ├── Stores/        # State management
│   │   └── Settings/      # Settings views
│   └── WavesAudioCore/    # Core audio models and protocols
├── Tests/
│   └── WavesTests/        # Test suite
└── Package.swift          # Swift Package Manager configuration
```

### Running Tests

```bash
swift test
```

### Building

```bash
swift build
```

## Privacy

Waves processes audio locally and never records or transmits it. It has no
analytics or telemetry. Waves makes no network request before you start an
update check or allow automatic checks. An allowed check fetches the signed
appcast from `https://waves.jonathanrreed.com/appcast.xml` without sending an
account, device identifier, audio, diagnostics, or telemetry. Turn automatic
checks off in General at any time. `Copy Diagnostics` contains no audio
samples, but it can include version and OS metadata, permission and route state,
app and device names or identifiers, and bounded error text. Review it before
sharing. See [`PRIVACY.md`](PRIVACY.md) for details, and
[`SECURITY.md`](SECURITY.md) to report a vulnerability.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: keep PRs focused, cover logic
with tests, and run `swift build`, `swift test`, and
`./script/build_and_run.sh --release-check` before proposing changes.

## License

Waves is released under the MIT License. See [`LICENSE`](LICENSE).

## Support

Check the troubleshooting section above first. For bugs and questions, open an
issue at [github.com/JonathanRReed/Waves/issues](https://github.com/JonathanRReed/Waves/issues) —
the bug template asks for a `Copy Diagnostics` export (Waves › Settings ›
Diagnostics), which contains no audio samples.
