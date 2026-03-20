# Hybrid Native Overhaul Design

Date: 2026-03-20

## Goal

Make Waves feel like a real macOS utility while keeping the existing hybrid model:

- a reliable menu bar presence
- a normal desktop window
- trustworthy per-app session discovery
- fast control over live audio and visible nearby control over recently live apps

The app should stop relying on frontend presentation state to imply audio truth. Native state should be the source of truth, with the React UI acting as a thin presentation layer.

## External Reference Read

The overhaul direction is based on these open-source references:

- Background Music: native-first per-app audio pipeline and process ownership mapping
- FineTune: pinned-app workflow, menu-bar utility behavior, and clean app identity
- eqMac: separation between driver/backend truth and the view layer
- switchaudio-osx and Instant Audio Switcher: output-device switching kept small and reliable

## Problems To Fix

- The menu bar item is fragile on macOS because the tray path is not configured like a native menu bar utility.
- Session discovery relies too heavily on coarse activity flags instead of live render and signal evidence.
- The backend does not expose enough session state for the UI to distinguish detected, live, recently live, controllable, and idle conditions.
- The frontend compensates with timers and hidden-state heuristics, which can make active sources feel missing or delayed.
- Top bar mode is still treated like a resized app surface instead of a native utility presentation.

## Recommended Architecture

Keep Tauri as the shell for now, but push macOS behavior further into native Rust:

1. Add a richer native session model.
2. Make menu bar creation deterministic on macOS.
3. Attach and manage Core Audio taps based on session lifecycle instead of browser-only heuristics.
4. Let the UI render native session truth directly.

This keeps delivery speed reasonable while creating a clean seam for a future native AppKit shell if we ever need one.

## Native Session Model

Each session should carry native-facing state beyond a single `active` boolean:

- `detected`: the app has a discoverable Core Audio process object
- `running`: macOS reports the process as currently running output
- `audible`: macOS reports the process as audible
- `has_recent_signal`: Waves observed recent signal through a tap
- `has_recent_render`: Waves observed recent rendering through a tap
- `last_seen_at`: last successful native discovery timestamp
- `last_signal_at`: last signal timestamp when available
- `visibility`: live, recent, pinned, hidden-idle, or unsupported

The backend should derive these fields. The frontend should not infer them from sparse snapshot data.

## Discovery And Control

- Discover all eligible process-backed sessions, not just browser-like sessions.
- Normalize helper-backed sessions back to a stable app identity.
- Create tap sessions for controllable, user-facing apps when they first appear and retain them for a grace period.
- Use real render and signal observations to decide whether a session is live or recent.
- Keep sessions visible for a short native hold window after activity stops.
- Mark sessions as read-only only when control truly cannot be attached, not merely because the current poll landed during a quiet moment.

## Menu Bar And Window Behavior

- Always create the macOS tray with an actual icon, not title-only presentation.
- Treat the icon as a template image on macOS so it renders like a native menu bar extra.
- Keep the Dock-visible hybrid behavior, but use predictable hide/show logic that works for both Dock reopen and menu bar clicks.
- Make top bar mode a compact utility surface backed by the same native state rather than a special discovery path.

## Frontend State Rules

- Render sections from native visibility state and recent timestamps, not from ad hoc UI timers alone.
- Show live first, then recent/pinned idle, then hidden detected sessions.
- Display read-only or degraded states without removing the app from view.
- Keep diagnostics visible only when native state is degraded.
- Reduce fake waveform motion. Motion should mainly smooth native peaks instead of inventing them.

## Validation

- Menu bar item appears reliably on launch and after reopen.
- Starting playback in browsers, media apps, and chat apps surfaces a row quickly.
- Stopping playback leaves the row visible briefly, then settles to idle.
- Idle detected sessions can still appear in the hidden section instead of vanishing.
- Output device switching remains reliable and independent from mixer refreshes.
- Bun tests, TypeScript checks, and Rust checks remain green.

## Implementation Order

1. Stabilize the macOS tray and window hide/show behavior.
2. Extend the native session model and serialization.
3. Rework macOS tap lifecycle so all eligible sessions can be measured and controlled.
4. Refactor the React app to consume richer native state.
5. Add tests around visibility grouping and shell behavior assumptions.
