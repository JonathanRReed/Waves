# Per-App EQ and Adaptive Mixing Design

Date: 2026-07-13
Status: Approved for implementation planning

## Summary

Waves will add per-app equalization and two independent adaptive mixing modes while preserving its compact, native macOS mixer behavior. Each manageable app receives a simple 3-band EQ, an advanced 8-band EQ, shared presets, and a user-selectable adaptive role. Adaptive Mix adds speech-aware media ducking and slow loudness balancing. Both adaptive modes operate through temporary gain offsets, so they never overwrite manual volume, mute, boost, EQ, profile, or per-device settings.

The main window toolbar will use the compact unified macOS style. Duplicate profile and route-recovery actions will be removed from the toolbar because those actions already exist in the sidebar and route-health UI.

## Goals

- Make the main toolbar compact, native, and visually quiet.
- Let users shape each managed app independently with a simple or advanced EQ.
- Make voice calls and media coexist without requiring repeated manual slider changes.
- Balance simultaneous sources without visibly moving or rewriting user controls.
- Preserve route recovery, persistence compatibility, accessibility, and real-time audio safety.
- Keep the common mixer flow fast and keep advanced controls progressively disclosed.

## Non-Goals

- Replacing Waves with a DAW, plugin host, or master-bus audio workstation.
- Capturing microphone audio or transcribing speech.
- Performing semantic or machine-learning speech recognition.
- Adding third-party production dependencies.
- Storing EQ inside profiles in this release.
- Providing user-editable crossover frequencies, Q values, attack times, release times, or loudness targets in this release.
- Combining multiple applications into one new virtual master output graph.

## Toolbar

The main `Window` scene will use `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`. The toolbar will contain two global controls:

1. An Adaptive Mix menu with Off, Speech Focus, Loudness Balance, and Both.
2. Refresh, retaining its existing progress and accessibility behavior.

New Profile remains available through the sidebar add button and Command-N. Recover Routes remains available through the actionable route-health indicator. Removing those duplicate toolbar buttons reduces visual noise without removing capability.

Rendered verification will compare `unifiedCompact(showsTitle: false)` with `unifiedCompact` if hiding the title harms window identity or sidebar balance. The compact height is mandatory; title visibility is the only visual detail that may change during rendered verification.

## Per-App EQ Interaction

Each full mixer row gains an EQ button after Boost and before Mute. The button opens a native right-side inspector for that app. Selecting another EQ button replaces the inspector content without opening another window or sheet. Closing the inspector returns the main window to the current mixer width.

Compact menu-bar rows do not embed EQ controls. Their context menu includes `Open EQ in Waves`, which opens the main window, focuses the app's current source, selects the app, and presents its EQ inspector.

The inspector contains:

- App icon and display name.
- EQ enabled toggle.
- Simple and Advanced segmented picker.
- Preset menu.
- Horizontal band sliders with labels, current dB values, and keyboard adjustment.
- Reset to Flat action.
- Adaptive role picker with Auto, Voice, Media, and Ignore.
- An honest route state message when saved settings are not currently active.

EQ is disabled and Flat by default. Enabling EQ or changing a band enrolls a routable app into managed routing, matching the existing volume and mute behavior. Excluded apps show disabled controls and explain that Waves does not alter their audio.

## EQ Bands and Presets

Simple mode uses three fixed bands:

| Label | Filter | Center or corner frequency |
| --- | --- | --- |
| Low | Low shelf | 120 Hz |
| Mid | Peaking | 1.5 kHz |
| High | High shelf | 6 kHz |

Advanced mode uses eight fixed peaking bands at 60 Hz, 120 Hz, 250 Hz, 500 Hz, 1 kHz, 2 kHz, 4 kHz, and 8 kHz. Every band supports -12 dB through +12 dB. The implementation uses fixed, musically conservative Q values defined centrally with the band metadata.

Presets are available in both modes. Selecting a preset writes the corresponding curve for the current mode. Switching modes preserves each mode's last custom curve rather than projecting and overwriting it.

