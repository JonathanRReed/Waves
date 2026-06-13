# Changelog

All notable changes to Waves are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Waves aims to use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Per-app output-device routing** — send each app to a chosen output device.
- **Per-app exclude/ignore** escape hatch for apps that dislike being tapped.
- **Live per-app level meters** (visibility-gated; near-zero idle cost).
- Real audio-capture (TCC) permission detection, surfaced in onboarding and
  diagnostics, replacing an OS-version proxy.
- Global output-device switching from the menu-bar panel.
- Full keyboard operation of the mixer and VoiceOver rotors; Reduce Motion,
  Increase Contrast, and Dynamic Type support.
- Mute provenance (auto-pause never overrides a user mute, and resumes
  correctly after relaunch).
- "Copy Diagnostics" route-health export.
- Versioned persistence envelope; testable realtime DSP (`TapDSP`).
- Privacy manifest, `PRIVACY.md`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CHANGELOG.md`, a Homebrew cask, and tag-driven notarized release CI.
- MIT license.

### Changed
- App pinned to a dark appearance (matches the design charter; fixes light-mode
  readability).
- Menu-bar icon reflects live state instead of average volume.
- Search spans all visible apps instead of only the selected scope.

### Fixed
- Numerous pre-publish audit fixes: data-loss-on-decode, prefs wipe on upgrade,
  reorder off-by-one, tap/aggregate-device leaks and actor reentrancy,
  realtime-thread blocking, boost clipping, zombie taps after an app quits,
  dead device-change handling, and copy/accessibility gaps.

### Removed
- Decorative volume-control-mode picker (it was a no-op).
