# Waves Quality and Quick Mixer Design

## Status

Approved by the maintainer on 2026-08-15.

## Purpose

This work turns the menu-bar surface into a compact, native quick mixer and then addresses the highest-value maintainability, release-hygiene, dependency, testing, and CI problems identified during the repository review.

The work is intentionally split into reviewable phases. The audio engine and routing behavior must remain stable while the menu-bar UI is redesigned. Large store and backend refactors must be behavior-preserving and land separately from visual changes.

## Product principles

Waves remains a native, quiet, precise macOS utility. The menu-bar panel is the fastest control surface, not a compressed copy of the entire application. It should expose the controls used several times per day and move lower-frequency controls into contextual menus or the main window.

The existing product rules remain binding:

- macOS 14.2 or later, Apple Silicon and Intel.
- No virtual audio driver, system extension, account, analytics, or telemetry.
- Route state must remain honest. Unavailable controls stay unavailable and explain why.
- Keyboard, VoiceOver, Increase Contrast, Reduce Transparency, and Reduce Motion behavior must remain supported.
- Cyan is reserved for live signal, selection, and primary routing actions.
- No audio-render callback may allocate, lock, log, or perform actor work.

## Phase 1: Quick Mixer

### Scene and sizing

Keep SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Do not introduce a custom `NSStatusItem`, `NSPopover`, or floating `NSPanel` unless the SwiftUI implementation still demonstrates a verified sizing or focus defect after the content redesign.

The menu-bar panel uses one width token with a target width of 372 points. The root view must not force a permanent height. App content owns its natural height until the app-list region reaches its cap, after which only the app list scrolls.

The panel must remain usable on a compact laptop display and with large accessibility text. The footer must remain reachable without scrolling the entire panel.

### Visual hierarchy

The panel is ordered as follows:

1. Compact header with Waves identity, truthful live status, and refresh.
2. One horizontal context row containing output device and profile menus.
3. A thin live waveform strip only while audio is active or settling. Idle state does not reserve waveform height.
4. One unified quick-app list ordered by pinned apps, currently playing apps, then optional recent apps.
5. Compact footer with Open Waves and Settings.

The system menu-bar window owns the outer material. The quick mixer must not place the full `WavesBackground` visual-effect stack behind the system popover. Internal content rows use semantic fills and hairlines only where grouping is required.

### App-list policy

The quick mixer displays no more than seven unique apps in total.

Ordering rules:

- Pinned apps first, preserving the existing pin order.
- Live apps second, excluding apps already shown as pinned.
- Recent apps last, excluding pinned, live, and excluded apps.
- Excluded apps never render in the quick mixer. They remain available in the main window and settings.

When more eligible apps exist, the list ends with one `View N more in Waves` action. That action opens the main window focused on the most useful matching source scope.

The panel may show compact group labels when more than one group is present, but it must not apply independent per-group row limits that can produce eleven visible rows.

### Compact app row

The row becomes a two-line component.

The first line contains:

- App icon.
- App name.
- Small route-state indicator when needed.
- Numeric volume percentage.
- Mute button.
- More-actions button.

The second line contains one wide volume slider.

The following controls move to the more-actions menu:

- Pin or unpin.
- Boost level.
- Equalizer.
- Per-app output device.
- Mute-shortcut assignment.
- Exclude from Waves or manage with Waves.
- Global route recovery when the route policy exposes recovery.

The row remains adjustable with VoiceOver. The visible mute and slider controls retain their labels, values, hints, and capability gating. The menu exposes full text labels and current-state checkmarks.

### Context controls

Output and profile menus share one horizontal row. Each control may truncate its visible title but must expose the full value to accessibility and help text. Profiles remain applicable directly from the menu bar, including Reset Mix when a restore point exists.

### Footer

The footer contains:

- `Open Waves…`
- A Settings button or gear with the accessible label `Open Settings`.

`Launch at login` is removed from the menu-bar panel. It remains in General Settings, where its approval state and repair path are already explained.

### Waveform behavior

The full mixed-waveform visualization remains a signature component in the main window. The menu bar uses a compact strip between 24 and 30 points high only while live audio exists or while the existing settle animation completes.

When idle, the waveform view is not mounted and reserves no space. Reduce Motion uses a static level pose. The existing visibility and cadence gates remain intact.

### File boundaries

The menu-bar implementation is split into focused files under `Sources/Waves/Features/Mixer/MenuBar/`:

