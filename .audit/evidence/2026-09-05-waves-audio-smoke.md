# Waves premerge audio smoke checks

Checked September 5, 2026 on the local Mac. Both the installed baseline and
the existing 1.7.1 development package completed the tested volume and mute
flow. This is not candidate, hardware, or Half Bounce qualification.

## Fixture

Jonathan selected YouTube in Helium as the test source. The test used Helium
0.16.4.1 and Lofi Girl's video `CFGLoQIhmow`, with the existing MacBook Pro
Speakers output and returning-user Waves state. Waves showed three managed
routes and one live source, Helium. External socket and URL control remained
disabled. No new control permission was enabled.

The original preferences and session files were copied into the private
directory `/tmp/waves-audio-fixture.JP2g26` before testing. They were not
reset or restored wholesale. Only the tested Helium controls were changed,
then returned to 100 percent and unmuted.

## Installed baseline

Target: `/Applications/Waves.app`, version 1.7.0 build 16. Executable SHA-256:
`80d21dd3e0ecccdac92d662bad39fb826398441ec7ce2bfd5c104c1199b8855a`.

Native UI observations:

- Helium was live and managed, with Ready routing status.
- Decrementing its accessible volume control produced the confirmation
  `Managed route active. Helium set to 95%`.
- Clicking its mute control produced `App muted. Helium`, and the combined
  meter dropped to zero.
- Unmuting and restoring volume produced the 100 percent confirmation,
  Unmuted state, and a nonzero live meter.

The earlier process, PID 80368, became inaccessible to native UI inspection
after the profiling work. Its identity was rechecked before sending TERM.
It exited within the ten-second bound. A normal relaunch restored UI access.
This does not establish a Waves root cause or prove graceful application
shutdown. The subsequently tested baseline quit normally through its UI.

## Development build

Target:
`/tmp/waves-package-verification.Mldvxc/checkout/dist/Waves.app`.
Version 1.7.1 build 19, embedded source revision
`64daff18863623cba84809f8357e3a2ed2eddafa`. Executable SHA-256:
`d7e111ee1eec3119102dcab23d2a7e92b3e30787cdc97589b9fa31ad21b0d27a`.

The existing package passed `codesign --verify --deep --strict` before launch.
Its signature is ad hoc, not a Developer ID or notarization receipt. A fresh
Git comparison found no changes in `Sources`, `Package.swift`, or
`Package.resolved` between its source revision and branch revision
`3f70ce721b17149d85c82b010fcc85897cb7c6cf`. That establishes the compared
application inputs, not identity of the entire release build recipe.

The running executable path was independently verified with `ps -ww` for
PID 18198. It was the temporary development package, not the installed app.

The same native controls produced the 95 percent confirmation, mute
confirmation and zero meter, then unmute and 100 percent confirmations with
live metering restored. The development build quit normally through its UI,
and a fresh process check found no Waves process. The persisted Helium row
then reported desiredVolume 1, appliedVolume 1, isMuted false and managed
routing.

After testing, the installed 1.7.0 app was reopened. `ps -ww` confirmed PID
22473 ran `/Applications/Waves.app/Contents/MacOS/Waves`. Its UI showed Ready,
Helium playing, managed routing, 100 percent volume and Unmuted state.

A bounded unified-log capture recorded these events from that exact PID and
executable path:

| Event | elapsedNs |
|---|---:|
| FirstControlSubmitted | 114585313625 |
| FirstControlConfirmed | 114701586625 |

The observed control completed in 116.273 milliseconds after submission.
It happened well after startup. It does not prove cold-launch latency or
completion before Dock settlement. The log collector's 25-second deadline
ended the log process with exit 124 after the events were captured; it did
not terminate Waves.

Private log:
`/tmp/waves-audio-fixture.JP2g26/development-control-signposts.jsonl`.
SHA-256: `a75ff23da296209bf202185983e1bbc64899d46a08b35c82976442f8986cfe63`.

## Profiling limits

The ten-minute current-state run collected 99 numeric samples over
601.066444 seconds, but Time Profiler exceeded its save deadline. The
analyzer classified that evidence as failed. It is not a passing trace or a
qualified hidden-window comparison.

A separate Audio System Trace saved and exported successfully, but its
default rolling-window configuration retained only a ten-second window.
The export contains 752 callback records for PID 80368 across about 2.667
seconds, with an observed maximum duration of 120042 nanoseconds and no
client point-of-interest rows. Its retained scope does not establish a
full-run maximum, a deadline-miss count, or absence of audio errors across
the requested recording.

A follow-up capture with a longer retention window exceeded its 240-second
deadline and was terminated. All failed and partial files remain private.
No further profiling experiment was started after Jonathan questioned the
time spent on this work.

## Release boundary

No application source changed in these checks. No release candidate was
built, signed, notarized, installed on Mac mini, tagged, or published.
The managed deep security audit of revision 3f70ce7 remains in progress on
Mac mini. Jonathan subsequently approved deferring Half Bounce qualification
and exhaustive benchmarks for this maintenance release. Security, practical
audio/regression checks, stability, signing, notarization and physical Mac mini
verification remain required before publication.
