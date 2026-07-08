# Privacy

Waves is designed to be private by default. It is a local macOS utility — it has
no account, no analytics, and no servers.

## What Waves accesses

- **App audio (Core Audio process taps).** To apply per-app volume, mute, and
  boost, Waves taps the audio of apps you choose and replays it to your output
  device. **Audio is processed locally and in real time on your Mac. It is never
  recorded, stored, or transmitted.** macOS asks for audio-capture permission
  the first time Waves needs it.
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

- Your preferences, profiles, per-device volume settings, and the last session.

These can include app names, bundle identifiers, route state, selected output
device identifiers, diagnostic notes, and your volume/mute/boost choices. They
never leave your Mac.

`Copy Diagnostics` places the current diagnostic report on the general
pasteboard. That report can include app names, device names, routing state, and
recent error text; only copy it when you intend to share it.

## What Waves does **not** do

- No telemetry, analytics, crash reporting, or tracking.
- No network requests. (If a future release adds opt-in update checks, that will
  be clearly disclosed here.)
- No recording or transmission of any audio.

## Permissions summary

| Permission | Why | Required? |
| --- | --- | --- |
| Audio capture | Per-app volume/mute/boost via process taps | Yes, for control |
| Accessibility | Global keyboard shortcuts | Optional |

Questions or concerns: please open an issue.