| Preset | Intent |
| --- | --- |
| Flat | No tonal change |
| Voice Focus | Reduce low rumble and upper distraction, emphasize speech presence |
| Warm | Add restrained low-mid weight and soften the highest band |
| Bass Reduce | Reduce low-frequency competition with voice and effects |
| Treble Soften | Reduce sharp upper-frequency content |

Moving any band after selecting a preset changes the displayed preset to Custom. Reset to Flat changes every band in the active mode to 0 dB.

## Persistent Models

New public value types in `WavesAudioCore` will define:

- `EqualizerMode`: simple or advanced.
- `EqualizerSettings`: enabled state, current mode, simple gains, advanced gains, selected preset, and adaptive role.
- `EqualizerPreset`: Flat, Voice Focus, Warm, Bass Reduce, Treble Soften, and Custom.
- `AdaptiveAppRole`: Auto, Voice, Media, or Ignore.
- `AdaptiveMixMode`: Off, Speech Focus, Loudness Balance, or Both.

`UserPreferences` will store an `appEqualizerSettings` dictionary keyed by logical app ID and the global `adaptiveMixMode`. Decoding uses independent fallback defaults so existing preferences remain valid. Unknown or missing values load as EQ disabled, Flat, Auto role, and Adaptive Mix Off.

EQ settings remain attached to logical app identity across process churn, app restarts, route recovery, and Waves relaunches. Profiles remain unchanged and continue to capture volume, mute, and boost only.

## Backend Contract

`AudioControlBackend` will add operations to set per-app EQ settings, read per-app adaptive analysis values, and apply a batch of per-app adaptive gains. Applying gains as one batch avoids creating a separate task for every active app on each adaptive update. The preview backend will implement the same contract so UI flows and store tests do not depend on live Core Audio routes.

`WorkspaceAudioControlBackend` will retain authoritative per-app EQ settings and temporary adaptive gains alongside existing desired volume, mute, boost, and target-device state. Route creation and route recovery apply the stored EQ and adaptive state before the controller begins emitting output.

Changing EQ on a monitor-only but routable app requests a managed route. If the route cannot be created, the setting remains persisted for future use and the UI reports `Saved, not active` instead of claiming that audio changed.

## Real-Time DSP

Each managed controller receives a preallocated equalizer processor that supports up to eight biquad sections per channel. Filter coefficients and channel delay state are created outside the audio callback. Coefficient changes are dispatched onto the controller's existing serial callback queue, which prevents concurrent mutation while an IO callback is processing.

The render path remains allocation-free. It performs these operations in order:

1. Copy tapped input into the output buffer.
2. Sanitize non-finite samples.
3. Apply the enabled EQ sections.
4. Apply automatic EQ headroom compensation.
5. Apply manual volume and boost.
6. Measure the pre-adaptive RMS and voice-band energy used by Adaptive Mix.
7. Apply the temporary adaptive gain.
8. Clamp to the sample format's valid output range.
9. Measure final output peak and RMS for live UI meters.

Automatic EQ headroom compensation offsets the highest positive band gain. It prevents an EQ boost from adding equivalent full-band gain before the existing output clamp. Coefficient transitions are smoothed over a short fixed interval to prevent zipper noise and clicks.

The processor supports the tap's existing Float32, Int16, and Int32 formats. Flat, disabled EQ with 0 dB adaptive gain preserves the current render behavior and output within the existing sanitization and clamping rules.

## Speech Focus

Speech Focus identifies source apps through `AdaptiveAppRole`:

- Voice always participates as a speech source.
- Media is eligible for ducking.
- Ignore is excluded from all adaptive analysis and gain changes.
- Auto maps known conferencing apps to Voice and known media apps to Media. Other categories remain neutral for speech ducking.

The backend reports full-band RMS and voice-band energy for managed Voice sources. An `AdaptiveMixCoordinator` evaluates those values every 100 milliseconds while Adaptive Mix is not Off. This task is independent of the visibility-gated UI meter poll, so adaptive behavior continues while the main window and menu-bar panel are closed. The task stops and releases its analysis state when Adaptive Mix is Off.

