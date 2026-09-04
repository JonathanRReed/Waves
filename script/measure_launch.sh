#!/bin/bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: measure_launch.sh --app PATH --output PATH --run N --version VERSION \
  --build N --artifact-sha256 HEX --observation PATH [--timeout SECONDS]
USAGE
  exit 2
}

die() {
  failure_reason=$*
  echo "measure_launch.sh: $*" >&2
  exit 2
}

app=""; output=""; run=""; expected_version=""; expected_build=""
expected_sha=""; observation=""; timeout=30
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
[[ "$run" =~ ^([1-9]|[12][0-9]|30)$ ]] || die "--run must be an integer from 1 through 30"
[[ "$expected_build" =~ ^[1-9][0-9]*$ ]] || die "--build must be a positive integer"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die "--artifact-sha256 must contain 64 lowercase hexadecimal characters"
[[ -d "$app/Contents" ]] || die "app bundle not found: $app"
[[ ! -e "$output" || -f "$output" ]] || die "output is not a regular file: $output"
[[ ! -e "$observation" ]] || die "observation path must not exist before this attempt"

plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || die "Info.plist not found in app bundle"
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null) || die "cannot read app version"
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null) || die "cannot read app build"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null) || die "cannot read app executable name"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) || die "cannot read bundle identifier"
executable="$app/Contents/MacOS/$executable_name"
[[ -f "$executable" ]] || die "main executable not found: $executable"
executable=$(/usr/bin/ruby -e 'puts File.realpath(ARGV.fetch(0))' "$executable")
actual_sha=$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')
[[ "$actual_version" == "$expected_version" ]] || die "version mismatch: expected $expected_version, found $actual_version"
[[ "$actual_build" == "$expected_build" ]] || die "build mismatch: expected $expected_build, found $actual_build"
[[ "$actual_sha" == "$expected_sha" ]] || die "executable SHA-256 mismatch: expected $expected_sha, found $actual_sha"

process_tool=${WAVES_PROCESS_TOOL:-}
find_candidate_pids() {
  if [[ -n "$process_tool" ]]; then
    "$process_tool" "$executable"
    return
  fi
  /bin/ps -axo pid=,comm= | /usr/bin/ruby -e '
    target = File.realpath(ARGV.fetch(0))
    STDIN.each_line do |line|
      pid, command = line.strip.split(/\s+/, 2)
      next unless pid && command
      begin
        puts pid if File.realpath(command) == target
      rescue Errno::ENOENT, Errno::EACCES
      end
    end
  ' "$executable"
}

same_name=$(/usr/bin/pgrep -x "$executable_name" || true)
[[ -z "$same_name" ]] || die "a process named $executable_name is already running; close it yourself before measuring: $same_name"
[[ -z "$(find_candidate_pids)" ]] || die "the candidate executable is already running; close it yourself before measuring"

mkdir -p "$(dirname "$output")"
evidence_root="${output}.evidence"
mkdir -p "$evidence_root"
attempt_dir="$evidence_root/attempt-$run"
mkdir "$attempt_dir" 2>/dev/null || die "attempt $run already exists and cannot be reused"
attempt_file="$attempt_dir/attempt.json"
raw_log="$attempt_dir/unified-log.ndjson"
failure_reason="collector exited before completing the attempt"
attempt_created=1
completed=0
log_pid=""
launched_pid=""

ATTEMPT_FILE="$attempt_file" RUN_ID="$run" VERSION_ID="$expected_version" BUILD_ID="$expected_build" ARTIFACT_ID="$expected_sha" /usr/bin/ruby -rjson -e '
  File.write(ENV.fetch("ATTEMPT_FILE"), JSON.pretty_generate(
    run: Integer(ENV.fetch("RUN_ID")), status: "pending", version: ENV.fetch("VERSION_ID"),
    build: Integer(ENV.fetch("BUILD_ID")), artifactSHA256: ENV.fetch("ARTIFACT_ID")
  ) + "\n")
