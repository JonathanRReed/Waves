# Changelog

All notable changes to Waves are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Waves aims to use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Live mixed-waveform visualizer** — a flowing header ribbon that visualizes the
  combined audio energy of everything currently playing (root-sum-of-squares mix,
  eased between samples for smooth 60fps motion). Calm when silent, alive when
  sound flows; freezes to a static level bar under Reduce Motion and pauses its
  render loop when idle.
- **Genuine Liquid Glass** — adopts Apple's `glassEffect` / `.glassProminent` on
  the floating layer (sheets, primary actions) on macOS 26 (Tahoe), with native
  `.borderedProminent` controls and a real `NSVisualEffectView` window backdrop on
  macOS 14.2–15. Content cards stay tonal (not glass) — glass belongs to the
  floating layer only, per Apple's guidance. Honors Reduce Transparency (opaque)
  and Increase Contrast (stronger borders).
- **Profiles** — group the apps you use together (e.g. Work, Gaming) and switch
  between them from the sidebar or menu bar. A profile can be a pure grouping or
  optionally capture each app's volume, mute, and boost. Reframes the old
  "presets"; an existing `presets.json` is migrated to `profiles.json` on first
  launch.
- **Browser & Electron audio attribution** — Chromium-based browsers (Chrome,
  Helium, Brave, Edge, Arc) and Electron apps emit audio from a sandboxed
  helper/"Audio Service" subprocess that isn't a normal running application;
  Waves now walks the helper's executable path back to the enclosing `.app` so
  these apps show as **Live** and are fully controllable — including
  picture-in-picture / popout video.
- **Quick Pin in the menu bar** — one-click pin/unpin on every menu-bar row;
  pinned apps lock to the top and survive the app (and Waves) quitting and
  relaunching (pin state is stored in preferences, not just the live session).
- A refined visual identity: an in-app wave mark that gently animates while audio
  is live, gradient per-row level meters, and consistent card/section styling.
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
- "Presets" are now "Profiles" throughout the UI; the `waves://apply-preset` URL
  command still works as a deprecated alias for `waves://apply-profile`.
- New-profile shortcut is ⌘N (replacing the old ⌘S save-preset shortcut).

### Fixed
- A managed app no longer drops out of the **Live** list the moment you adjust
  its volume — Live membership now follows the live-level meter, not a stale
  snapshot, so a playing app stays Live while it's still producing sound.
- Numerous pre-publish audit fixes: data-loss-on-decode, prefs wipe on upgrade,
  reorder off-by-one, tap/aggregate-device leaks and actor reentrancy,
  realtime-thread blocking, boost clipping, zombie taps after an app quits,
  dead device-change handling, and copy/accessibility gaps.

### Removed
- Decorative volume-control-mode picker (it was a no-op).
