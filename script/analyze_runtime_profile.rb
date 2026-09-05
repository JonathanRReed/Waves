#!/usr/bin/ruby

require "json"

SCHEMA_VERSION = "waves-runtime-profile-v1"
SCENARIOS = %w[
  current-state
  steady-0-routes
  steady-1-route
  steady-10-routes
  adaptive-eq-off
  adaptive-on-eq-off
  adaptive-off-eq-on
  adaptive-on-eq-on
  route-churn
  launch-exit
  device-recovery
  clean-shutdown
  degraded-shutdown
].freeze
SAMPLE_METRICS = %w[cpuPercent residentBytes threadCount descriptorCount].freeze
TIMING_METRICS = {
  "bufferDurationSeconds" => "seconds",
  "maximumCallbackDurationSeconds" => "seconds",
  "deadlineMissCount" => "count",
  "overloadCount" => "count"
}.freeze
SHA_PATTERN = /\A[0-9a-f]{64}\z/

def abort_input(message)
  warn "runtime profile: #{message}"
  exit 2
end

def finite_nonnegative_number?(value)
  value.is_a?(Numeric) && value.finite? && value >= 0
end

def median(values)
  sorted = values.sort
  middle = sorted.length / 2
  sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
end

path = ARGV.shift
abort_input("usage: #{$PROGRAM_NAME} summary.json") unless path && ARGV.empty?

begin
  record = JSON.parse(File.read(path))
rescue Errno::ENOENT
  abort_input("missing input: #{path}")
rescue JSON::ParserError => error
  abort_input("input is not valid JSON: #{error.message}")
end
abort_input("input must contain a JSON object") unless record.is_a?(Hash)

reasons = []
incomplete_reasons = []

reasons << "unsupported or missing schemaVersion" unless record["schemaVersion"] == SCHEMA_VERSION
scenario = record["scenario"]
reasons << "missing or undocumented scenario" unless SCENARIOS.include?(scenario)

identity = record["identity"]
identity_valid = identity.is_a?(Hash) && identity["pid"].is_a?(Integer) && identity["pid"].positive? &&
  identity["executablePath"].is_a?(String) && identity["executablePath"].start_with?("/") &&
  identity["executableSHA256"].is_a?(String) && identity["executableSHA256"].match?(SHA_PATTERN) &&
  identity["processStartObservation"].is_a?(String) && !identity["processStartObservation"].empty?
reasons << "missing or invalid executable identity" unless identity_valid

time_profiler = record.dig("tools", "timeProfiler") if record["tools"].is_a?(Hash)
if !time_profiler.is_a?(Hash) || !%w[recorded unavailable failed].include?(time_profiler["status"])
  reasons << "missing or invalid Time Profiler tool status"
elsif time_profiler["status"] == "recorded"
  reasons << "Time Profiler trace was not validated by bounded TOC export" unless time_profiler["tocValidated"] == true
  reasons << "Time Profiler trace was not synchronized to its recording-start notification" unless time_profiler["recordingStartSynchronized"] == true
elsif time_profiler["status"] == "unavailable"
  if time_profiler["reason"].is_a?(String) && !time_profiler["reason"].empty?
    incomplete_reasons << "Time Profiler unavailable: #{time_profiler['reason']}"
  else
    reasons << "unavailable Time Profiler status requires a reason"
  end
else
  reason = time_profiler["reason"].is_a?(String) && !time_profiler["reason"].empty? ? time_profiler["reason"] : "no reason recorded"
  reasons << "Time Profiler failed: #{reason}"
end

request = record["request"]
request_valid = request.is_a?(Hash) && finite_nonnegative_number?(request["durationSeconds"]) && request["durationSeconds"].positive? &&
  finite_nonnegative_number?(request["sampleIntervalSeconds"]) && request["sampleIntervalSeconds"].positive?
reasons << "missing or invalid request durations" unless request_valid