'

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM
  if [[ -n "$log_pid" ]] && /bin/kill -0 "$log_pid" 2>/dev/null; then
    /bin/kill "$log_pid" 2>/dev/null || true
    wait "$log_pid" 2>/dev/null || true
  fi
  if (( attempt_created == 1 && completed == 0 )); then
    ATTEMPT_FILE="$attempt_file" ATTEMPT_DIR="$attempt_dir" RAW_LOG="$raw_log" OBSERVATION="$observation" FAILURE_REASON="$failure_reason" LAUNCHED_PID="$launched_pid" EXECUTABLE_PATH="$executable" /usr/bin/ruby -rjson -rdigest -rfileutils -e '
      attempt_path = ENV.fetch("ATTEMPT_FILE")
      attempt_dir = ENV.fetch("ATTEMPT_DIR")
      attempt = JSON.parse(File.read(attempt_path))
      sources = []
      observation_hash = nil
      observation_path = ENV.fetch("OBSERVATION")
      if File.file?(observation_path)
        copy = File.join(attempt_dir, "observation.failed.json")
        FileUtils.cp(observation_path, copy, preserve: true)
        observation_hash = Digest::SHA256.file(copy).hexdigest
        begin
          parsed = JSON.parse(File.read(copy))
          Array(parsed["evidenceFiles"]).each_with_index do |source, index|
            next unless source.is_a?(String) && File.file?(source)
            destination = File.join(attempt_dir, format("failed-source-%02d-%s", index + 1, File.basename(source)))
            FileUtils.cp(source, destination, preserve: true)
            sources << { "file" => File.basename(destination), "sha256" => Digest::SHA256.file(destination).hexdigest, "bytes" => File.size(destination) }
          end
        rescue JSON::ParserError
        end
      end
      raw_log = ENV.fetch("RAW_LOG")
      manifest = {
        run: attempt.fetch("run"), version: attempt.fetch("version"), build: attempt.fetch("build"),
        artifactSHA256: attempt.fetch("artifactSHA256"), status: "failed", failure: ENV.fetch("FAILURE_REASON"),
        launchedPID: ENV.fetch("LAUNCHED_PID").empty? ? nil : Integer(ENV.fetch("LAUNCHED_PID")),
        processImagePath: ENV.fetch("EXECUTABLE_PATH"),
        rawLogSHA256: File.file?(raw_log) ? Digest::SHA256.file(raw_log).hexdigest : nil,
        observationSHA256: observation_hash, sourceEvidence: sources
      }
      manifest_path = File.join(attempt_dir, "manifest.json")
      File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
      manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
      ([raw_log, manifest_path] + Dir.glob(File.join(attempt_dir, "failed-source-*")) + [File.join(attempt_dir, "observation.failed.json")]).each { |path| File.chmod(0o444, path) if File.file?(path) }
      attempt.merge!("status" => "failed", "failure" => ENV.fetch("FAILURE_REASON"), "manifestSHA256" => manifest_sha)
      File.write(attempt_path, JSON.pretty_generate(attempt) + "\n")
      index_path = File.join(File.dirname(attempt_dir), "index.jsonl")
      File.open(index_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.flock(File::LOCK_EX); file.puts(JSON.generate(run: attempt.fetch("run"), status: "failed", artifactSHA256: attempt.fetch("artifactSHA256"), manifestSHA256: manifest_sha)) }
    ' 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

log_tool=${WAVES_LOG_TOOL:-/usr/bin/log}
open_tool=${WAVES_OPEN_TOOL:-/usr/bin/open}
"$log_tool" stream --level debug --style ndjson --signpost --mach-continuous-time \
  --predicate "subsystem == '$bundle_id' AND category == 'LaunchPerformance'" >"$raw_log" 2>&1 &
log_pid=$!
readiness_deadline=$((SECONDS + timeout))
while ! /usr/bin/grep -q '^Filtering the log data using' "$raw_log" 2>/dev/null; do
  /bin/kill -0 "$log_pid" 2>/dev/null || die "unified-log capture exited before becoming ready"
  ((SECONDS < readiness_deadline)) || die "unified-log capture did not become ready within ${timeout}s"
  /bin/sleep 0.05
done
"$open_tool" -na "$app"