Speech becomes active after two consecutive analysis frames at or above -42 dBFS whose voice-band energy is at least 55 percent of full-band energy. A 600 millisecond hang prevents pauses between words from releasing the duck. Ducking gain reaches its target over 120 milliseconds and returns to 0 dB over 900 milliseconds. These are fixed product constants in this release. This is an output-audio heuristic. It does not use microphone input and does not identify words or speakers.

When speech becomes active, eligible Media apps receive a target duck of -10 dB. Gain moves toward that target with a fast attack. After speech ends, a short hang prevents rapid toggling, then gain returns smoothly with a slower release. The UI does not move the app's manual volume slider.

If no managed Voice source is available, Speech Focus performs no ducking. It never infers speech from an app name alone when no usable audio analysis exists.

## Loudness Balance

Loudness Balance uses a 3 second exponential average of each eligible managed app's pre-adaptive RMS, measured after EQ, headroom compensation, manual volume, and boost. Measuring before the temporary adaptive gain prevents the controller from chasing its own correction. The target is -24 dBFS. Sources below -50 dBFS are treated as silent and receive no positive trim.

The controller target is a conservative shared listening level. Adaptive trim is limited to:

- At most -6 dB reduction for a loud source.
- At most +3 dB increase for a quiet active source.
- Downward correction changes by at most 1 dB per second.
- Upward correction changes by at most 0.5 dB per second.

Ignore apps do not participate. Voice, Media, and Auto apps participate when they are managed and active. Loudness Balance does not alter manual volume, saved profiles, or per-device volume presets.

## Combined Mode

Both mode adds the Speech Focus and Loudness Balance gain offsets. The combined temporary gain is clamped to -18 dB through +3 dB. Speech sources are never ducked by Speech Focus, though Loudness Balance may apply a conservative trim. Media can receive both its loudness trim and the speech duck.

Changing Adaptive Mix mode recalculates all affected targets immediately and transitions smoothly. Turning the mode Off returns every adaptive gain to 0 dB without changing stored manual controls.

## State Flow

1. The user changes EQ, preset, adaptive role, or global Adaptive Mix mode.
2. `AppStore` updates observed state immediately and persists preferences.
3. `AppStore` sends the relevant operation to `AudioControlBackend`.
4. The backend applies settings to an existing controller or creates a managed route when permitted.
5. The controller updates DSP coefficients or adaptive gain on its callback queue.
6. While Adaptive Mix is active, `AdaptiveMixCoordinator` reads one batch of analysis values every 100 milliseconds, updates speech and loudness state, and sends one batch of temporary gains to the backend.
7. The next session refresh or route recovery reconstructs the same state from persisted logical app settings.
8. UI status reflects whether the setting is active, saved for later, excluded, or failed.

## Error Handling

- Excluded app: controls are disabled with an explanation. No route is created.
- Unsupported or unroutable app: settings persist, UI shows `Saved, not active`, and no false success toast appears.
- Route creation failure: keep the settings, merge the backend state, show one actionable error toast, and retain the app's prior audio path.
- Coefficient validation failure: reject non-finite or out-of-range gains, keep the last valid coefficients, and log the validation error.
- Route recovery: rebuild the route with volume, mute, boost, EQ, adaptive gain, and target device before marking it managed.
- App termination: release real-time resources while retaining logical app settings.
- Adaptive source loss: transition all affected ducking gains back to 0 dB.
- Adaptive coordinator cancellation or failure: send one 0 dB gain batch before stopping so no temporary attenuation remains stranded.
- Preference decoding failure: use backward-compatible defaults and preserve the existing corrupt-file backup behavior.

## Accessibility

- Every EQ button identifies the target app and whether EQ is enabled.
- Band sliders announce the app, frequency label, and signed dB value.
- Preset, mode, adaptive role, and Adaptive Mix controls use native labels and keyboard navigation.
- Inspector route status is expressed in text and not color alone.
- All motion and value transitions respect Reduce Motion. Audio gain smoothing remains active because it prevents audible artifacts rather than serving as visual animation.
- Menu-bar `Open EQ in Waves` remains available through keyboard and VoiceOver context actions.

