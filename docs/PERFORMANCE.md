# Launch performance measurement

This procedure tests whether a backend-confirmed Waves control change finishes at least 150 ms before the Dock icon settles. A set qualifies only when attempts 1 through 30 all have complete, internally consistent evidence. At least 29 controls must finish before Dock settlement. The nearest-rank p95 of `controlConfirmedNs - dockSettledNs` must be no greater than `-150000000`.

## Fixed fixture

Use the signed, installed release candidate with normal returning-user preferences. Keep the same Mac, macOS version, display setup, power source, Dock settings, audio route, and foreground app for all 30 attempts. Start a real audio app and play audible material through a route that Waves manages. Record the audio app and version, audio device, Waves route, macOS version, and Mac model beside the result set.

Do not change Dock animation preferences, delete Waves preferences, clear application support data, or use an empty test account. Close Waves yourself before each attempt. The collector will not terminate a process because it cannot safely assume that another process named Waves belongs to this test.

A cold launch means no Waves process is running when the collector invokes `open -na` on the verified candidate. It does not mean erased user state or a purged operating-system disk cache. Rebooting, purging caches, or changing preferences creates a different fixture and needs a new set.

## Evidence sidecar

Start an external recorder before the collector. It must preserve the actual video or other source files and write a new observation sidecar during the attempt. The sidecar records timestamps in the source clock, not invented Mach timestamps:

```json
{
  "sourceClock": {"name":"video-timescale","ticksPerSecond":60000},
  "conversionMethod": "linear-interpolation",
  "syncPairs": [
    {
      "eventID":"sync-start",
      "sourceTicks":1200,
      "machContinuousTicks":2631742723521,
      "sourceEvidenceFile":"/absolute/path/run-01.mov",
      "sourceEvidenceLocator":"frame 72, visible marker sync-start",
      "machEvidenceFile":"/absolute/path/run-01-sync.jsonl",
      "machEvidenceLocator":"line 1",
      "machCaptureCommand":"/usr/bin/ruby sync-marker.rb sync-start run-01-sync.jsonl",
      "sourceUncertaintyTicks":1,
      "machUncertaintyTicks":240000
    },
    {
      "eventID":"sync-end",
      "sourceTicks":61200,
      "machContinuousTicks":2631766723521,
      "sourceEvidenceFile":"/absolute/path/run-01.mov",
      "sourceEvidenceLocator":"frame 3672, visible marker sync-end",
      "machEvidenceFile":"/absolute/path/run-01-sync.jsonl",
      "machEvidenceLocator":"line 2",
      "machCaptureCommand":"/usr/bin/ruby sync-marker.rb sync-end run-01-sync.jsonl",
      "sourceUncertaintyTicks":1,
      "machUncertaintyTicks":240000
    }
  ],
  "processStartSourceTicks":2400,
  "firstFrameSourceTicks":8400,
  "dockSettledSourceTicks":48000,
  "evidenceFiles":["/absolute/path/run-01.mov","/absolute/path/run-01-sync.jsonl","/absolute/path/sync-marker.rb"]
}
```

Each pair must name one event observed on both clocks. `sourceEvidenceFile` must be the retained recording, and `sourceEvidenceLocator` must identify the frame or timestamp where the event is visible. `machEvidenceFile` must contain a JSONL object with the same `eventID` and `machContinuousTicks`; `machEvidenceLocator` identifies that line. Both files must appear in `evidenceFiles`. Event IDs must be unique.

Record the exact helper command in `machCaptureCommand` and retain its source. One workable helper calls `mach_continuous_time`, presents the same event ID in the captured window, flushes that presentation, calls `mach_continuous_time` again, and appends the midpoint tick plus the half-span to the JSONL file. Invoke it once near each end of the recording:

```sh
/usr/bin/ruby sync-marker.rb sync-start run-01-sync.jsonl
/usr/bin/ruby sync-marker.rb sync-end run-01-sync.jsonl
```

`sourceUncertaintyTicks` records the frame-selection bound in the source clock. `machUncertaintyTicks` must include the helper's measured call span plus a conservative bound for presenting the marker. Zero is valid only when the acquisition method can prove zero uncertainty. The collector retains these declared bounds in the manifest. It can verify file membership and the matching Mach JSONL record. It cannot prove that the named video frame shows the claimed event or that the declared uncertainty is adequate. A reviewer must inspect those annotations and the retained files.

