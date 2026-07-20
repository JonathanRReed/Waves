# Privacy

Waves is designed to be private by default. It is a local macOS utility. It has
no account, analytics, or telemetry.

## What Waves accesses

- **App audio (Core Audio process taps).** To apply per-app volume, mute, boost,
  EQ, and adaptive mixing, Waves taps the audio of apps you choose and replays it
  to your output device. **Audio is processed locally and in real time on your
  Mac. It is never recorded, stored, or transmitted.** On first run, Waves shows
  its local privacy setup and does not start the audio backend or attempt capture
  until you consent. macOS may then ask for audio-capture permission when the
  process-tap capability is first used. Adaptive Mix retains only transient
  loudness and voice-band energy values, never audio samples.
- **Running applications.** Waves lists your running apps (names and icons) so it
  can show them in the mixer.
- **Audio output devices.** Waves reads available output devices to show the
  current device and, optionally, switch it.
- **Accessibility (optional).** Only required if you enable global keyboard
  shortcuts. While enabled, Waves listens for system-wide key presses but ignores
  everything except its supported shortcuts and does not store or transmit
  keystrokes. Per-app routing works without it.

## What Waves stores

Locally, in `~/Library/Application Support/Waves/` (or `~/.Waves` as a fallback):

- Your preferences, profiles, per-app EQ and adaptive role settings, per-device
  volume settings, and the last session.

These can include app names, bundle identifiers, route state, selected output
device identifiers, diagnostic notes, and your volume/mute/boost choices. They
never leave your Mac.

`Copy Diagnostics` places a bounded current report on the general pasteboard.
It contains no audio samples, but can include the Waves version/build, macOS
version, structured capture-authorization state, app and device names or
identifiers, route states, persistence/cleanup status, and bounded error text.
Fields with potentially identifying values are labelled in the report. Review
and redact it before sharing.

## Update checks

Waves makes no network request before you start an update check or allow
automatic checks. An allowed check fetches the signed appcast from
`https://waves.jonathanrreed.com/appcast.xml`. The request sends no account,
device identifier, audio, diagnostics, or telemetry. If you accept an update,
Sparkle downloads the signed update listed in that appcast. Automatic checks can
be turned off in General Settings.

## What Waves does **not** do

- No telemetry, analytics, crash reporting, or tracking.
- No network requests except update checks and update downloads you request.
- No recording or transmission of any audio.

## Permissions summary

| Permission | Why | Required? |
| --- | --- | --- |
| Audio capture | Per-app volume, mute, boost, EQ, and adaptive mixing via process taps | Yes, for control |
| Accessibility | Global keyboard shortcuts | Optional |

Questions or concerns: please open an issue.