result = record["result"]
result_valid = result.is_a?(Hash) && %w[complete incomplete failed].include?(result["status"]) &&
  finite_nonnegative_number?(result["actualDurationSeconds"]) && [true, false].include?(result["interrupted"])
reasons << "missing or invalid collector result" unless result_valid
if result_valid && (result["status"] != "complete" || result["interrupted"])
  reasons << "collector status is #{result['status']}#{result['interrupted'] ? ' and interrupted' : ''}"
end

metadata = record["aggregateMetadata"]
if metadata && (!metadata.is_a?(Hash) || (metadata.key?("routeCount") && !(metadata["routeCount"].is_a?(Integer) && metadata["routeCount"] >= 0)))
  reasons << "aggregate routeCount must be a nonnegative integer"
end

samples = record["samples"]
unless samples.is_a?(Array) && !samples.empty?
  reasons << "samples must contain at least one sample"
  samples = []
end

previous_elapsed = -1.0
sample_failure_count = 0
samples.each_with_index do |sample, index|
  unless sample.is_a?(Hash)
    reasons << "sample #{index + 1} is not an object"
    next
  end
  elapsed = sample["elapsedSeconds"]
  unless finite_nonnegative_number?(elapsed) && elapsed > previous_elapsed
    reasons << "sample #{index + 1} has invalid or non-monotonic elapsedSeconds"
  else
    previous_elapsed = elapsed
  end
  failures = sample["failures"]
  unless failures.is_a?(Array) && failures.all? { |failure| failure.is_a?(String) && !failure.empty? }
    reasons << "sample #{index + 1} has invalid failures"
    failures = []
  end
  sample_failure_count += 1 unless failures.empty?
  SAMPLE_METRICS.each do |metric|
    value = sample[metric]
    if value.nil?
      incomplete_reasons << "sample #{index + 1} is missing #{metric}"
    elsif !finite_nonnegative_number?(value)
      reasons << "sample #{index + 1} has invalid #{metric}"
    elsif %w[threadCount descriptorCount].include?(metric) && !value.is_a?(Integer)
      reasons << "sample #{index + 1} has non-integer #{metric}"
    end
  end
end
incomplete_reasons << "#{sample_failure_count} samples contain collection failures" if sample_failure_count.positive?

sample_coverage_valid = false
if request_valid && result_valid && !samples.empty? && samples.all? { |sample| sample.is_a?(Hash) && finite_nonnegative_number?(sample["elapsedSeconds"]) }
  elapsed_values = samples.map { |sample| sample["elapsedSeconds"] }
  interval = request["sampleIntervalSeconds"]
  duration = request["durationSeconds"]
  start_covered = elapsed_values.first <= interval
  end_covered = elapsed_values.last >= duration
  gaps_covered = elapsed_values.each_cons(2).all? { |left, right| right - left <= interval * 2.0 }
  duration_covered = result["actualDurationSeconds"] >= duration
  sample_coverage_valid = start_covered && end_covered && gaps_covered && duration_covered
  incomplete_reasons << "samples do not cover the requested duration at the requested interval" unless sample_coverage_valid
end

timing = record["runtimeTimingEvidence"]
unless timing.is_a?(Hash)
  incomplete_reasons << "runtimeTimingEvidence is missing"
  timing = {}
end

missing_metrics = record["missingMetrics"]
if !missing_metrics.is_a?(Array) || !missing_metrics.all? { |item| item.is_a?(String) && !item.empty? }
  reasons << "missingMetrics must be an array of non-empty strings"
elsif missing_metrics.any?
  incomplete_reasons << "unavailable metrics: #{missing_metrics.join(', ')}"
