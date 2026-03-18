---
title: Waves session discovery and output control design
---

## Overview

## Goal

Restore reliable macOS app discovery for real live audio sources, especially browsers that surface playback through helper or renderer processes, while adding a first-party global output device selector and preserving the hybrid dock plus menu bar utility behavior.

## Constraints

- Keep the frontend focused on clean app-level rows rather than exposing raw helper or PID labels.
- Preserve the existing `MixerBackend` based command surface where practical.
- Treat global output device switching as in-scope for this pass.
- Keep per-app output routing out of scope for this pass.
- Continue using the hybrid menu bar plus dock behavior instead of switching to a menu-bar-only app model.

## Architecture

- Extend the macOS backend discovery model so multiple Core Audio process objects can map to one visible app row.
- Resolve browser helper and renderer processes back to a stable parent-facing app identity when the owning app is user-visible and actively producing output.
- Preserve the underlying process-object mapping internally so per-app gain control still targets the real live process.
- Add a backend device layer for enumerating audio output devices and switching the system default output.
- Add a compact frontend output selector that sits alongside the utility controls.
- Keep the current Tauri tray path, but validate it against macOS menu bar behavior during implementation and testing.

## Data flow

1. `refresh_sessions` enumerates macOS process objects and groups eligible live processes into normalized app rows.
2. Grouping keeps helper and renderer backed browser playback visible under a clean app identity such as Chrome, Arc, Safari, or Edge.
3. `get_mixer_snapshot` returns grouped app rows plus platform notes without exposing raw subprocess labels in the main UI.
4. A new output-device command surface enumerates available output devices and returns the current system output.
5. A new switch-output command sets the system output device and refreshes the active device state.
6. Volume and mute commands continue to target the underlying live process mapping rather than the grouped display label alone.

## Error handling

- If a helper-backed process disappears during control, return a clear refresh-required error.
- If a process is live but cannot be mapped to a user-facing app identity, keep it out of the main list rather than showing a noisy raw process label.
- If output device switching fails, surface the device name and a clear native error.
- If menu bar visibility still fails after tray retention, treat it as a separate platform-validation issue rather than blocking discovery or device work.

## Validation

- Validate browser playback in Chromium-family browsers and Safari so a playing tab appears as a clean browser row.
- Validate that helper or renderer backed browser audio remains controllable through the grouped row.
- Validate that the output selector lists current devices and can switch the default system output.
- Validate that hide-to-tray, dock reopen, and menu bar item behavior still work after the backend changes.
- Keep Bun checks, Rust checks, and production build green.
