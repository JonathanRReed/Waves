# Per-App EQ and Adaptive Mixing Implementation Plan

Design: `docs/superpowers/specs/2026-07-13-per-app-eq-adaptive-mixing-design.md`

## Objective

Ship a compact native toolbar, persistent per-app 3-band and 8-band EQ with presets, speech-aware media ducking, and slow loudness balancing without changing manual mixer controls or weakening existing route recovery.

## Task 1: Core EQ Models and Presets

Files:

- Add `Sources/WavesAudioCore/Models/EqualizerSettings.swift`
- Add `Tests/WavesTests/EqualizerSettingsTests.swift`

Work:

1. Write tests for default disabled Flat settings, gain clamping, fixed band metadata, preset curves, Custom transitions, mode-specific curve preservation, and Codable round trips.
2. Implement `EqualizerMode`, `EqualizerPreset`, `AdaptiveAppRole`, `AdaptiveMixMode`, band metadata, and `EqualizerSettings`.
3. Keep every public model `Codable`, `Hashable`, and `Sendable`.

Verification:

- `swift test --filter EqualizerSettingsTests`

## Task 2: Allocation-Free EQ DSP

Files:

- Add `Sources/WavesAudioCore/Audio/EqualizerDSP.swift`
- Add `Tests/WavesTests/EqualizerDSPTests.swift`
- Modify `Sources/WavesAudioCore/Audio/TapDSP.swift`
- Modify `Tests/WavesTests/TapDSPTests.swift`

Work:

1. Write tests for coefficient validity, Flat behavior, shelf and peaking response direction, gain limits, finite output, state continuity across buffers, supported sample formats, and headroom compensation.
2. Implement fixed Direct Form biquad sections with preallocated per-channel state.
3. Implement simple and advanced coefficient generation using the controller sample rate.
4. Smooth coefficient changes without allocating in the render path.
5. Preserve current TapDSP scaling, sanitization, clamping, and metering behavior when EQ is disabled.

Verification:

- `swift test --filter EqualizerDSPTests`
- `swift test --filter TapDSPTests`

## Task 3: Adaptive Mixing Calculations

Files:

- Add `Sources/WavesAudioCore/Audio/AdaptiveMixing.swift`
- Add `Tests/WavesTests/AdaptiveMixingTests.swift`

Work:

1. Write tests for speech threshold, two-frame activation, voice-band ratio, 600 ms hang, duck attack, 900 ms release, silence handling, 3 second RMS average, -24 dBFS target, trim limits, correction rates, role mapping, combined clamp, and Off restoration.
2. Implement pure value-state processors for speech detection and loudness trim.
3. Keep timing explicit through elapsed-duration inputs so tests remain deterministic.

Verification:

- `swift test --filter AdaptiveMixingTests`

## Task 4: Backend Protocol and Preview Backend

Files:

- Modify `Sources/WavesAudioCore/Backend/AudioControlBackend.swift`
- Modify `Sources/WavesAudioCore/Backend/PreviewAudioControlBackend.swift`
- Modify `Sources/WavesAudioCore/Models/AudioSessionSnapshot.swift` only if active EQ status must travel with the snapshot
- Update affected preview/backend tests

Work:

1. Add per-app EQ setting, adaptive analysis batch, and adaptive gain batch operations.
2. Define `AdaptiveAnalysisLevels` separately from visible UI meter levels.
3. Make preview behavior deterministic and capable of saved-not-active states.
4. Update every protocol conformer before proceeding.

Verification:

- `swift build`
- `swift test`

## Task 5: Workspace Audio Controller Integration

Files:

- Modify `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`

Work:

1. Store authoritative EQ settings and temporary adaptive gains per logical app ID.
2. Extend controller creation with sample rate, channel layout, EQ settings, and adaptive gain.
3. Apply DSP in the documented render order.
4. Produce pre-adaptive RMS and voice-band energy without retaining audio samples.
5. Dispatch coefficient and adaptive-gain changes on the existing controller callback queue.
6. Reapply EQ and adaptive state during route rebuild and recovery.
7. Release DSP state with controller teardown while preserving logical settings.