deadline=$((SECONDS + timeout))
while ((SECONDS < deadline)); do
  /bin/kill -0 "$log_pid" 2>/dev/null || die "unified-log capture exited before the launched PID was resolved"
  candidate_output=$(find_candidate_pids)
  candidate_count=$(printf '%s\n' "$candidate_output" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
  if ((candidate_count == 1)); then
    launched_pid=$candidate_output
    break
  fi
  ((candidate_count <= 1)) || die "more than one new candidate process appeared; refusing ambiguous launch"
  /bin/sleep 0.1
done
[[ -n "$launched_pid" ]] || die "could not resolve the launched candidate PID within ${timeout}s"

has_pid_bound_confirmation() {
  /usr/bin/ruby -rjson -e '
    path, pid_text, image_path = ARGV
    expected_pid = Integer(pid_text)
    expected_path = File.realpath(image_path)
    found = File.foreach(path).any? do |line|
      begin
        event = JSON.parse(line)
      rescue JSON::ParserError
        next false
      end
      next false unless event["eventType"] == "signpostEvent" && event["signpostType"] == "event"
      next false unless event["signpostName"] == "FirstControlConfirmed" && event["processID"] == expected_pid
      begin
        File.realpath(event["processImagePath"]) == expected_path
      rescue TypeError, Errno::ENOENT, Errno::EACCES
        false
      end
    end
    exit(found ? 0 : 1)
  ' "$raw_log" "$launched_pid" "$executable"
}

while ((SECONDS < deadline)); do
  if [[ -f "$observation" ]] && has_pid_bound_confirmation; then break; fi
  /bin/kill -0 "$log_pid" 2>/dev/null || die "unified-log capture exited before required evidence arrived"
  /bin/sleep 0.1
done
[[ -f "$observation" ]] || die "external observation was not produced within ${timeout}s"
has_pid_bound_confirmation || die "PID-bound FirstControlConfirmed was not logged within ${timeout}s"

if /bin/kill -0 "$log_pid" 2>/dev/null; then
  /bin/kill "$log_pid" 2>/dev/null || true
  wait "$log_pid" 2>/dev/null || true
fi
log_pid=""

/usr/bin/ruby -rjson -rdigest -rfiddle -rfileutils -e '
  log_path, observation_path, output_path, attempt_dir, pid_text, image_path, run_text, version, build_text, artifact = ARGV
  abort_run = ->(message) { warn("measure_launch.sh: #{message}"); exit 2 }
  observation = JSON.parse(File.read(observation_path)) rescue abort_run.call("observation is not valid JSON")
  required = %w[sourceClock conversionMethod syncPairs processStartSourceTicks firstFrameSourceTicks dockSettledSourceTicks evidenceFiles]
  missing = required.reject { |key| observation.key?(key) }
  abort_run.call("observation is missing #{missing.join(", ")}") unless missing.empty?
  clock = observation["sourceClock"]
  abort_run.call("sourceClock must name the clock and its positive ticksPerSecond") unless clock.is_a?(Hash) && clock["name"].is_a?(String) && !clock["name"].empty? && clock["ticksPerSecond"].is_a?(Integer) && clock["ticksPerSecond"].positive?
  abort_run.call("conversionMethod must be linear-interpolation") unless observation["conversionMethod"] == "linear-interpolation"
  pairs = observation["syncPairs"]
  abort_run.call("syncPairs must contain at least two calibration pairs") unless pairs.is_a?(Array) && pairs.length >= 2
  pairs.each { |pair| abort_run.call("each sync pair needs integer sourceTicks and machContinuousTicks") unless pair.is_a?(Hash) && pair["sourceTicks"].is_a?(Integer) && pair["machContinuousTicks"].is_a?(Integer) }
  pairs.sort_by! { |pair| pair["sourceTicks"] }
  abort_run.call("sync pairs must increase on both clocks") unless pairs.each_cons(2).all? { |a, b| a["sourceTicks"] < b["sourceTicks"] && a["machContinuousTicks"] < b["machContinuousTicks"] }
  milestone_keys = %w[processStartSourceTicks firstFrameSourceTicks dockSettledSourceTicks]
  milestone_keys.each { |key| abort_run.call("#{key} must be an integer") unless observation[key].is_a?(Integer) }
  min_source, max_source = pairs.first["sourceTicks"], pairs.last["sourceTicks"]
  abort_run.call("sync pairs must bracket every external milestone") unless milestone_keys.all? { |key| observation[key].between?(min_source, max_source) }
  files = observation["evidenceFiles"]
  abort_run.call("evidenceFiles must name at least one source file") unless files.is_a?(Array) && !files.empty? && files.all? { |path| path.is_a?(String) && File.file?(path) }
  evidence_paths = files.map { |path| File.realpath(path) }
  pair_keys = %w[eventID sourceEvidenceFile sourceEvidenceLocator machEvidenceFile machEvidenceLocator machCaptureCommand sourceUncertaintyTicks machUncertaintyTicks]
  pairs.each do |pair|
    absent = pair_keys.reject { |key| pair.key?(key) }
    abort_run.call("sync pair is missing binding fields: #{absent.join(", ")}") unless absent.empty?
    %w[eventID sourceEvidenceLocator machEvidenceLocator machCaptureCommand].each do |key|
      abort_run.call("sync pair #{key} must be a non-empty string") unless pair[key].is_a?(String) && !pair[key].strip.empty?
    end
    %w[sourceUncertaintyTicks machUncertaintyTicks].each do |key|
      abort_run.call("sync pair #{key} must be a non-negative integer") unless pair[key].is_a?(Integer) && pair[key] >= 0
    end
    %w[sourceEvidenceFile machEvidenceFile].each do |key|
      abort_run.call("sync pair #{key} must name a retained evidence file") unless pair[key].is_a?(String) && File.file?(pair[key]) && evidence_paths.include?(File.realpath(pair[key]))
    end
    mach_match = File.foreach(pair["machEvidenceFile"]).any? do |line|
      begin
        item = JSON.parse(line)
        item["eventID"] == pair["eventID"] && item["machContinuousTicks"] == pair["machContinuousTicks"]
      rescue JSON::ParserError
        false
      end
    end
    abort_run.call("sync pair #{pair["eventID"]} has no matching Mach evidence record") unless mach_match
  end
  abort_run.call("sync pair eventID values must be unique") unless pairs.map { |pair| pair["eventID"] }.uniq.length == pairs.length

  launched_pid = Integer(pid_text)
  selected = Hash.new { |hash, key| hash[key] = [] }
  File.foreach(log_path) do |line|
    event = JSON.parse(line) rescue next
    next unless event["eventType"] == "signpostEvent" && event["signpostType"] == "event"
    next unless event["processID"] == launched_pid
    begin
      next unless File.realpath(event["processImagePath"]) == File.realpath(image_path)
    rescue TypeError, Errno::ENOENT, Errno::EACCES
      next
    end
    next unless %w[ProcessInit MainWindowViewAppeared FirstControlConfirmed].include?(event["signpostName"])
    elapsed = event["eventMessage"].to_s[/\AelapsedNs=(\d+)\z/, 1]
    next unless elapsed && event["machTimestamp"].is_a?(Integer)
    selected[event["signpostName"]] << { "elapsedNs" => Integer(elapsed), "machContinuousTicks" => event["machTimestamp"] }
  end
  %w[ProcessInit FirstControlConfirmed].each { |name| abort_run.call("expected exactly one PID-bound #{name} signpost") unless selected[name].length == 1 }

  pointer = Fiddle::Pointer.malloc(8)
  function = Fiddle::Function.new(Fiddle.dlopen(nil)["mach_timebase_info"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
  abort_run.call("mach_timebase_info failed") unless function.call(pointer).zero?
  numerator, denominator = pointer[0, 8].unpack("L2")
  abort_run.call("invalid Mach timebase") unless numerator.positive? && denominator.positive?
  adjacent_drifts = pairs.each_cons(2).map do |left, right|
    source_delta = right["sourceTicks"] - left["sourceTicks"]
    mach_delta = right["machContinuousTicks"] - left["machContinuousTicks"]
    source_seconds = Rational(source_delta, clock["ticksPerSecond"])
    mach_seconds = Rational(mach_delta * numerator, denominator * 1_000_000_000)
    ((source_seconds - mach_seconds).abs / source_seconds).to_f
  end
  abort_run.call("an adjacent source-to-Mach calibration differs by more than one percent") if adjacent_drifts.any? { |drift| drift > 0.01 }
  ticks_to_ns = ->(ticks) { (Rational(ticks * numerator, denominator)).round }
  source_to_mach = lambda do |source_ticks|
    left, right = pairs.each_cons(2).find { |a, b| source_ticks.between?(a["sourceTicks"], b["sourceTicks"]) }
    fraction = Rational(source_ticks - left["sourceTicks"], right["sourceTicks"] - left["sourceTicks"])
    (left["machContinuousTicks"] + fraction * (right["machContinuousTicks"] - left["machContinuousTicks"])).round
  end
  process_init = selected["ProcessInit"].first
  origin_ns = ticks_to_ns.call(process_init["machContinuousTicks"]) - process_init["elapsedNs"]
  external_ns = milestone_keys.to_h { |key| [key, ticks_to_ns.call(source_to_mach.call(observation[key])) - origin_ns] }
  control_ns = selected["FirstControlConfirmed"].first["elapsedNs"]
  process_ns, frame_ns, dock_ns = external_ns.values_at(*milestone_keys)
  abort_run.call("external milestones have invalid ordering") unless process_ns <= frame_ns && frame_ns <= [control_ns, dock_ns].min

  copied_sources = files.each_with_index.map do |source, index|
    destination = File.join(attempt_dir, format("source-%02d-%s", index + 1, File.basename(source)))
    FileUtils.cp(source, destination, preserve: true)
    { "file" => File.basename(destination), "sha256" => Digest::SHA256.file(destination).hexdigest, "bytes" => File.size(destination) }
  end
  retained_name_by_path = files.each_with_index.to_h { |source, index| [File.realpath(source), copied_sources[index]["file"]] }
  retained_pairs = pairs.map do |pair|
    pair.merge(
      "sourceEvidenceFile" => retained_name_by_path.fetch(File.realpath(pair["sourceEvidenceFile"])),
      "machEvidenceFile" => retained_name_by_path.fetch(File.realpath(pair["machEvidenceFile"]))
    )
  end
  observation_copy = File.join(attempt_dir, "observation.json")
  FileUtils.cp(observation_path, observation_copy, preserve: true)
  run = Integer(run_text); build = Integer(build_text)
  manifest = {
    run: run, version: version, build: build, artifactSHA256: artifact,
    launchedPID: launched_pid, processImagePath: File.realpath(image_path),
    machTimebaseNumerator: numerator, machTimebaseDenominator: denominator,
    sourceClock: clock, clockConversionMethod: "linear-interpolation then mach ticks times numerator divided by denominator",
    syncPairs: retained_pairs, calibrationAdjacentRelativeDrift: adjacent_drifts, selectedSignposts: selected, sourceEvidence: copied_sources,
    observationSHA256: Digest::SHA256.file(observation_copy).hexdigest,
    rawLogSHA256: Digest::SHA256.file(log_path).hexdigest
  }
  manifest_path = File.join(attempt_dir, "manifest.json")
  File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
  manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
  ([log_path, observation_copy, manifest_path] + copied_sources.map { |source| File.join(attempt_dir, source["file"]) }).each { |path| File.chmod(0o444, path) }
  record = { run: run, version: version, build: build, artifactSHA256: artifact,
    processStartNs: process_ns, firstFrameNs: frame_ns, controlConfirmedNs: control_ns,
    dockSettledNs: dock_ns, passed: control_ns < dock_ns, attemptManifestSHA256: manifest_sha }
  File.open(output_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.flock(File::LOCK_EX); file.puts(JSON.generate(record)) }
  attempt_path = File.join(attempt_dir, "attempt.json")
  attempt = JSON.parse(File.read(attempt_path)).merge("status" => "completed", "manifestSHA256" => manifest_sha)
  File.write(attempt_path, JSON.pretty_generate(attempt) + "\n")
  index_path = File.join(File.dirname(attempt_dir), "index.jsonl")
  File.open(index_path, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |file| file.flock(File::LOCK_EX); file.puts(JSON.generate(run: run, status: "completed", artifactSHA256: artifact, manifestSHA256: manifest_sha)) }
' "$raw_log" "$observation" "$output" "$attempt_dir" "$launched_pid" "$executable" "$run" "$expected_version" "$expected_build" "$expected_sha"

completed=1
echo "Appended completed attempt $run to $output"
