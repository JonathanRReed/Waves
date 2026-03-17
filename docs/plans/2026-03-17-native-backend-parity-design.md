---
title: Waves native backend parity design
---

## Overview

## Goal

Implement real native per-application session discovery plus volume and mute control on both macOS and Windows, with macOS implemented first and Windows following behind the same shared Rust and Tauri backend contract.

## Constraints

- Keep the existing frontend command surface unchanged.
- Preserve the current `MixerBackend` trait as the shared app-facing seam.
- Maintain UI and API parity across macOS and Windows.
- Avoid expanding scope into routing, EQ, or automation during this pass.

## Architecture

- Keep `src-tauri/src/backend/mod.rs` as the shared orchestration layer.
- Replace the scaffold implementations in `macos.rs` and `windows.rs` with real native adapters.
- macOS should use a real Core Audio based session-control path appropriate for per-app control.
- Windows should use a real WASAPI session-control path for discovery and per-app volume and mute writes.

## Data flow

1. `refresh_sessions` enumerates native sessions and normalizes them into `AppAudioSession` values.
2. `get_mixer_snapshot` returns the last normalized snapshot without changing the frontend model.
3. `set_app_volume` resolves the platform session and writes native volume.
4. `toggle_app_mute` resolves the platform session and writes native mute.
5. Both backends surface unsupported cases through `SessionSupport` and platform notes instead of hiding sessions.

## Error handling

- If a session disappears during an action, return a clear error and require refresh.
- If a session is discoverable but not controllable, keep it visible with a specific reason.
- If macOS native control requires explicit capability or device setup, surface that in backend notes and support reasons.

## Validation

- Keep Bun checks, Rust checks, and production build green.
- Validate that the same frontend flow works on both platforms through the shared command layer.
- Treat native parity as complete only when both macOS and Windows return real session snapshots and real volume or mute writes.