Verification:

- `swift build`
- Focused backend and DSP tests

## Task 6: Persistence and AppStore Coordination

Files:

- Modify `Sources/Waves/Stores/UserPreferences.swift`
- Modify `Sources/Waves/Stores/AppStore.swift`
- Modify `Tests/WavesTests/UserPreferencesTests.swift`
- Add or update AppStore tests using the preview backend

Work:

1. Add backward-compatible `appEqualizerSettings` and `adaptiveMixMode` preference fields.
2. Add optimistic per-app EQ mutations, persistence, backend application, and honest saved-not-active results.
3. Add `AdaptiveMixCoordinator` lifecycle independent of UI visibility.
4. Poll analysis every 100 ms only while Adaptive Mix is active.
5. Apply one adaptive-gain batch per update.
6. Return every temporary gain to 0 dB on Off, stop, failure, and cancellation.
7. Keep manual volume, boost, mute, profiles, and per-device presets unchanged.

Verification:

- `swift test --filter UserPreferencesTests`
- Focused AppStore tests

## Task 7: Compact Toolbar and EQ Inspector UI

Files:

- Modify `Sources/Waves/App/WavesApp.swift`
- Modify `Sources/Waves/Features/Mixer/MainWindowView.swift`
- Modify `Sources/Waves/Features/Mixer/MixerRowView.swift`
- Add `Sources/Waves/Features/Mixer/EqualizerInspectorView.swift`
- Modify `Sources/Waves/Features/Mixer/MenuBarMixerView.swift`

Work:

1. Apply compact unified toolbar styling.
2. Remove duplicate New Profile and Recover Routes toolbar items while preserving their existing sidebar, command, and route-health paths.
3. Add the Adaptive Mix menu and active-state accessibility value.
4. Add per-row EQ buttons and a selection-driven native inspector.
5. Implement Simple and Advanced controls, presets, Reset to Flat, adaptive role, route state, keyboard support, and VoiceOver labels.
6. Add menu-bar context action that opens and focuses the selected app's inspector in the main window.
7. Keep compact rows compact and avoid embedding advanced controls in the popover.

Verification:

- `swift build`
- `swift test`
- Rendered main-window and menu-bar inspection

## Task 8: Canonical Feature Tracking

Files:

- Modify `docs/feature-status.json`
- Regenerate `FEATURE_STATUS.csv`

Work:

1. Add user stories and acceptance criteria for toolbar density, per-app EQ, presets, saved-not-active behavior, adaptive roles, Speech Focus, Loudness Balance, Both mode, persistence, route recovery, accessibility, and privacy.
2. Record actual verification evidence after tests and rendered QA.
3. Regenerate the CSV from the JSON source of truth.

Verification:

- `python3 script/feature_tracker.py render`
- `python3 script/feature_tracker.py stats`

## Task 9: Full Validation and Rendered QA

Commands:

- Confirm no project lint configuration exists, or run the configured lint command if one is present.
- `swift build`
- `swift test`
- `./script/build_and_run.sh --verify`
- `git diff --check`

Rendered checks:

1. Compact toolbar height and action placement.
2. Inspector open, close, app switching, and window resizing.
3. Simple and Advanced sliders, presets, Custom state, and Reset to Flat.
4. Keyboard, VoiceOver labels, increased contrast, light appearance, dark appearance, and Reduce Motion.
5. Menu-bar handoff to the correct app.
6. Saved-not-active and excluded-app states.
7. Live voice plus media behavior for Speech Focus, Loudness Balance, Both, and Off.
8. Manual sliders and saved profile values remain unchanged while adaptive gains operate.

Completion requires every acceptance criterion in the design spec to have direct code, test, tracker, or rendered evidence.
