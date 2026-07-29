# Changelog

All notable changes to Waves are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and Waves aims to use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] - 2026-07-28

Everything in 1.3.1 below, plus the start of external control. 1.3.1 was never
published, so this release carries both.

### Added
- Allow external control (Settings ▸ Shortcuts ▸ Automation, off by default).
  Waves can accept commands from other software on your Mac — reading which apps
  it manages, and changing their volume and mute. It listens on a private socket
  that only your user account can reach; it is never on the network, and no
  other Mac can see it. This is the foundation the Stream Deck plugin will use.
- Add `wavesctl`, a small command-line tool for the same thing. `wavesctl apps`
  lists what Waves manages; `wavesctl toggle <app>` mutes one.

## [1.3.1] - 2026-07-28

A refinement release. No new features — Waves does the same things, using a
small fraction of the energy, and tells you more when something goes wrong.

### Fixed
- Stop Reset Mix from taking over every running app. Applying a profile
  snapshotted the levels of *every* app on screen, so pressing Reset Mix sent a
  volume change to all of them — building an audio tap and a private device for
  apps you had never touched, and remembering that choice on every later launch.
  It now snapshots only the apps Waves actually manages.
- Stop rebuilding a working audio route every six seconds. Waves decided a route
  had died when it stopped hearing sound through it — but an app can hold its
  audio open and send silence indefinitely: a call with nobody talking, a stream
  between cues, a paused game. Each false alarm tore down and rebuilt that app's
  audio tap, with a small dropout every time, and then did it again six seconds
  later, forever. Waves now checks whether the route is still running rather than
  whether it is loud.
- Stop Waves from burning CPU in the background. Left running with one app
  routed, Waves kept redrawing its waveform and level meters at full display
  rate for as long as audio was playing — even with its window behind another
  app, minimized, on another Space, or closed entirely. Over a long session that
  was roughly two saturated processor cores, a warm machine, and a loud fan.
  Waves now stops drawing the moment nothing of it is on screen, and eases off
  to half rate when its window is visible but not the app you are using.
- Redraw the level meters without re-laying out the window. Each meter used to
  animate by resizing itself, which forced macOS to re-measure the entire window
  on every frame, for every playing app at once. The meters now paint directly,
  so the cost stays proportional to what is actually visible.
- Stop polling audio levels for windows nobody can see. The three-times-a-second
  level poll kept running while Waves was hidden, because the signal it used to
  detect "hidden" never fired for a window that was merely covered.
- Let Adaptive Mix rest. It woke ten times a second whenever it was switched on,
  even with nothing routed through Waves and therefore nothing to balance or
  duck. It now idles until there is real work, and stops rewriting gain values
  that have not changed.
- Stop logging normal app churn as a warning. Quitting an app while Waves was
  looking at it produced a Core Audio "bad object" warning, dozens per session,
  which buried the failures that actually matter. Those are now recognized as
  ordinary lifecycle events; genuine device, permission, and property failures
  are still reported.
- Stop re-checking audio permission the hard way. Waves confirmed its recording
  permission by creating and destroying a system-wide audio tap — twice every
  eight seconds, for as long as it was open, even while a working route was
  already proving the permission was granted. A tap that failed to clean up was
  also abandoned; those are now retried.
- Stop re-encoding every app's icon every eight seconds. The result was thrown
  away each time.
- Keep the menu-bar icon honest. It reported "muted" whenever any app was muted,
  even with something else audibly playing — directly above a panel that read
  "1 app playing" — and its VoiceOver label said the same. Playing now wins;
  "muted" appears only when nothing is audible. The icon, its spoken label, and
  the panel header now come from one shared answer.
- Stop losing a profile member you can't get back. Unticking an app that wasn't
  running made its row disappear from the profile editor entirely, with no way to
  re-tick it, and Save then wrote the profile without it.
- Keep the equalizer card pointed at something real. Excluding the app it was
  editing left the card attached to a stream Waves no longer touches.
- Stop resetting an Adaptive Mix choice. Turning Adaptive Mix off and back on
  rewrote a deliberate Speech Focus or Loudness Balance selection to Both. Waves
  now restores the mode you picked, including across a restart.
- Adaptive Mix no longer takes its cue from the app list's display settings —
  hiding system processes could change which streams got turned down.
- Say "No Results" when a search matches nothing, instead of "No Running Apps",
  and offer to clear the search.
- Help ▸ Waves Help now opens Settings on the Help page rather than General.
- Flush each saved file independently when quitting. One failure used to abandon
  the other three, so a single bad write could discard your session, profiles,
  and device presets — and the error named none of them.
- Keep trying to release audio resources a first teardown could not. A tap left
  behind keeps its app silent, and nothing used to retry it.
- Don't start the update checker inside the test suite, where its scheduled check
  could raise a dialog no one can answer and hang the run.
- Keep a profile member visible if its app quits while the profile editor is
  open. Its row used to disappear, and Save then wrote the profile without it.
- Don't report the last clean quit as though it described a crash. The shutdown
  record is written only on a normal quit, so after a force quit or a system kill
  the previous quit's "clean" result was shown as if it were the crash's. Waves
  now consumes the record at launch, and honestly reports nothing when there is
  nothing to report.
- Sort app names the way a person would read them. The faster sort added in this
  release compared raw character values, which pushed accented names ("Ätna")
  after every unaccented one. Names now fold accents as well as case, all four
  sort orders agree, and apps sharing a name no longer swap places between
  refreshes.
- Stop clearing "pause music for conferencing" behind your back. Turning that on
  downgrades Adaptive Mix from Both to Loudness Balance; switching Adaptive Mix
  off and on then restored Both, which silently turned the setting back off.
- Reset the adaptive engine when nothing is routed, so a returning route starts
  clean instead of resuming from stale ducking.
- Show the previous shutdown's persistence errors and the running build's source
  revision in the diagnostics report. Both were recorded but never printed.
- Say "Try a different search term" only when the query is a real search — a
  whitespace-only query made the empty state's heading and message disagree.

### Added
- Record what happened during shutdown. If cleanup finishes in a degraded state,
  Waves now writes exactly which stage failed and with what status to
  `~/Library/Application Support/Waves/Diagnostics/last-shutdown.json`, before it
  exits. The next launch reads it back into the diagnostics report. Previously a
  degraded shutdown said only that it was degraded, and the detail was gone with
  the process.
- Include the source revision in the diagnostics report, so a bug report names
  the exact build it came from.

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
