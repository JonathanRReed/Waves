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
    {"sourceTicks":1200,"machContinuousTicks":2631742723521},
    {"sourceTicks":61200,"machContinuousTicks":2631766723521}
  ],
  "processStartSourceTicks":2400,
  "firstFrameSourceTicks":8400,
  "dockSettledSourceTicks":48000,
  "evidenceFiles":["/absolute/path/run-01.mov"]
}
```

Each synchronization pair must come from one event observed on both clocks. Record how the event was produced and identified. Use at least two pairs that bracket every process, frame, and Dock milestone. The collector linearly interpolates source ticks to raw `mach_continuous_time` ticks. It then calls `mach_timebase_info` and converts raw ticks to nanoseconds using `ticks * numerator / denominator`. Raw Mach ticks are not nanoseconds. For example, the timebase measured during development was 125 over 3, but the collector always reads the current host value.

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

On completion, the attempt directory contains the raw unified log, copied observation sidecar, copied source evidence, and `manifest.json`. The manifest records the PID, executable path, host timebase, synchronization pairs, selected signposts, file hashes, and artifact identity. Its SHA-256 appears in the measurement, `attempt.json`, and the append-only evidence index.

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
