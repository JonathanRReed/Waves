# Performance measurement

Release evidence does not require long soaks or a fixed-count launch protocol.
On 2026-11-14 the release owner retired the 4-, 12- and 72-hour soaks and the
30-run launch-time protocol for good. Each release instead records a short
bounded runtime check of the signed candidate (`gates.boundedRuntimeCheck` in
`docs/RELEASE.md`), with the seconds it actually ran.

Performance comparisons against the previous release are optional. When a
release has none, `benchmarkDeferral` in `release/metadata.json` records the
approval and every `performance` metric is recorded as `deferred`. When a
comparison is worth making, use the collector below on both builds under the
same conditions.

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

The analyzer reports `complete`, `incomplete`, or `failed` evidence. It never reports a release pass. Missing identity, process-start observation, scenario, or Time Profiler status fails closed. An unavailable profiler makes the evidence incomplete. A failed profiler, invalid numbers, an interrupted collector, an over-buffer callback, or positive deadline-miss or overload counts fail. Missing timing evidence stays incomplete. Requested-duration coverage requires samples across the duration with gaps consistent with the requested interval.