end
TIMING_METRICS.each do |name, expected_unit|
  metric = timing[name]
  if metric.nil?
    incomplete_reasons << "#{name} is unavailable"
    next
  end
  unless metric.is_a?(Hash) && finite_nonnegative_number?(metric["value"]) && metric["unit"] == expected_unit
    reasons << "#{name} has an invalid value or unit"
    next
  end
  if expected_unit == "count" && !metric["value"].is_a?(Integer)
    reasons << "#{name} must be an integer count"
  end
  provenance = metric["provenance"]
  provenance_valid = provenance.is_a?(Hash) && provenance["source"].is_a?(String) && !provenance["source"].empty? &&
    provenance["scenario"] == scenario && identity_valid && provenance["executableSHA256"] == identity["executableSHA256"]
  reasons << "#{name} provenance is not bound to this scenario and executable" unless provenance_valid
end

metric_value = lambda do |name|
  metric = timing[name]
  metric.is_a?(Hash) ? metric["value"] : nil
end
buffer = metric_value.call("bufferDurationSeconds")
callback = metric_value.call("maximumCallbackDurationSeconds")
if finite_nonnegative_number?(buffer) && finite_nonnegative_number?(callback) && callback > buffer
  reasons << "maximumCallbackDurationSeconds exceeds bufferDurationSeconds"
end
%w[deadlineMissCount overloadCount].each do |metric|
  value = metric_value.call(metric)
  reasons << "#{metric} is positive" if finite_nonnegative_number?(value) && value.positive?
end

soak = { "available" => false, "reason" => "insufficient duration or temporal coverage for first and last 15-minute windows" }
if request_valid && result_valid && result["actualDurationSeconds"] >= 7200 && sample_coverage_valid
  interval = request["sampleIntervalSeconds"]
  required_per_window = [2, (900.0 / interval * 0.8).floor].max
  first = samples.select { |sample| sample.is_a?(Hash) && sample["elapsedSeconds"].is_a?(Numeric) && sample["elapsedSeconds"] <= 900 }
  last_start = result["actualDurationSeconds"] - 900
  last = samples.select { |sample| sample.is_a?(Hash) && sample["elapsedSeconds"].is_a?(Numeric) && sample["elapsedSeconds"] >= last_start }
  first_span = first.empty? ? 0 : first.last["elapsedSeconds"] - first.first["elapsedSeconds"]
  last_span = last.empty? ? 0 : last.last["elapsedSeconds"] - last.first["elapsedSeconds"]
  required_span = [0, 900.0 - interval * 2.0].max
  if first.length >= required_per_window && last.length >= required_per_window && first_span >= required_span && last_span >= required_span
    medians = {}
    monotonic = []
    SAMPLE_METRICS.each do |metric|
      all_values = samples.map { |sample| sample[metric] }
      next unless all_values.all? { |value| finite_nonnegative_number?(value) }
      medians[metric] = { "first15MinuteMedian" => median(first.map { |sample| sample[metric] }), "last15MinuteMedian" => median(last.map { |sample| sample[metric] }) }
      monotonic << metric if all_values.each_cons(2).all? { |left, right| right >= left } && all_values.uniq.length > 1
    end
    soak = {
      "available" => true,
      "windowSeconds" => 900,
      "firstWindowSampleCount" => first.length,
      "lastWindowSampleCount" => last.length,
      "medians" => medians,
      "monotonicGrowthMetrics" => monotonic,
      "leakDiagnosis" => false,
      "note" => "Monotonic growth is a flag for review, not a leak diagnosis."
    }
  else
    soak["reason"] = "insufficient temporal coverage in the first or last 15-minute window"
  end
end

evidence_status = if reasons.any?
  "failed"
elsif incomplete_reasons.any?
  "incomplete"
else
  "complete"
end

puts JSON.pretty_generate(
  "schemaVersion" => SCHEMA_VERSION,
  "evidenceStatus" => evidence_status,
  "reasons" => reasons + incomplete_reasons,
  "sampleCount" => samples.length,
  "sampleFailureCount" => sample_failure_count,
  "soakComparison" => soak,
  "statement" => "This analyzer classifies evidence only. It does not issue a release-pass decision."
)
