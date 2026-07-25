# Changelog

All notable changes to Waves are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Waves aims to use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-07-20

### Added
- Add Reset Mix. Applying a profile with saved levels now remembers how every
  app was set first, and one click in the toolbar or menu bar puts everything
  back. Apply Meeting for the call, reset when it ends.
- Add a default profile. Right-click a profile and choose Apply at Startup (or
  pick one in Settings > Profiles) and Waves applies its levels every time it
  starts.
- Add an About window with the version number, an update check, and links to
  the website, source, and privacy policy.
- Show live processing in the wave visualizer: streams shaped by an equalizer
  gain visible texture, streams held back by Sidechain Focus ride lower at
  their real reduced level, and small EQ and Focus chips name what's active.

### Changed
- Merge the two equalizers into one Equalizer card in Sound. It edits the
  shared All Managed Audio curve or any single app, switched with one chip
  row that also marks which streams have EQ on. The per-app side panel is
  gone, along with its overlap problems in small windows.
- Reorganize Settings into General, Mixer, Profiles, Shortcuts, Setup,
  Advanced, and Help. Each sidebar row says what it contains, related
  settings live together, and the update check appears in Settings, the app
  menu, and the About window.
- Rewrite descriptions across the app in plain language with concrete
  examples.

### Fixed
- Reserve headroom for the real combined EQ curve instead of only the
  largest single band. Stacked boosts on neighboring bands could previously
  exceed the reserve and clip loud audio.
- Keep clipping protection in place until an EQ change has fully faded in,
  instead of releasing it about 20 ms early.

## [1.2.1] - 2026-07-20

### Fixed
- Load the in-app logo from the packaged application resources without relying
  on SwiftPM's build-directory fallback. Fresh downloads now launch correctly
  on Macs that do not have the Waves source checkout.
- Run packaged-app smoke tests with access to local Swift build artifacts
  denied, preventing clean-machine resource failures from passing release QA.

## [1.2.0] - 2026-07-20

### Added
- Add a dedicated Sound workspace with Managed Audio EQ for every stream routed
  through Waves, including Simple and Advanced bands, presets, and combined
  clipping protection when per-app and managed equalizers are stacked.
- Add content-aware app policies for Lecture or Voice, Meeting, Music, Video or
  Media, Game, and Other, with Foreground, Normal, Background, and Never Adjust
  priorities.
- Add Sidechain Focus with Assigned Priorities, Follow Front App, and Smart
  Hybrid modes. Smart Hybrid promotes an audible frontmost app by one priority
  tier while preserving explicit priorities as guardrails.
- Add Lecture Focus, Media First, Balanced, and Custom adaptive strategies for
  common mixes such as a clear lecture over background music or media over a
  low-priority meeting.
- Add independent Waves and Graphite palettes, each available in System, Light,
  and Dark appearance modes.
- Add a four-stage guided setup for privacy, audio readiness, common preferences,
  and a final configuration summary.
- Add Setup & Repair with live checks, direct links to the matching macOS privacy,
  Accessibility, Login Items, and Sound panes, route recovery, and a non-destructive
  Redo Guided Setup flow.

### Changed
- Replace the app icon with the new cyan wave identity across the app bundle,
  Finder, Dock, and distribution image.
- Redesign the mixer, inspector, settings, menu bar, and shared surfaces around a
  quieter native visual system with consistent themed fills, strokes, selection,
  and status colors.
- Replace the single legacy adaptive role with independent content type and
  priority policies while migrating existing Auto, Voice, Media, and Ignore
  choices.
- Process adaptive focus from transient local activity and speech measurements.
  Waves never records or exports audio samples and never pauses or mutes apps for
  Sidechain Focus.
- Treat persisted backend capability status as unprobed until the live backend
  refreshes it, preventing stale permission and route-health claims at launch.

### Fixed
- Reserve combined EQ headroom before processing so stacked boosts do not clip
  full-scale managed audio.
- Require audible activity before front-app focus can trigger, require detected
  speech for lecture and meeting sources, and keep Never Adjust immune to
  adaptive gain.
- Keep a Background meeting from leapfrogging explicitly Foreground media in
  Smart Hybrid mode.
- Keep first-run setup non-mutating until the user explicitly chooses Continue,
  including Settings navigation and application shutdown.
- Reject oversized URL-scheme payloads before Foundation URL parsing.
- Bound decoded profile counts, entry counts, and names for both persisted
  libraries and imported backups.

## [1.1.0] - 2026-07-18

### Added
- **Per-app equalizer and Adaptive Mix** with simple or advanced curves, presets,
  app roles, and locally persisted settings.
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
- First-run privacy setup now records explicit local consent before the audio
  backend starts or attempts any Core Audio capture.
- Per-app changes now use generation-safe complete intents, so superseded async
  work cannot overwrite a newer volume, mute, EQ, boost, exclusion, or route.
- Per-app intent state remains durable while apps are offline, and profile applies
  retain one truthful ordered result for every source row.
- Preferences, profiles, sessions, and device presets now use bounded coalesced
  persistence with surfaced write failures and explicit flush boundaries.
- Release packaging and CI now gate both arm64 and x86_64 slices, matching dSYM
  UUIDs, the macOS 14.2 floor, bundle metadata, privacy assets, and package layout.
- Copied diagnostics now report truthful version/OS, structured authorization,
  device/readiness, route/backend, persistence, and checked-cleanup state in a
  bounded privacy-labelled format with no audio samples.
- App pinned to a dark appearance (matches the design charter; fixes light-mode
  readability).
- Menu-bar icon reflects live state instead of average volume.
- Search spans all visible apps instead of only the selected scope.
- "Presets" are now "Profiles" throughout the UI; the `waves://apply-preset` URL
  command still works as a deprecated alias for `waves://apply-profile`.
- New-profile shortcut is ⌘N (replacing the old ⌘S save-preset shortcut).

### Fixed
- Unsupported or inconsistent native audio formats and missing current-output
  device queries now fail closed instead of fabricating a usable route.
- App termination now performs bounded, checked shutdown: pending mutations and
  persistence settle before native route cleanup, with degraded/timed-out results
  reported rather than silently assumed clean.
- Equalizer access is now visible on every menu-bar app row instead of being
  discoverable only through the row's context menu.
- Local release builds now carry version 1.1.0 and build 2 so macOS can clearly
  distinguish them from the earlier 1.0.0 build during an upgrade.
- Local packaging falls back to the compatible macOS 26 SDK when Command Line
  Tools provides SwiftUI macro declarations without the required plugin.
- Universal packaging keeps arm64 and x86_64 products in separate SwiftPM
  scratch directories so one architecture cannot overwrite the other.
- A managed app no longer drops out of the **Live** list the moment you adjust
  its volume — Live membership now follows the live-level meter, not a stale
  snapshot, so a playing app stays Live while it's still producing sound.
- Numerous pre-publish audit fixes: data-loss-on-decode, prefs wipe on upgrade,
  reorder off-by-one, tap/aggregate-device leaks and actor reentrancy,
  realtime-thread blocking, boost clipping, zombie taps after an app quits,
  dead device-change handling, and copy/accessibility gaps.

### Removed
- Decorative volume-control-mode picker (it was a no-op).
