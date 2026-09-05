#!/bin/bash

set -u
set -o pipefail
umask 077
original_args=("$@")

usage() {
  cat >&2 <<'USAGE'
Usage: profile_runtime.sh --pid PID --executable PATH --sha256 HEX --scenario NAME \
  --duration SECONDS --sample-interval SECONDS --output NEW_DIRECTORY [--route-count COUNT]

Scenarios: current-state, steady-0-routes, steady-1-route, steady-10-routes,
adaptive-eq-off, adaptive-on-eq-off, adaptive-off-eq-on, adaptive-on-eq-on,
route-churn, launch-exit, device-recovery, clean-shutdown, degraded-shutdown.
USAGE
  exit 2
}

die() {
  echo "profile_runtime.sh: $*" >&2
  exit 2
}

pid=""
executable=""
expected_sha=""
scenario=""
duration=""
sample_interval=""
output=""
route_count=""

while (($#)); do
  case "$1" in
    --pid) pid=${2-}; shift 2 ;;
    --executable) executable=${2-}; shift 2 ;;
    --sha256) expected_sha=${2-}; shift 2 ;;
    --scenario) scenario=${2-}; shift 2 ;;
    --duration) duration=${2-}; shift 2 ;;
    --sample-interval) sample_interval=${2-}; shift 2 ;;
    --output) output=${2-}; shift 2 ;;
    --route-count) route_count=${2-}; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -n "$pid" && -n "$executable" && -n "$expected_sha" && -n "$scenario" && -n "$duration" && -n "$sample_interval" && -n "$output" ]] || usage
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || die "PID must be a positive integer"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "sha256 must be 64 lowercase hexadecimal characters"
case "$scenario" in
  current-state|steady-0-routes|steady-1-route|steady-10-routes|adaptive-eq-off|adaptive-on-eq-off|adaptive-off-eq-on|adaptive-on-eq-on|route-churn|launch-exit|device-recovery|clean-shutdown|degraded-shutdown) ;;
  *) die "scenario is not in the documented fixed vocabulary" ;;
esac
/usr/bin/ruby -e 'ARGV.each { |value| number = Float(value); exit 1 unless number.finite? && number.positive? }' "$duration" "$sample_interval" || die "duration and sample interval must be finite positive numbers"
if [[ -n "$route_count" ]]; then
  [[ "$route_count" =~ ^[0-9]+$ ]] || die "route count must be a nonnegative integer"
