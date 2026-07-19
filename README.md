# Waves

Waves is a native macOS per-app audio mixer. It uses local Core Audio process taps on macOS 14.2 or newer to route selected app audio through per-app volume, mute, boost, equalizer, and adaptive mixing controls before playback.

## Features

### Core Audio Control
- **Per-App Volume Control**: Adjust volume levels individually for each running application
- **Mute/Unmute Apps**: Quickly mute or unmute specific applications
- **Volume Boost**: Enhance audio output with 2×, 3×, or 4× boost
- **Audio-Aware Discovery**: Uses Core Audio process output state when available, with a manageable running-app fallback
- **Browser & Electron support**: Attributes audio from helper subprocesses (Chrome, Helium, Brave, Edge, Arc, and Electron apps play through a sandboxed "Audio Service" helper) back to the parent app, so they show as **Live** and are fully controllable — including picture-in-picture / popout video

### Equalizer & Adaptive Mixing
- **Per-App Equalizer**: Choose a simple 3-band curve or an advanced 8-band curve for each app
- **EQ Presets**: Start from Flat, Voice Focus, Warm, Bass Reduce, or Treble Soften
- **Speech Focus**: Gently lowers media while a designated voice app carries speech
- **Loudness Balance**: Smooths large loudness differences between active apps without moving manual volume sliders
- **Explicit Roles and Modes**: Set each app to Auto, Voice, Media, or Ignore, then choose Speech Focus, Loudness Balance, Both, or Off

### Device Management
- **Device Auto-Restore**: Automatically re-establishes audio routes when switching output devices
- **Per-Device Volume Memory**: Remember volume settings for each app across different audio devices

### Automation & Integration
- **Keyboard Shortcuts**: Global hotkeys for quick volume adjustments (⌘⌥↑/↓ for volume, ⌘⌥M for mute)
- **URL Scheme Automation**: Opt-in custom URL schemes for integration with other tools
- **Auto-Pause Music**: Automatically pause music apps when conferencing apps become active

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
  or errored, with an in-app diagnostics export. No other tool surfaces tap
  health this clearly.
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
- Accessibility permission is only required for global shortcuts
- Audio capture permission when macOS prompts for Core Audio process taps

## Installation

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

1. Launch Waves and review the first-run privacy setup. Waves records your local
   consent before starting its audio backend or attempting Core Audio capture;
   macOS may then present its audio-capture permission prompt.
2. After setup, Waves detects manageable running apps and audio-active processes
   when Core Audio exposes them.
3. Adjust volume sliders for individual apps.
4. Use the boost menu when an app is too quiet.
5. Use the mute button to silence specific applications.
6. Pin important apps to keep them easily accessible.

### Keyboard Shortcuts

When keyboard shortcuts are enabled in Settings:

- **⌘⌥↑**: Increase volume for frontmost app
- **⌘⌥↓**: Decrease volume for frontmost app
- **⌘⌥M**: Toggle mute for frontmost app

### URL Scheme Automation

URL scheme automation is disabled by default for security. Enable it in General Settings before using these commands:

- `waves://set-volume?app=APP_ID&volume=0.5` - Set volume for an app (0.0 to 1.0)
- `waves://mute?app=APP_ID&muted=true` - Mute or unmute an app
- `waves://apply-profile?name=Focus` - Apply a named profile (`apply-preset` still works as a deprecated alias)
- `waves://refresh` - Refresh the audio session

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

### General Settings
- **Launch at login**: Start Waves automatically when you log in
- **Show recent apps**: Display background apps in the list
- **Show system processes**: Include system audio processes
- **Auto-pause music during calls**: Pause media when conferencing apps are active
- **Enable keyboard shortcuts**: Use global hotkeys for volume control
- **Per-device volume memory**: Remember volumes per audio device
- **URL scheme automation**: Allow local `waves://` automation commands after explicit opt-in
- **Sort apps by**: Choose sorting method (Activity, Name, Category, Manual)

### Audio Settings
- View current output device information
- Read how managed routing captures and plays back app audio
- Recover managed routes if needed

### Profiles
- Create, edit, delete, and manage profiles
- Export profiles to JSON files
- Import profiles from JSON files

### Advanced
- View running app inventory
- Check diagnostics and system status
- Recover managed routes if needed

## Troubleshooting

### No audio apps detected
- Ensure audio applications are actually playing sound
- Check if "Show system processes" is enabled in Settings
- Try refreshing the app list (⌘R)

### Volume changes not applying
- Use "Recover Routes" in the toolbar or Audio settings to re-establish audio routing
- Check the Diagnostics panel in Advanced settings
- Ensure macOS 14.2+ is installed for per-app routing

### Keyboard shortcuts not working
- Verify "Enable keyboard shortcuts" is enabled in Settings
- Check that Waves has accessibility permissions
- Ensure no other apps are using the same shortcuts

### Device switching issues
- Managed routes re-establish automatically; if one didn't, recover routes manually from the Advanced tab
- Check that your audio device is properly connected

## Architecture

### Core Components

- **WavesAudioCore**: Core audio models and backend protocols
- **Waves**: SwiftUI application with UI components
- **WorkspaceAudioControlBackend**: Production audio backend using Core Audio
- **PreviewAudioControlBackend**: Preview backend for development/testing

### Key Modules

- **AppStore**: Central state management using Swift Observation
- **AudioControlBackend**: Protocol for audio operations
- **PerAppTapController**: Manages per-app audio routing taps
- **PreferencesStore**: Persists user preferences
- **ProfileStore**: Manages profiles (with one-time migration from legacy `presets.json`)
- **SessionStore**: Caches audio session state

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

Waves processes audio locally and never records or transmits it, has no
analytics, and makes no network requests. `Copy Diagnostics` contains no audio
samples, but it can include version/OS metadata, structured permission and route
state, app and device names or identifiers, and bounded error text; review it
before sharing. See [`PRIVACY.md`](PRIVACY.md) for details, and
[`SECURITY.md`](SECURITY.md) to report a vulnerability.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: keep PRs focused, cover logic
with tests, and run `swift build`, `swift test`, and
`./script/build_and_run.sh --release-check` before proposing changes.

## License

Waves is released under the MIT License. See [`LICENSE`](LICENSE).

## Support

For issues and questions, please refer to the in-app diagnostics panel or check the troubleshooting section above.