## Security and Privacy

- Adaptive analysis operates only on the output buffers already processed by managed Waves routes.
- No audio samples, spectral data, or speech events are written to disk or sent over the network.
- Preferences contain only numeric EQ settings, mode selections, roles, and logical app identifiers.
- Existing private directory and file permissions continue to protect persisted settings.
- No new entitlement, permission, network request, secret, or production dependency is introduced.

## Validation

Unit tests will cover:

- Biquad coefficient validity and finite output across all supported sample formats.
- Flat and disabled EQ behavior.
- Simple and advanced preset curves.
- Band gain clamping and invalid-value rejection.
- Filter state continuity across audio buffers.
- Coefficient smoothing without non-finite output.
- Automatic headroom compensation.
- Backward-compatible preference decoding.
- Equalizer setting and adaptive-role persistence by logical app ID.
- Route recovery reapplying EQ and adaptive gain.
- Speech threshold, hysteresis, hang, attack, and release behavior.
- Loudness silence floor, trim limits, and slow convergence.
- Combined gain clamping and Off-mode restoration.

Project validation will run:

- The project's lint command if one is added before implementation completes. The current repository has no SwiftLint or swift-format configuration.
- `swift build`
- `swift test`
- `./script/build_and_run.sh --verify`
- `git diff --check`

Rendered verification will inspect toolbar height, inspector layout, band slider keyboard behavior, preset changes, saved-not-active messaging, menu-bar handoff, light and dark appearance, increased contrast, and Reduce Motion. Live audio verification will use at least one conferencing or voice source and one media source to confirm that both adaptive layers change audible output without moving manual controls.

## Planned File Boundaries

Expected new files:

- `Sources/WavesAudioCore/Models/EqualizerSettings.swift`
- `Sources/WavesAudioCore/Audio/EqualizerDSP.swift`
- `Sources/WavesAudioCore/Audio/AdaptiveMixing.swift`
- `Sources/Waves/Features/Mixer/EqualizerInspectorView.swift`
- `Tests/WavesTests/EqualizerDSPTests.swift`
- `Tests/WavesTests/AdaptiveMixingTests.swift`

Expected modified files:

- `Sources/Waves/App/WavesApp.swift`
- `Sources/Waves/Features/Mixer/MainWindowView.swift`
- `Sources/Waves/Features/Mixer/MixerRowView.swift`
- `Sources/Waves/Features/Mixer/MenuBarMixerView.swift`
- `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`
- `Sources/Waves/Services/Persistence/PreferencesStore.swift`
- `Sources/Waves/Stores/AppStore.swift`
- `Sources/Waves/Stores/UserPreferences.swift`
- `Sources/WavesAudioCore/Audio/TapDSP.swift`
- `Sources/WavesAudioCore/Backend/AudioControlBackend.swift`
- `Sources/WavesAudioCore/Backend/PreviewAudioControlBackend.swift`
- `Tests/WavesTests/UserPreferencesTests.swift`
- `Tests/WavesTests/TapDSPTests.swift`
- `docs/feature-status.json`
- `FEATURE_STATUS.csv`

File boundaries may be narrowed during implementation, but behavior and ownership defined in this design remain fixed unless the design is revised and approved.

## Acceptance Criteria

- The main toolbar renders with compact macOS height and no duplicate New Profile or Recover Routes actions.
- A user can enable, edit, reset, and persist a 3-band or 8-band EQ for a managed app.
- Presets work in both modes and become Custom after manual edits.
- EQ and adaptive controls never alter visible manual volume sliders or saved profile values.
- Speech Focus audibly lowers eligible media during detected conferencing speech and restores it smoothly afterward.
- Loudness Balance converges within its documented limits without raising silence.
- Both mode combines the behaviors within the total gain clamp.
- Excluded, unsupported, and failed routes communicate their actual state without claiming success.
- Route recovery restores EQ and adaptive behavior.
- Existing volume, mute, boost, device routing, profile, and menu-bar behaviors continue to pass their tests.
- The rendered inspector is keyboard-operable, VoiceOver-labeled, and usable in supported accessibility appearances.
