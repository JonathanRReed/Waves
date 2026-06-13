# Waves

Waves is a native macOS per-app audio mixer. It uses local Core Audio process taps on macOS 14.2 or newer to route selected app audio through per-app volume, mute, and boost controls before playback.

## Features

### Core Audio Control
- **Per-App Volume Control**: Adjust volume levels individually for each running application
- **Mute/Unmute Apps**: Quickly mute or unmute specific applications
- **Volume Boost**: Enhance audio output with 2x, 3x, or 4x boost presets
- **Audio-Aware Discovery**: Uses Core Audio process output state when available, with a manageable running-app fallback

### Device Management
- **Device Auto-Restore**: Automatically re-establishes audio routes when switching output devices
- **Per-Device Volume Presets**: Remember volume settings for each app across different audio devices
- **Smart Volume Backend**: Intelligently switches between hardware and software volume control

### Automation & Integration
- **Keyboard Shortcuts**: Global hotkeys for quick volume adjustments (⌘⌥↑/↓ for volume, ⌘⌥M for mute)
- **URL Scheme Automation**: Opt-in custom URL schemes for integration with other tools
- **Auto-Pause Music**: Automatically pause music apps when conferencing apps become active

### Presets & Organization
- **Volume Presets**: Save and restore custom volume configurations
- **Preset Sharing**: Export and import presets as JSON files
- **App Pinning**: Pin important apps to keep them visible
- **Drag-to-Reorder**: Customize the order of your app list
- **Smart Sorting**: Sort apps by activity, name, category, or manual order

### User Interface
- **Dynamic Menu Bar Icon**: Menu bar icon changes based on volume and mute state
- **Real-time Audio Levels**: Visual feedback for audio activity levels
- **Smooth Animations**: Polished UI with spring animations and transitions
- **Empty State UI**: Helpful guidance when no audio apps are detected
- **Setup Checklist**: Settings-based setup status for permissions, output device visibility, and route health

## System Requirements

- macOS 14.2 or later
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

1. Launch Waves. It will automatically detect manageable running apps and audio-active processes when Core Audio exposes them.
2. Adjust volume sliders for individual apps
3. Use the boost menu when an app is too quiet
4. Use the mute button to silence specific applications
5. Pin important apps to keep them easily accessible

### Keyboard Shortcuts

When keyboard shortcuts are enabled in Settings:

- **⌘⌥↑**: Increase volume for frontmost app
- **⌘⌥↓**: Decrease volume for frontmost app
- **⌘⌥M**: Toggle mute for frontmost app

### URL Scheme Automation

URL scheme automation is disabled by default for security. Enable it in General Settings before using these commands:

- `waves://set-volume?app=APP_ID&volume=0.5` - Set volume for an app (0.0 to 1.0)
- `waves://mute?app=APP_ID&muted=true` - Mute or unmute an app
- `waves://apply-preset?name=Focus` - Apply a named preset
- `waves://refresh` - Refresh the audio session

### Presets

1. Adjust volumes for your apps
2. Click the "+" button in the toolbar
3. Enter a preset name
4. Your configuration is saved and can be applied anytime

### Device Switching

When switching audio devices:
- Enable "Auto-restore device" in Settings for automatic route recovery
- Enable "Per-device volume presets" to remember app volumes per device

## Settings

### General Settings
- **Launch at login**: Start Waves automatically when you log in
- **Show recent apps**: Display background apps in the list
- **Show system processes**: Include system audio processes
- **Auto-restore device**: Re-establish routes when device changes
- **Auto-pause music during calls**: Pause media when conferencing apps are active
- **Enable keyboard shortcuts**: Use global hotkeys for volume control
- **Per-device volume presets**: Remember volumes per audio device
- **URL scheme automation**: Allow local `waves://` automation commands after explicit opt-in
- **Sort apps by**: Choose sorting method (Activity, Name, Category, Manual)

### Audio Settings
- View current output device information
- Choose the preferred route-control mode for Waves-managed sessions

### Presets
- Create, delete, and manage volume presets
- Export presets to JSON files
- Import presets from JSON files

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
- Check the Diagnostics panel in Advanced settings
- Try "Recover routes now" to re-establish audio routing
- Ensure macOS 14.2+ is installed for per-app routing

### Keyboard shortcuts not working
- Verify "Enable keyboard shortcuts" is enabled in Settings
- Check that Waves has accessibility permissions
- Ensure no other apps are using the same shortcuts

### Device switching issues
- Enable "Auto-restore device" in Settings
- Try manually recovering routes from the Advanced tab
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
- **PresetStore**: Manages volume presets
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
analytics, and makes no network requests. See [`PRIVACY.md`](PRIVACY.md) for
details, and [`SECURITY.md`](SECURITY.md) to report a vulnerability.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: keep PRs focused, cover logic
with tests, and run `swift build`, `swift test`, and
`./script/build_and_run.sh --release-check` before proposing changes.

## License

Waves is released under the MIT License. See [`LICENSE`](LICENSE).

## Support

For issues and questions, please refer to the in-app diagnostics panel or check the troubleshooting section above.
