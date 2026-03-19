# Reactive Native Mixer Design

Date: 2026-03-19

## Goal

Make Waves the simplest native per-app mixer on macOS while also being the most reactive. It should feel alive, immediate, and utility-like, not like a bloated audio control center.

The product should not try to beat SoundSource on breadth. It should beat SoundSource on clarity, speed, and live-session responsiveness.

## Category Read

- SoundSource wins on breadth: per-app volume, routing, effects, menu bar access, and overall polish.
- Background Music is the strongest open-source reference for per-app control, but it also exposes the technical traps around helper processes, browser sessions, and audio device complexity.
- Volumes Bar, VolumeHub, and AppVolume all point toward the same advantage: simpler surfaces win when they stay focused on live audio and low-friction control.

## Product Principles

- Live first: the default surface shows only active audio sessions plus pinned apps.
- Instant truth: real audio should appear immediately, even if that causes slight layout movement.
- Native calm: the UI should feel like a macOS utility, not a dashboard.
- One-glance control: every visible row should be understandable in under a second.
- Motion with meaning: meters and waveforms should reflect real signal, not decorative pulsing.
- Zero helper clutter: helper processes and low-signal technical sessions stay hidden by default.

## Default Information Architecture

- Primary list: active now.
- Secondary list: pinned but currently idle.
- Optional hidden area: other detected sessions, only when explicitly expanded.
- Top controls: search, output device, shell mode, refresh.
- Diagnostics should not dominate the happy path. They should collapse into a subtle status affordance unless something is wrong.

## Session Behavior Rules

- Show immediately: the moment a real audio session is detected, it enters the active list.
- Stay visible briefly: when audio stops, the row should decay into idle for a short grace period instead of vanishing instantly.
- Pinned always wins: pinned apps remain visible even when idle.
- Hide by default: unpinned idle sessions leave the main surface.
- Promote browser-like apps: Helium, Chrome, Safari, Arc, Brave, Firefox, and similar apps should be treated as likely media hosts, not helper noise.
- De-duplicate aggressively: subprocesses should collapse into one human-readable app row.
- Prefer human identity: always show the app identity, not the helper identity.
- Never fake activity: motion can smooth real signal, but never invent it.

## State Model

- Active: currently producing audio, or inside a short recent-activity hold window.
- Pinned idle: pinned, not currently producing audio.
- Hidden idle: unpinned and no recent activity.
- Read-only active: visible if live, even if direct control is limited.
- Error state: visible only when a discovered session has a real problem.

## Top Bar Behavior

- Top bar opens directly into the active-now plus pinned surface.
- Top bar remains scrollable when many live sources exist.
- New live sources insert immediately near the top.
- Sort order favors:
  - live pinned
  - live unpinned
  - pinned idle
- Within live groups, stronger current activity floats higher.

## Reactivity and Motion

- Waveforms must respond to actual session intensity.
- Motion should have fast attack and slower decay.
- New active sessions should appear instantly with a short insertion animation.
- Sessions leaving the active state should settle into idle instead of popping out harshly.
- Idle pinned rows should feel visually quieter.
- Muted rows should flatten clearly.
- No ambient random pulsing when no live or recent signal exists.

## Visual Simplification

Each row should reduce to:

- app icon
- app name
- live waveform or meter
- volume slider
- mute
- pin

Secondary information should shrink or disappear:

- categories should be removed or heavily de-emphasized
- status pills should be simpler
- explanatory copy should shrink
- diagnostics should stay out of the main visual flow unless there is a problem

## Where Waves Should Win

- faster session appearance
- less clutter in the default view
- more legible at a glance
- more alive-feeling motion tied to real signal
- stronger utility-like top-bar usage

## Where Waves Should Not Compete Yet

- EQ and effects
- advanced routing matrices
- plugin depth
- broad power-user configuration

## Implementation Shape

### Remove or reduce

- persistent idle clutter from the default surface
- prominent category labels
- repeated onboarding copy in the normal path
- large diagnostics blocks unless discovery fails
- decorative waveform motion that is not tied to real activity

### Add or improve

- active-now primary section
- pinned-idle secondary section
- recent-activity hold window for session stability
- real-signal waveform smoothing
- instant insertion of newly active sessions
- stronger browser-like app heuristics in native discovery
- top-bar-specific layout tuned for fast scanning and short interactions

### Behavioral priorities

1. Make live-session discovery trustworthy and immediate.
2. Reduce the default surface to active now plus pinned.
3. Make waveform motion reflect real activity with premium smoothing.
4. Tighten the top-bar interaction model around fast scanning and one-step control.
5. Push diagnostics and edge-case UI out of the happy path.

## Success Criteria

- A new real audio source appears immediately.
- A live row looks alive because of real signal, not ambient animation.
- The default view can be scanned in one glance.
- Helper-process clutter is hidden by default.
- Top bar feels like a native audio utility, not a shrunken app window.
- Waves feels faster and calmer than broader alternatives, even with fewer features.
