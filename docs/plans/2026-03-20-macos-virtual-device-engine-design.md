# macOS Virtual Device Engine Design

Date: 2026-03-20

## Goal

Implement true per-app volume on macOS without muting or breaking system audio.

Waves should:

- become the active system output path while it is running
- expose real per-app gain and mute controls for output apps
- keep playing through the user-selected physical output device
- restore the prior output device when Waves stops
- surface installation and degradation state honestly in the UI

## Why The Tap Prototype Failed

Core Audio process taps are useful for discovery and metering, but they are not a safe foundation for full per-app attenuation in this app's current architecture.

The previous tap path could suppress audio while tapped and did not provide a correct, always-on route back to the real output device. That made it possible to lose sound entirely.

## Reference Architecture

The implementation direction is based on:

- Apple's Audio Server Plug-In model for user-space Core Audio drivers
- Background Music's split between virtual device and companion app
- libASPL's production-ready HAL plug-in abstraction and client identity model
- Proxy Audio Device's real-device proxying pattern
- Pancake and Roc VAD's separation between hidden audio engine and control surface

## Components

### 1. Waves HAL Driver

A bundled AudioServerPlugIn driver creates the Waves virtual output device.

Responsibilities:

- accept output from macOS apps
- identify connected clients by PID and bundle ID
- maintain per-client gain and mute state
- apply gain during realtime mixing
- emit per-client peaks and recent activity
- send mixed PCM frames to the bridge process
- expose a localhost control API for session discovery and control

### 2. Waves Audio Bridge

A lightweight helper process receives the mixed stream from the driver and plays it to the selected physical output device.

Responsibilities:

- receive mixed frames from the driver with a bounded local buffer
- play audio to the chosen hardware output device
- track underruns and bridge health
- allow target output changes without tearing down the whole app shell

### 3. Waves Desktop App

The Tauri app becomes the controller and installer.

Responsibilities:

- install or update the driver bundle
- start and monitor the bridge
- switch macOS default output to Waves when the engine is enabled
- restore the user's prior output device on shutdown
- query driver sessions and issue per-app volume changes
- show actionable diagnostics if install, routing, or bridge playback is degraded

## Control And Audio Flow

1. Waves starts the bridge and records the current physical output device.
2. Waves ensures the driver is installed and available.
3. Waves sets the system default output device to the Waves virtual device.
4. Apps render to the Waves virtual device.
5. The driver identifies clients, applies per-app gain, mixes audio, and sends PCM frames to the bridge.
6. The bridge outputs those frames to the selected physical device.
7. The UI queries the driver for sessions, peaks, and support state.

## Runtime State Model

macOS sessions should now be derived from driver truth, not process taps:

- detected
- runningOutput
- recentRender
- recentSignal
- lastSeenAt
- lastSignalAt
- volume
- muted
- peakLevel
- support.controllable

Platform state should also include:

- driverInstalled
- driverLoaded
- bridgeRunning
- engineActive
- targetOutputDeviceId
- fallbackReason

## Installation And Recovery

- Bundle the unsigned driver inside the app resources for local testing and manual installation.
- Provide an install command that copies the driver into `/Library/Audio/Plug-Ins/HAL` and restarts `coreaudiod`.
- If the driver is missing or not loaded, keep the app usable but mark macOS control unavailable and explain why.
- On clean shutdown, restore the prior physical output device.
- On next launch, if Waves is still the default output but the bridge is not running, start the bridge first and then restore or reattach as needed.

## Validation

- Playing audio in Safari, Chrome, Firefox, Spotify, Music, and Discord creates live controllable rows.
- Changing one app volume changes only that app.
- Muting one app does not mute unrelated apps or the system.
- Selecting a different hardware output keeps Waves active while rerouting the mixed output correctly.
- Quitting Waves restores the previous default output device.
- Build artifacts include the app, the driver payload, the bridge payload, and the DMG.
