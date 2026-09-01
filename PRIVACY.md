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
- **Keyboard shortcuts.** Waves registers the exact key combinations you assign
  with the system's own hot-key API. It is handed those combinations and nothing
  else — it does not read, store, or transmit any other keystroke, and it needs
  no Accessibility permission to do this.
- **Wave Link coexistence (only while Elgato Wave Link runs).** When Wave Link
  compatibility is enabled and a code-signature-verified Wave Link process is
  routing audio, Waves connects to Wave Link's local control service over a
  loopback-only WebSocket (`127.0.0.1`) to apply the volume and mute you set.
  To find that service it asks the kernel which local ports the signed Wave
  Link process itself is listening on (the same information `lsof` shows), and
  it connects only to a port that answers as Wave Link. This traffic never
  leaves your Mac, carries only channel volume/mute commands and a channel
  listing, and happens only in response to your controls or an explicit
  connection test in Settings. Diagnostics you copy may include Wave Link's
  channel names and the bundle identifiers of the apps assigned to them.

## What Waves stores

Locally, in `~/Library/Application Support/Waves/` (or `~/.Waves` as a fallback):

- Your preferences, profiles, per-app EQ and adaptive role settings, per-device
  volume settings, and the last session.
- `Diagnostics/last-shutdown.json`: a small, bounded record of how Waves last
  shut down, written at quit and replaced each time. When cleanup finishes in a
  degraded state it names the stage that failed, its numeric status, and the app
  identifier involved, so the next launch can explain what went wrong instead of
  losing it with the process. Waves reads it back into the diagnostics report.

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
- No network requests that leave your Mac except update checks and update
  downloads you request. (Wave Link compatibility uses a loopback-only
  connection to Wave Link on the same machine, described above.)
- No recording or transmission of any audio.

## Permissions summary

| Permission | Why | Required? |
| --- | --- | --- |
| Audio capture | Per-app volume, mute, boost, EQ, and adaptive mixing via process taps | Yes, for control |

Waves requests no other permission. In particular it never asks for
Accessibility: global keyboard shortcuts are registered through the system's
hot-key API, which grants no ability to observe anything else.

Questions or concerns: please open an issue.