- `MenuBarMixerView.swift`: root composition and lifecycle only.
- `MenuBarHeader.swift`: identity, status, refresh, and optional live strip.
- `MenuBarContextControls.swift`: output and profile controls.
- `MenuBarAppList.swift`: deduplication, ordering, cap, overflow, and empty state.
- `MenuBarAppRow.swift`: compact two-line row and row actions menu.
- `MenuBarFooter.swift`: Open Waves and Settings.
- `MenuBarLayout.swift`: structural constants and pure layout policy.

Shared row capability and accessibility policy remains reusable with the main mixer. The refactor must not duplicate route-control logic.

## Phase 2: Release and dependency hygiene

- Upgrade Sparkle from 2.9.4 to 2.9.5 after the complete quality gate passes.
- Update `docs/PRODUCT.md` so its release boundary matches the published 1.5.0 build 13 release.
- Move `1.5-update-plan.md` from the repository root into `docs/archive/` with a short archival notice.
- Add a release-consistency check that compares the maintained release version source against README, product documentation, appcast metadata, and Homebrew metadata where those values are present.
- Keep the website repository out of this app-repository change. Website copy is handled separately.

## Phase 3: Store and backend decomposition

These changes land as behavior-preserving refactors after the quick mixer and release-hygiene work.

### AppStore

Keep `AppStore` as the main-actor observable facade consumed by views. Extract coherent responsibilities into collaborators without changing the public UI-facing API in the same commit:

- Startup and shutdown lifecycle.
- Session discovery and maintenance.
- Live levels and recent/live membership.
- Profile operations and restore-point handling.
- Device inventory and device-preset flow.
- Presentation requests, focus tokens, and toast delivery.

Each extraction requires characterization tests before code moves. Avoid a rewrite or a new state-management framework.

### WorkspaceAudioControlBackend

Extract bounded components around existing behavior:

- Process discovery and attribution.
- Route registry and lifecycle.
- Tap and renderer construction.
- Output-device observation.
- Geometry recovery.
- Snapshot assembly.

Realtime constraints and public backend protocol behavior remain unchanged. Each extraction requires targeted tests and a full audio quality gate.

### Source comments

Keep short invariants next to code. Move long incident histories and architectural rationale into `docs/decisions/` records, linked from the relevant type or method. Do not remove explanations that protect realtime, persistence, identity, or release-supply-chain invariants.

## Phase 4: Testing and CI

### Menu-bar regression matrix

Add rendered or policy tests for:

- 360, 372, and 380-point widths.
- Zero, one, seven, and more than seven eligible apps.
- Long app, profile, and output-device names.
- All apps excluded.
- Light and dark appearances.
- Increase Contrast, Reduce Transparency, and Reduce Motion.
- Idle and live waveform states.
- Footer reachability and first-presentation sizing.

Pure ordering, deduplication, exclusion, and cap rules must be unit tested separately from image rendering.

### CI split

Create two workflows or two clearly separated jobs:

- Fast pull-request gate: formatting, compile, focused unit tests, and rendered quick-mixer checks.
- Full quality gate: complete tests, packaging, DMG evidence, extended audio validation, and release-oriented checks.

The full gate remains required for main and release publication. The fast gate must provide materially quicker feedback for normal pull requests without weakening release validation.

## Phase 5: Existing pull requests and hardening

- Rebase and verify the Sparkle 2.9.5 dependency update, then merge it through the normal gate.
- Re-evaluate PR #28 against current verified-router architecture. Port only still-relevant tests and behavior, then close the obsolete PR with a supersession explanation.
- Replace the forced `CATapDescription` cast in verified-router observation with a checked cast that returns `.unreadable` for an unexpected Core Audio value.

## Error handling

UI actions continue to use existing AppStore feedback and capability policies. The quick mixer must not invent independent persistence or audio error handling.

Unexpected Core Audio property values fail closed for the individual observation, not by terminating Waves. Menu-list policy operates on immutable snapshots and does not mutate store state while computing layout.

## Verification

Every behavior change follows test-first development. Each phase runs the narrowest relevant tests first, followed by `./script/quality-gate.sh full` before its pull request is marked ready.

Menu-bar visual evidence must be generated for the approved compact width and accessibility variants. The pull request must include a concise before-and-after explanation and list any hardware-specific validation that remains outside automated coverage.

## Rollout

Land the phases as separate pull requests in this order:

1. Quick Mixer and UI file decomposition.
2. Release/dependency hygiene.
3. AppStore decomposition.
4. Audio backend decomposition.
5. CI split and remaining hardening.

A later phase must rebase onto the preceding merged phase. Do not combine all phases into one unreviewable pull request.
