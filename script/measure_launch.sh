#!/bin/bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: measure_launch.sh --app PATH --output PATH --run N --version VERSION \
  --build N --artifact-sha256 HEX --observation PATH [--timeout SECONDS]

The observation JSON must be created by an external recorder during this run.
USAGE
  exit 2
}

die() {
  echo "measure_launch.sh: $*" >&2
  exit 2
}

app=""
output=""
run=""
expected_version=""
expected_build=""
expected_sha=""
observation=""
timeout=30

while (($#)); do
  case "$1" in
    --app) (($# >= 2)) || usage; app=$2; shift 2 ;;
    --output) (($# >= 2)) || usage; output=$2; shift 2 ;;
    --run) (($# >= 2)) || usage; run=$2; shift 2 ;;
    --version) (($# >= 2)) || usage; expected_version=$2; shift 2 ;;
    --build) (($# >= 2)) || usage; expected_build=$2; shift 2 ;;
    --artifact-sha256) (($# >= 2)) || usage; expected_sha=$2; shift 2 ;;
    --observation) (($# >= 2)) || usage; observation=$2; shift 2 ;;
    --timeout) (($# >= 2)) || usage; timeout=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$app" && -n "$output" && -n "$run" && -n "$expected_version" && -n "$expected_build" && -n "$expected_sha" && -n "$observation" ]] || usage
[[ "$run" =~ ^[1-9][0-9]*$ ]] || die "--run must be a positive integer"
[[ "$expected_build" =~ ^[1-9][0-9]*$ ]] || die "--build must be a positive integer"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "--artifact-sha256 must contain 64 lowercase hexadecimal characters"
[[ -d "$app/Contents" ]] || die "app bundle not found: $app"
[[ ! -e "$output" || -f "$output" ]] || die "output is not a regular file: $output"
[[ ! -e "$observation" ]] || die "observation path already exists; use a fresh path for this run"

plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || die "Info.plist not found in app bundle"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null) || die "cannot read app version"
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null) || die "cannot read app build"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null) || die "cannot read app executable name"
executable="$app/Contents/MacOS/$executable_name"
[[ -f "$executable" ]] || die "main executable not found: $executable"
actual_sha=$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')
[[ "$actual_version" == "$expected_version" ]] || die "version mismatch: expected $expected_version, found $actual_version"
[[ "$actual_build" == "$expected_build" ]] || die "build mismatch: expected $expected_build, found $actual_build"
[[ "$actual_sha" == "$expected_sha" ]] || die "executable SHA-256 mismatch: expected $expected_sha, found $actual_sha"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) || die "cannot read bundle identifier"
running=$(/usr/bin/pgrep -x "$executable_name" || true)
if [[ -n "$running" ]]; then
  paths=""
  while IFS= read -r pid; do
    path=$(/bin/ps -p "$pid" -o comm= 2>/dev/null || true)
    paths+=" pid=$pid path=$path"
  done <<< "$running"
  die "Waves is still running; close it yourself before measuring.$paths"
fi

mkdir -p "$(dirname "$output")" "$(dirname "$observation")"
work_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/waves-launch.XXXXXX")
log_file="$work_dir/signposts.ndjson"
log_pid=""
cleanup() {
  if [[ -n "$log_pid" ]] && /bin/kill -0 "$log_pid" 2>/dev/null; then
    /bin/kill "$log_pid" 2>/dev/null || true
    wait "$log_pid" 2>/dev/null || true
  fi
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

log_tool=${WAVES_LOG_TOOL:-/usr/bin/log}
open_tool=${WAVES_OPEN_TOOL:-/usr/bin/open}
"$log_tool" stream --style ndjson --signpost --mach-continuous-time \
  --predicate "subsystem == '$bundle_id' AND category == 'LaunchPerformance'" >"$log_file" 2>&1 &
log_pid=$!
"$open_tool" -na "$app"

deadline=$((SECONDS + timeout))
while [[ ! -f "$observation" ]] && ((SECONDS < deadline)); do
  /bin/sleep 0.1
done
[[ -f "$observation" ]] || die "external observation was not produced within ${timeout}s"

while ((SECONDS < deadline)); do
  if /usr/bin/grep -q 'FirstControlConfirmed' "$log_file" 2>/dev/null; then
    break
  fi
  /bin/sleep 0.1
done
if /bin/kill -0 "$log_pid" 2>/dev/null; then
  /bin/kill "$log_pid" 2>/dev/null || true
  wait "$log_pid" 2>/dev/null || true
fi
log_pid=""

/usr/bin/ruby -rjson -e '
  log_path, observation_path, output_path, run, version, build, sha = ARGV
  abort_run = ->(message) { warn("measure_launch.sh: #{message}"); exit 2 }
  observation = JSON.parse(File.read(observation_path)) rescue abort_run.call("observation is not valid JSON")
  required = %w[clock processStartMachContinuousNs firstFrameMachContinuousNs dockSettledMachContinuousNs processStartEvidenceSHA256 firstFrameEvidenceSHA256 dockSettledEvidenceSHA256]
  missing = required.reject { |key| observation.key?(key) }
  abort_run.call("observation is missing #{missing.join(", ")}") unless missing.empty?
  abort_run.call("observation clock must be machContinuousTimeNanoseconds") unless observation["clock"] == "machContinuousTimeNanoseconds"
  %w[processStartMachContinuousNs firstFrameMachContinuousNs dockSettledMachContinuousNs].each do |key|
    abort_run.call("#{key} must be an integer") unless observation[key].is_a?(Integer)
  end
  %w[processStartEvidenceSHA256 firstFrameEvidenceSHA256 dockSettledEvidenceSHA256].each do |key|
    abort_run.call("#{key} must be a SHA-256") unless observation[key].is_a?(String) && observation[key].match?(/\A[0-9a-f]{64}\z/)
  end
  events = {}
  File.foreach(log_path) do |line|
    object = JSON.parse(line) rescue next
    text = object.to_s
    %w[ProcessInit MainWindowViewAppeared FirstControlConfirmed].each do |name|
      next unless text.include?(name)
      elapsed = text[/elapsedNs[=:\\" ]+(\d+)/, 1]
      mach_key = object.keys.find { |key| key.to_s.downcase.gsub(/[^a-z]/, "").include?("machcontinuoustime") }
      mach = mach_key && object[mach_key]
      events[name] ||= { elapsed: Integer(elapsed), mach: Integer(mach) } if elapsed && mach
    end
  end
  abort_run.call("missing real ProcessInit signpost with Mach continuous timestamp") unless events["ProcessInit"]
  abort_run.call("missing real FirstControlConfirmed signpost") unless events["FirstControlConfirmed"]
  origin = events["ProcessInit"][:mach] - events["ProcessInit"][:elapsed]
  process_start = observation["processStartMachContinuousNs"] - origin
  first_frame = observation["firstFrameMachContinuousNs"] - origin
  dock_settled = observation["dockSettledMachContinuousNs"] - origin
  control = events["FirstControlConfirmed"][:elapsed]
  abort_run.call("observation timestamps are out of order") unless process_start <= first_frame && first_frame <= dock_settled
  passed = control < dock_settled
  record = { run: Integer(run), version: version, build: Integer(build), artifactSHA256: sha,
    processStartNs: process_start, firstFrameNs: first_frame, controlConfirmedNs: control,
    dockSettledNs: dock_settled, passed: passed }
  File.open(output_path, "a", 0o600) { |file| file.puts(JSON.generate(record)) }
' "$log_file" "$observation" "$output" "$run" "$expected_version" "$expected_build" "$expected_sha"

echo "Appended run $run to $output"