fi
[[ "$output" = /* ]] || die "output must be an absolute path"

if [[ "${WAVES_RUNTIME_INTERNAL:-}" != "1" ]]; then
  outer_timeout=${WAVES_RUNTIME_TEST_OUTER_TIMEOUT:-$(/usr/bin/ruby -e 'puts Float(ARGV.fetch(0)) + 210.0' "$duration")}
  exec /usr/bin/ruby -e '
    timeout = Float(ARGV.shift)
    script = ARGV.shift
    child = Process.spawn({"WAVES_RUNTIME_INTERNAL" => "1"}, "/bin/bash", script, *ARGV, pgroup: true)
    interrupted = nil
    Signal.trap("INT") { interrupted = "INT" }
    Signal.trap("TERM") { interrupted = "TERM" }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      finished = Process.waitpid(child, Process::WNOHANG)
      if finished
        status = $?
        exit(status.exited? ? status.exitstatus : 128 + status.termsig)
      end
      break if interrupted || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    begin
      Process.kill("TERM", -child)
    rescue Errno::ESRCH
    end
    grace = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3.0
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < grace
      finished = Process.waitpid(child, Process::WNOHANG)
      if finished
        status = $?
        exit(interrupted ? 128 + Signal.list.fetch(interrupted) : 124)
      end
      sleep 0.05
    end
    begin
      Process.kill("KILL", -child)
    rescue Errno::ESRCH
    end
    Process.waitpid(child) rescue nil
    warn "profile_runtime.sh: bounded outer deadline expired"
    exit(interrupted ? 128 + Signal.list.fetch(interrupted) : 124)
  ' "$outer_timeout" "$0" "${original_args[@]}"
fi

[[ ! -e "$output" ]] || die "output directory already exists; refusing to reuse or overwrite it"
[[ -f "$executable" ]] || die "executable does not exist: $executable"

canonical_executable=$(/usr/bin/ruby -e 'puts File.realpath(ARGV.fetch(0))' "$executable") || die "cannot resolve executable path"
actual_sha=$(/usr/bin/shasum -a 256 "$canonical_executable" | /usr/bin/awk '{print $1}') || die "cannot hash executable"
[[ "$actual_sha" == "$expected_sha" ]] || die "executable SHA-256 does not match"

process_path() {
  /bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

initial_process_start=""
verify_identity() {
  local observed canonical_observed observed_start
  observed=$(process_path)
  [[ -n "$observed" ]] || return 1
  canonical_observed=$(/usr/bin/ruby -e 'puts File.realpath(ARGV.fetch(0))' "$observed" 2>/dev/null) || return 1
  [[ "$canonical_observed" == "$canonical_executable" ]] || return 1
  [[ $(/usr/bin/shasum -a 256 "$canonical_observed" | /usr/bin/awk '{print $1}') == "$expected_sha" ]] || return 1
  if [[ -n "$initial_process_start" ]]; then
    observed_start=$(/bin/ps -p "$pid" -o lstart= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ "$observed_start" == "$initial_process_start" ]] || return 1
  fi
}

verify_identity || die "PID does not identify the expected executable"
initial_process_start=$(/bin/ps -p "$pid" -o lstart= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[[ -n "$initial_process_start" ]] || die "cannot read target process start identity"
verify_identity || die "PID identity changed during initial verification"

/bin/mkdir -m 700 "$output" || die "cannot create output directory"
raw_dir="$output/private-raw"
/bin/mkdir -m 700 "$raw_dir" || die "cannot create private raw directory"
samples_path="$output/samples.jsonl"
: >"$samples_path"
/bin/chmod 600 "$samples_path"

start_monotonic=""
sampling_end_monotonic=""
interrupted=false
identity_after=true
collector_failure=""
xctrace_pid=""
xctrace_status="unavailable"
xctrace_reason="xctrace or Time Profiler template is unavailable"
xctrace_toc_validated=false
xctrace_start_synchronized=false
xctrace_command_start=""
xctrace_absolute_allowance=${WAVES_RUNTIME_TEST_RECORDER_TIMEOUT:-$(/usr/bin/ruby -e 'puts Float(ARGV.fetch(0)) + 90.0' "$duration")}
xctrace_start_timeout=${WAVES_RUNTIME_TEST_START_TIMEOUT:-60}
xctrace_notification_key=""
notify_pid=""
finalized=false

stop_notify_watcher() {
  if [[ -n "$notify_pid" ]] && /bin/kill -0 "$notify_pid" 2>/dev/null; then
    /bin/kill -TERM "$notify_pid" 2>/dev/null || true
    local stop_start stop_now
    stop_start=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
    while /bin/kill -0 "$notify_pid" 2>/dev/null; do
      stop_now=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
      if /usr/bin/ruby -e 'exit(Float(ARGV[1]) - Float(ARGV[0]) >= 1 ? 0 : 1)' "$stop_start" "$stop_now"; then
        /bin/kill -KILL "$notify_pid" 2>/dev/null || true
        break
      fi
      /bin/sleep 0.05
    done
    wait "$notify_pid" 2>/dev/null || true
  fi
  notify_pid=""
}

stop_xctrace() {
  if [[ -n "$xctrace_pid" ]] && /bin/kill -0 "$xctrace_pid" 2>/dev/null; then
    /bin/kill -TERM -- "-$xctrace_pid" 2>/dev/null || /bin/kill "$xctrace_pid" 2>/dev/null || true
    local stop_start stop_now
    stop_start=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
    while /bin/kill -0 "$xctrace_pid" 2>/dev/null; do
      stop_now=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
      if /usr/bin/ruby -e 'exit(Float(ARGV[1]) - Float(ARGV[0]) >= 2 ? 0 : 1)' "$stop_start" "$stop_now"; then
        /bin/kill -KILL -- "-$xctrace_pid" 2>/dev/null || /bin/kill -KILL "$xctrace_pid" 2>/dev/null || true
        break
      fi
      /bin/sleep 0.05
    done
    wait "$xctrace_pid" 2>/dev/null || true
  fi
  xctrace_pid=""
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap.
finish() {
  local exit_code=$?
  trap - EXIT INT TERM HUP
  stop_notify_watcher
  stop_xctrace
  if [[ "$finalized" == false ]]; then
    if ! finalize_summary; then
      exit_code=2
    fi
  fi
  exit "$exit_code"
}

# shellcheck disable=SC2329 # Invoked by signal traps.
handle_signal() {
  interrupted=true
  collector_failure="collection interrupted by signal"
  stop_notify_watcher
  stop_xctrace
  xctrace_status="failed"
  xctrace_reason="recording stopped because collection was interrupted"
  exit 130
}

finalize_summary() {
  local end_monotonic actual_duration result_status
  end_monotonic=${sampling_end_monotonic:-$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')}
  if [[ -n "$start_monotonic" ]]; then
    actual_duration=$(/usr/bin/ruby -e 'puts(Float(ARGV[1]) - Float(ARGV[0]))' "$start_monotonic" "$end_monotonic")
  else
    actual_duration=0
  fi
  if [[ "$interrupted" == true || "$identity_after" != true || -n "$collector_failure" ]]; then
    result_status="failed"
  else
    result_status="complete"
  fi
  PID_VALUE="$pid" EXECUTABLE_VALUE="$canonical_executable" SHA_VALUE="$expected_sha" PROCESS_START_VALUE="$initial_process_start" SCENARIO_VALUE="$scenario" DURATION_VALUE="$duration" INTERVAL_VALUE="$sample_interval" ACTUAL_VALUE="$actual_duration" STATUS_VALUE="$result_status" INTERRUPTED_VALUE="$interrupted" FAILURE_VALUE="$collector_failure" ROUTE_COUNT_VALUE="$route_count" XCTRACE_STATUS_VALUE="$xctrace_status" XCTRACE_REASON_VALUE="$xctrace_reason" XCTRACE_TOC_VALUE="$xctrace_toc_validated" XCTRACE_SYNC_VALUE="$xctrace_start_synchronized" SAMPLES_VALUE="$samples_path" OUTPUT_VALUE="$output" /usr/bin/ruby -rjson -e '
    samples = File.foreach(ENV.fetch("SAMPLES_VALUE")).map do |line|
      JSON.parse(line) unless line.strip.empty?
    end.compact
    missing = [
      "bufferDurationSeconds: no established process-bound telemetry",
      "maximumCallbackDurationSeconds: no established process-bound telemetry",
      "deadlineMissCount: no established process-bound telemetry",
      "overloadCount: safe process-bound overload observation unavailable",
      "wakeups: not collected by the bounded sampler",
      "dirtyMemoryBytes: not collected by the bounded sampler",
      "controllerCount: no established aggregate telemetry"
    ]
    route = ENV.fetch("ROUTE_COUNT_VALUE")
    record = {
      schemaVersion: "waves-runtime-profile-v1",
      scenario: ENV.fetch("SCENARIO_VALUE"),
      identity: {
        pid: Integer(ENV.fetch("PID_VALUE")),
        executablePath: ENV.fetch("EXECUTABLE_VALUE"),
        executableSHA256: ENV.fetch("SHA_VALUE"),
        processStartObservation: ENV.fetch("PROCESS_START_VALUE")
      },
      request: {
        durationSeconds: Float(ENV.fetch("DURATION_VALUE")),
        sampleIntervalSeconds: Float(ENV.fetch("INTERVAL_VALUE"))
      },
      result: {
        status: ENV.fetch("STATUS_VALUE"),
        actualDurationSeconds: Float(ENV.fetch("ACTUAL_VALUE")),
        interrupted: ENV.fetch("INTERRUPTED_VALUE") == "true",
        failure: ENV.fetch("FAILURE_VALUE").empty? ? nil : ENV.fetch("FAILURE_VALUE")
      },
      aggregateMetadata: { routeCount: route.empty? ? nil : Integer(route) },
      tools: {
        timeProfiler: {
          status: ENV.fetch("XCTRACE_STATUS_VALUE"),
          reason: ENV.fetch("XCTRACE_REASON_VALUE"),
          tocValidated: ENV.fetch("XCTRACE_TOC_VALUE") == "true",
          recordingStartSynchronized: ENV.fetch("XCTRACE_SYNC_VALUE") == "true",
          rawTraceDirectory: ENV.fetch("XCTRACE_STATUS_VALUE") == "recorded" ? "private-raw/time-profile.trace" : nil,
          privacy: "Private raw trace may contain identifiers. It is not sanitized and must not be staged."
        }
      },
      samples: samples,
      runtimeTimingEvidence: {
        bufferDurationSeconds: nil,
        maximumCallbackDurationSeconds: nil,
        deadlineMissCount: nil,
        overloadCount: nil
      },
      missingMetrics: missing
    }
    destination = File.join(ENV.fetch("OUTPUT_VALUE"), "summary.json")
    File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(record) + "\n") }
  '
  finalized=true
}

trap finish EXIT
trap handle_signal INT TERM HUP

deadline_run() {
  local limit=$1
  shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV' "$limit" "$@"
}

developer_dir=${DEVELOPER_DIR:-/Users/jonathanreed/Downloads/Xcode-beta.app/Contents/Developer}
xcrun_tool=${WAVES_RUNTIME_TEST_XCRUN_TOOL:-/usr/bin/xcrun}
if [[ -x "$developer_dir/usr/bin/xctrace" ]]; then
  templates_file="$raw_dir/xctrace-templates.txt"
  if DEVELOPER_DIR="$developer_dir" deadline_run 45 "$xcrun_tool" xctrace list templates >"$templates_file" 2>&1; then
    if /usr/bin/grep -q 'Time Profiler' "$templates_file"; then
      /bin/rm "$templates_file"
      xctrace_notification_key="com.jrr.waves.runtime-profile.$$.${RANDOM}"
      /usr/bin/notifyutil -1 "$xctrace_notification_key" >"$raw_dir/xctrace-start-notification.txt" 2>"$raw_dir/xctrace-start-notification.stderr.txt" &
      notify_pid=$!
      registration_start=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
      registration_ready=false
      while /bin/kill -0 "$notify_pid" 2>/dev/null; do
        registration_state=$(deadline_run 1 /usr/bin/notifyutil -s "$xctrace_notification_key" 1 -g "$xctrace_notification_key" 2>>"$raw_dir/xctrace-start-notification.stderr.txt" || true)
        if [[ $(printf '%s\n' "$registration_state" | /usr/bin/awk 'NF { value=$NF } END { print value }') == "1" ]]; then
          registration_ready=true
          break
        fi
        registration_now=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
        if /usr/bin/ruby -e 'exit(Float(ARGV[1]) - Float(ARGV[0]) >= 5 ? 0 : 1)' "$registration_start" "$registration_now"; then
          break
        fi
        /bin/sleep 0.05
      done
      if [[ "$registration_ready" == true ]]; then
        xctrace_command_start=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
        DEVELOPER_DIR="$developer_dir" /usr/bin/ruby -e 'Process.setsid; exec(*ARGV)' "$xcrun_tool" xctrace record --template "Time Profiler" --notify-tracing-started "$xctrace_notification_key" --attach "$pid" --time-limit "${duration}s" --output "$raw_dir/time-profile.trace" >"$raw_dir/xctrace.stderr.txt" 2>&1 &
        xctrace_pid=$!
        xctrace_status="recording"
        xctrace_reason=""

        notification_wait_start=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
        while :; do
          if ! /bin/kill -0 "$notify_pid" 2>/dev/null; then
            if wait "$notify_pid"; then
              xctrace_start_synchronized=true
            else
              xctrace_status="failed"
              xctrace_reason="recording-start notification watcher failed"
              stop_xctrace
            fi
            notify_pid=""
            break
          fi
          if ! /bin/kill -0 "$xctrace_pid" 2>/dev/null; then
            wait "$xctrace_pid" 2>/dev/null || true
            xctrace_pid=""
            xctrace_status="failed"
            xctrace_reason="xctrace exited before its recording-start notification"
            stop_notify_watcher
            break
          fi
          notification_wait_now=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
          if /usr/bin/ruby -e 'exit(Float(ARGV[1]) - Float(ARGV[0]) >= Float(ARGV[2]) ? 0 : 1)' "$notification_wait_start" "$notification_wait_now" "$xctrace_start_timeout"; then
            xctrace_status="failed"
            xctrace_reason="xctrace recording-start notification exceeded its ${xctrace_start_timeout}-second deadline"
            stop_notify_watcher
            stop_xctrace
            break
          fi
          /bin/sleep 0.05
        done
      else
        xctrace_status="failed"
        xctrace_reason="recording-start notification watcher registration failed"
        stop_notify_watcher
      fi
    else
      xctrace_status="unavailable"
      xctrace_reason="installed xctrace successfully enumerated templates without Time Profiler"
    fi
  else
    xctrace_status="failed"
    xctrace_reason="installed xctrace template discovery failed or exceeded its 45-second deadline"
  fi
else
  xctrace_status="unavailable"
  xctrace_reason="xctrace binary is absent from the selected developer directory"
fi

start_monotonic=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')

while :; do
  now=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
  elapsed=$(/usr/bin/ruby -e 'puts(Float(ARGV[1]) - Float(ARGV[0]))' "$start_monotonic" "$now")
  if ! verify_identity; then
    identity_after=false
    collector_failure="target exited, PID was reused, or executable identity changed"
    break
  fi

  ps_output=""
  ps_failure=""
  if ! ps_output=$(deadline_run 5 /bin/ps -p "$pid" -o %cpu= -o rss= 2>/dev/null); then
    ps_failure="ps sample failed or exceeded its deadline"
  fi
  thread_output=""
  thread_failure=""
  if ! thread_output=$(deadline_run 5 /bin/ps -M -p "$pid" 2>/dev/null | /usr/bin/awk 'NR > 1 { count++ } END { print count + 0 }'); then
    thread_failure="thread sample failed or exceeded its deadline"
  fi
  fd_output=""
  fd_failure=""
  if ! fd_output=$(deadline_run 5 /usr/sbin/lsof -a -p "$pid" 2>/dev/null | /usr/bin/awk 'NR > 1 { count++ } END { print count + 0 }'); then
    fd_failure="lsof sample failed or exceeded its deadline"
  fi
  ELAPSED_VALUE="$elapsed" PS_VALUE="$ps_output" PS_FAILURE_VALUE="$ps_failure" THREAD_VALUE="$thread_output" THREAD_FAILURE_VALUE="$thread_failure" FD_VALUE="$fd_output" FD_FAILURE_VALUE="$fd_failure" /usr/bin/ruby -rjson -e '
    failures = []
    cpu = resident = threads = nil
    if ENV.fetch("PS_FAILURE_VALUE").empty?
      fields = ENV.fetch("PS_VALUE").split
      if fields.length == 2
        begin
          cpu = Float(fields[0])
          resident = Integer(fields[1]) * 1024
        rescue ArgumentError
          failures << "cpuPercent/residentBytes: ps returned invalid numeric data"
          cpu = resident = nil
        end
      else
        failures << "cpuPercent/residentBytes: ps returned incomplete data"
      end
    else
      failures << "cpuPercent/residentBytes: #{ENV.fetch("PS_FAILURE_VALUE")}"
    end
    if ENV.fetch("THREAD_FAILURE_VALUE").empty?
      begin
        threads = Integer(ENV.fetch("THREAD_VALUE"))
      rescue ArgumentError
        failures << "threadCount: ps returned invalid numeric data"
      end
    else
      failures << "threadCount: #{ENV.fetch("THREAD_FAILURE_VALUE")}"
    end
    descriptors = nil
    if ENV.fetch("FD_FAILURE_VALUE").empty?
      begin
        descriptors = Integer(ENV.fetch("FD_VALUE"))
      rescue ArgumentError
        failures << "descriptorCount: lsof returned invalid numeric data"
      end
    else
      failures << "descriptorCount: #{ENV.fetch("FD_FAILURE_VALUE")}"
    end
    values = [cpu, resident, threads, descriptors]
    if values.compact.any? { |value| !value.finite? || value.negative? }
      failures << "sample contained a negative or non-finite value"
      cpu = resident = threads = descriptors = nil
    end
    puts JSON.generate(
      elapsedSeconds: Float(ENV.fetch("ELAPSED_VALUE")),
      cpuPercent: cpu,
      residentBytes: resident,
      threadCount: threads,
      descriptorCount: descriptors,
      failures: failures
    )
  ' >>"$samples_path"

  reached=$(/usr/bin/ruby -e 'exit(Float(ARGV[0]) >= Float(ARGV[1]) ? 0 : 1)' "$elapsed" "$duration"; echo $?)
  [[ "$reached" == 0 ]] && break
  remaining=$(/usr/bin/ruby -e 'puts [Float(ARGV[0]), Float(ARGV[1]) - Float(ARGV[2])].min' "$sample_interval" "$duration" "$elapsed")
  /bin/sleep "$remaining"
done
sampling_end_monotonic=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')

if [[ -n "$collector_failure" && -n "$xctrace_pid" ]]; then
  stop_xctrace
  xctrace_status="failed"
  xctrace_reason="recording stopped because target identity was lost"
fi

if [[ -n "$xctrace_pid" ]]; then
  xctrace_timed_out=false
  while /bin/kill -0 "$xctrace_pid" 2>/dev/null; do
    xctrace_finalize_now=$(/usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC)')
    if /usr/bin/ruby -e 'exit(Float(ARGV[1]) - Float(ARGV[0]) >= Float(ARGV[2]) ? 0 : 1)' "$xctrace_command_start" "$xctrace_finalize_now" "$xctrace_absolute_allowance"; then
      xctrace_timed_out=true
      stop_xctrace
      break
    fi
    /bin/sleep 0.2
  done
  if [[ "$xctrace_timed_out" == true ]]; then
    xctrace_status="failed"
    xctrace_reason="xctrace exceeded its absolute recorder deadline; any partial trace is private and incomplete"
  elif wait "$xctrace_pid"; then
    trace_path="$raw_dir/time-profile.trace"
    toc_path="$raw_dir/time-profile-toc.xml"
    if [[ -d "$trace_path" ]] && [[ -n $(deadline_run 5 /usr/bin/find "$trace_path" -type f -size +0c -print -quit 2>/dev/null) ]] && \
      DEVELOPER_DIR="$developer_dir" deadline_run 45 "$xcrun_tool" xctrace export --input "$trace_path" --toc >"$toc_path" 2>"$raw_dir/xctrace-export.stderr.txt" && \
      [[ -s "$toc_path" ]] && deadline_run 5 /usr/bin/xmllint --noout "$toc_path" >/dev/null 2>&1; then
      xctrace_status="recorded"
      xctrace_reason=""
      xctrace_toc_validated=true
    else
      xctrace_status="failed"
      xctrace_reason="xctrace exited successfully but its trace artifact or bounded TOC export was missing or invalid"
      xctrace_toc_validated=false
    fi
  else
    xctrace_status="failed"
    xctrace_reason="xctrace did not complete successfully; inspect private stderr"
  fi
  xctrace_pid=""
fi

verify_identity || identity_after=false
if [[ "$identity_after" != true && -z "$collector_failure" ]]; then
  collector_failure="target exited, PID was reused, or executable identity changed after collection"
fi
finalize_summary || exit 2
exit 0