Use at least two pairs that bracket every process, frame, and Dock milestone. The collector checks the rate of every adjacent pair against the declared source-clock rate and rejects an interval that differs by more than one percent. It linearly interpolates source ticks to raw `mach_continuous_time` ticks, then calls `mach_timebase_info` and converts raw ticks to nanoseconds using `ticks * numerator / denominator`. Raw Mach ticks are not nanoseconds. For example, the timebase measured during development was 125 over 3, but the collector always reads the current host value.

The internal recorder starts its `ContinuousClock` origin in `WavesApp.init`. Its signpost `elapsedNs` fields use that origin. The collector derives the same origin from the PID-bound `ProcessInit` raw Mach timestamp after applying the host timebase. It converts the external process, frame, and Dock observations to that origin. `MainWindowViewAppeared` is only a diagnostic SwiftUI `onAppear` event. It is not process start or an observed first video frame.

The collector accepts the native unified-log schema:

```json
{"eventType":"signpostEvent","signpostType":"event","signpostName":"ProcessInit","eventMessage":"elapsedNs=123456","processID":86122,"processImagePath":"/private/tmp/example/Waves","machTimestamp":2631742727700}
```

`machTimestamp` contains raw Mach ticks. The log stream also emits a non-JSON filter preamble and a terminal count record. The collector retains both but selects only signpost events whose `processID` and canonical `processImagePath` match the exact process created after `open -na`.

## Run an attempt

Hash the main executable. This hash identifies the executable bytes, not app resources, nested frameworks, signatures, the whole app bundle, or the distribution archive.

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

The observation path must not exist before the attempt. The collector first verifies version, build, and executable SHA-256. It refuses a running same-name or exact-path process. It creates `.jsonl.evidence/attempt-N/attempt.json` with `pending` status before starting log collection or launching Waves. This directory is exclusive. An attempt number can never be reused.

The collector waits for the log stream filter preamble before `open -na`, resolves exactly one new PID for the canonical executable path, and binds signposts to that PID and path. Perform one mute or volume change while the Dock icon is bouncing. The real audio backend must emit `FirstControlConfirmed`.

On completion, the attempt directory contains the raw unified log, copied observation sidecar, copied source evidence, and `manifest.json`. The manifest records the PID, executable path, host timebase, synchronization event bindings, per-pair uncertainty, adjacent-pair drift, selected signposts, file hashes, and artifact identity. Its SHA-256 appears in the measurement, `attempt.json`, and the append-only evidence index.

On timeout, malformed evidence, log exit, ambiguous PID, or missing event, the collector marks the attempt failed. It retains the raw log, any available observation and source files, a failure manifest, and an index entry. A hard termination may leave `pending` status. Pending and failed attempts are both non-qualifying. Do not delete them or choose 30 successful attempts from a larger pool. Start a new result set if an infrastructure failure invalidates the experiment.

## Analyze the set

```sh
/usr/bin/ruby script/analyze_launch_measurements.rb \
  .audit/performance/launch-1.7.1-build-19.jsonl
```

A completed measurement extends the base schema with its manifest hash:

```json
{"run":1,"version":"1.7.1","build":19,"artifactSHA256":"...","processStartNs":0,"firstFrameNs":1,"controlConfirmedNs":2,"dockSettledNs":3,"passed":true,"attemptManifestSHA256":"..."}
```

The analyzer requires attempt directories 1 through 30 with no extras. It verifies one artifact identity, every manifest hash and index binding, and one measurement for every completed attempt. It derives pass status from `controlConfirmedNs < dockSettledNs` and rejects a conflicting serialized `passed` value. It also rejects non-integer milestones and impossible process, first-frame, control, or Dock ordering.

Failed, pending, missing, malformed, or unindexed attempts cannot qualify. The analyzer never skips them. It reports nearest-rank p50 and p95 for `controlConfirmedNs - dockSettledNs`. Negative values mean backend confirmation came first.

## Bounded runtime collection

`script/profile_runtime.sh` attaches only to an explicit PID. It requires the canonical executable path, the executable SHA-256, a fixed scenario, a finite duration, a finite sample interval, and a path that does not exist. It checks the PID, path, and hash before and after collection. The script never launches or stops the target.

The scenario vocabulary is:

