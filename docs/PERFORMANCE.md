# Launch performance measurement

This procedure measures whether a backend-confirmed Waves control change finishes at least 150 ms before the Dock icon settles. A qualifying set contains exactly 30 launches of one executable, at least 29 successful launches, and a nearest-rank p95 of `controlConfirmedNs - dockSettledNs` no greater than `-150000000`.

## Test fixture

Use the signed, installed release candidate with normal returning-user preferences. Keep the same Mac, macOS version, display setup, power source, Dock settings, audio route, and foreground app across all 30 runs. Start a real audio app and keep it playing audible material through a route that Waves manages. Record the app name, app version, audio device, Waves route, macOS version, and hardware in the run notes stored beside the JSONL file.

Do not change Dock animation preferences, delete Waves preferences, clear application support data, or use an empty test account. Close Waves before each run. The collector refuses to terminate it because a process with the same name may belong to another app or another Waves build.

A cold launch means no Waves process is running before `open -na` starts the verified candidate. It does not mean erased user state or a cold operating-system disk cache. Rebooting, purging caches, and changing preferences create a different fixture and need a separate 30-run set.

## External observations and clocks

The internal recorder starts its `ContinuousClock` origin in `WavesApp.init`. Its `ProcessInit`, `MainWindowViewAppeared`, and `FirstControlConfirmed` signposts report nanoseconds elapsed from that origin. `MainWindowViewAppeared` is SwiftUI `onAppear`; it is not a measured first video frame and is not process start.

An external observer must record process start, the first visibly rendered frame, and the end of the final Dock bounce. Use an unedited screen recording or another independently recorded source whose timestamps are expressed as Mach continuous-time nanoseconds. Save an observation JSON file during the launch:

```json
{
  "clock": "machContinuousTimeNanoseconds",
  "processStartMachContinuousNs": 104200000000,
  "firstFrameMachContinuousNs": 104350000000,
  "dockSettledMachContinuousNs": 104900000000,
  "processStartEvidenceSHA256": "64 lowercase hexadecimal characters",
  "firstFrameEvidenceSHA256": "64 lowercase hexadecimal characters",
  "dockSettledEvidenceSHA256": "64 lowercase hexadecimal characters"
}
```

The three evidence hashes identify the immutable source files used for those observations. They do not prove that an observer chose the correct frame. Preserve the files and the method or tool that converted frame or process observations to Mach continuous time. A screen recording alone has a media timeline, not a Mach timestamp. Record a synchronization event visible to the capture and timestamped by the external observer so the conversion is reviewable. If that synchronization is absent, the launch cannot qualify.

The collector reads unified log output with `--style ndjson --signpost --mach-continuous-time`. It computes the internal origin as the Mach timestamp of the real `ProcessInit` log entry minus that entry's `elapsedNs`. It subtracts this origin from each external Mach timestamp. `FirstControlConfirmed` already uses the internal origin. This conversion puts all four exported milestones on the same scale without treating `onAppear`, a fixed delay, or a fabricated timestamp as external evidence.

## Collect a run

Hash the main executable, not the `.app` directory. This value identifies the executable bytes measured by the 30-run set. It is not a hash of resources, signatures, nested frameworks, or the distribution archive.

```sh
APP=/Applications/Waves.app
SHA=$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Waves" | /usr/bin/awk '{print $1}')
script/measure_launch.sh \
  --app "$APP" \
  --output .audit/performance/launch-1.7.1-build-19.jsonl \
  --run 1 \
  --version 1.7.1 \
  --build 19 \
  --artifact-sha256 "$SHA" \
  --observation .audit/performance/run-01-observation.json \
  --timeout 30
```

Start the external observer before invoking the command. It must write the observation path during that run. The collector verifies version, build, and executable SHA-256 before launch, checks that no process named as the candidate executable is running, starts unified-log capture, and calls `open -na`. It appends one record only after parsing the required real observations and signposts.

Perform one mute or volume change in Waves while the Dock icon is bouncing. The real audio backend must confirm it. Repeat with run identities 1 through 30 under the same fixture.

## Failure rules

Keep every attempted launch in the experiment record. Do not silently retry a failed launch or select 30 successes from a larger set. A timeout, launch failure, malformed observation, missing milestone, missing clock synchronization, absent backend confirmation, changed artifact identity, or observer failure makes the attempt incomplete. Investigate it and restart the full controlled set if you cannot encode an honest complete record for that run.

The JSONL analyzer rejects malformed data rather than skipping it:

```sh
/usr/bin/ruby script/analyze_launch_measurements.rb \
  .audit/performance/launch-1.7.1-build-19.jsonl
```

The schema has exactly one record per run:

```json
{"run":1,"version":"1.7.1","build":19,"artifactSHA256":"...","processStartNs":0,"firstFrameNs":1,"controlConfirmedNs":2,"dockSettledNs":3,"passed":true}
```

`passed` means backend confirmation preceded the externally observed Dock settlement. The analyzer reports nearest-rank p50 and p95 for `controlConfirmedNs - dockSettledNs`. Negative values mean confirmation came first. Qualification requires exactly 30 unique run identities, one consistent version, build, and executable hash, at least 29 `passed` values, and p95 no greater than `-150000000` ns.