- `current-state`, a diagnostic snapshot of the current aggregate state
- `steady-0-routes`, `steady-1-route`, and `steady-10-routes`
- `adaptive-eq-off`, `adaptive-on-eq-off`, `adaptive-off-eq-on`, and `adaptive-on-eq-on`
- `route-churn`, `launch-exit`, `device-recovery`, `clean-shutdown`, and `degraded-shutdown`

`--route-count` records an optional aggregate count. It must not contain route, device, or user identifiers. `current-state` does not replace the prescribed 0, 1, and 10 route scenarios.

Run a short diagnostic collection like this:

```sh
PID=12345
EXE=/absolute/path/to/the/running/executable
SHA=$(/usr/bin/shasum -a 256 "$EXE" | /usr/bin/awk '{print $1}')
DEVELOPER_DIR=/Users/jonathanreed/Downloads/Xcode-beta.app/Contents/Developer \
  script/profile_runtime.sh \
  --pid "$PID" \
  --executable "$EXE" \
  --sha256 "$SHA" \
  --scenario current-state \
  --route-count 3 \
  --duration 30 \
  --sample-interval 5 \
  --output /absolute/path/to/new-runtime-evidence
```

The output directory uses mode `0700`; files use mode `0600`. `summary.json` contains schema version `waves-runtime-profile-v1`, scenario and executable identity, requested and actual duration, tool status, samples, sample failures, and explicit missing metrics. Each sample uses monotonic elapsed time and reports numeric CPU percentage, resident bytes, threads, and descriptors. A failed measurement is `null` with a reason. It is never serialized as zero.

When Time Profiler is available, the collector writes its trace under `private-raw/time-profile.trace`. Raw traces, the trace table of contents, notification output, and recorder stderr can contain identifiers. They are private, are not sanitized, and must not be staged. The collector accepts the trace only when the artifact contains data and a bounded `xctrace export --toc` produces valid XML. A timeout kills the recorder process group and marks the tool failed. A partial or unreadable trace is not a successful recording. Xcode 27 does not list an Energy Log template. Power Profiler is not treated as equivalent evidence.

Template discovery has a 45-second deadline because a full Xcode installation can take more than 10 seconds to enumerate templates. The collector registers `notifyutil -1` before launching `xctrace`. It uses notification state to confirm registration before passing `--notify-tracing-started`; spawning the watcher alone is not treated as proof. The recording-start notification has a 60-second deadline. Numeric sampling starts only after that notification. If notification setup or record start fails, Time Profiler fails and the collector preserves numeric-only samples when practical.

The recorder has one absolute deadline of requested duration plus 90 seconds, measured from the `xctrace` command start. This single bound includes native startup, recording, and save. TOC export has a separate 45-second deadline. The five-second limit remains in place for `ps`, `lsof`, trace artifact inspection, and XML validation.

An outer supervisor limits the full command to the requested sampling duration plus 210 seconds. This bound covers identity checks, hashing, template discovery, notification registration and start, sampling helpers, recorder completion, TOC export, and summary generation. On timeout it sends `TERM`, waits three seconds for a failed receipt, then sends `KILL` to the collector group. Recorder cleanup has its own two-second `TERM` deadline before `KILL`; watcher cleanup has a one-second deadline. Neither path signals the target PID. `actualDurationSeconds` measures sampling only. It excludes trace setup and completion.

The collector does not poll Waves diagnostics or collect system-wide logs. Safe process-bound callback duration, deadline miss, overload, wakeup, dirty-memory, and controller telemetry is not established, so these fields remain `null` with reasons. Sampled CPU cannot prove a callback met its deadline. A source audit cannot prove runtime timing.

Analyze a summary with:

```sh
/usr/bin/ruby script/analyze_runtime_profile.rb \
  /absolute/path/to/new-runtime-evidence/summary.json
```

The analyzer reports `complete`, `incomplete`, or `failed` evidence. It never reports a release pass. Missing identity, process-start observation, scenario, or Time Profiler status fails closed. An unavailable profiler makes the evidence incomplete. A failed profiler, invalid numbers, an interrupted collector, an over-buffer callback, or positive deadline-miss or overload counts fail. Missing timing evidence stays incomplete. Requested-duration coverage requires samples across the duration with gaps consistent with the requested interval. The analyzer compares the first and last 15-minute windows only after a two-hour run with adequate count and temporal span. It flags monotonic growth, but does not call that flag a memory leak.
