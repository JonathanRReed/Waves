#!/usr/bin/ruby

require "digest"
require "json"

REQUIRED_KEYS = %w[run version build artifactSHA256 processStartNs firstFrameNs controlConfirmedNs dockSettledNs passed attemptManifestSHA256].freeze
SHA_PATTERN = /\A[0-9a-f]{64}\z/

def fail_input(message)
  warn "launch measurements: #{message}"
  exit 2
end

def read_json(path, label)
  JSON.parse(File.read(path))
rescue Errno::ENOENT
  fail_input("missing #{label}: #{path}")
rescue JSON::ParserError => error
  fail_input("malformed #{label} #{path}: #{error.message}")
end

def nearest_rank(values, percentile)
  sorted = values.sort
  sorted[(percentile * sorted.length).ceil - 1]
end

path = ARGV.shift
fail_input("usage: #{$PROGRAM_NAME} measurements.jsonl") unless path && ARGV.empty?

records = []
File.foreach(path).with_index(1) do |line, line_number|
  next if line.strip.empty?
  begin
    value = JSON.parse(line)
  rescue JSON::ParserError => error
    fail_input("line #{line_number} is not valid JSON: #{error.message}")
  end
  fail_input("line #{line_number} must contain a JSON object") unless value.is_a?(Hash)
  missing = REQUIRED_KEYS.reject { |key| value.key?(key) }
  fail_input("line #{line_number} is missing #{missing.join(', ')}") unless missing.empty?
  records << value
end

evidence_root = "#{path}.evidence"
fail_input("missing attempt evidence directory: #{evidence_root}") unless File.directory?(evidence_root)
attempt_paths = Dir.glob(File.join(evidence_root, "attempt-*")).select { |entry| File.directory?(entry) }
attempt_numbers = attempt_paths.map { |entry| File.basename(entry)[/\Aattempt-(\d+)\z/, 1]&.to_i }
unless attempt_numbers.compact.sort == (1..30).to_a && attempt_paths.length == 30
  fail_input("attempt identities must be exactly 1 through 30 with no extras")
end
index_path = File.join(evidence_root, "index.jsonl")
index_entries = []
if File.file?(index_path)
  File.foreach(index_path).with_index(1) do |line, line_number|
    begin
      index_entries << JSON.parse(line)
    rescue JSON::ParserError => error
      fail_input("attempt index line #{line_number} is not valid JSON: #{error.message}")
    end
  end
end

record_by_run = {}
records.each do |record|
  run = record["run"]
  unless run.is_a?(Integer) && run.between?(1, 30) && !record_by_run.key?(run)
    fail_input("run identities must be unique integers from 1 through 30")
  end
  record_by_run[run] = record
end

attempts = (1..30).map do |run|
  directory = File.join(evidence_root, "attempt-#{run}")
  attempt = read_json(File.join(directory, "attempt.json"), "attempt metadata")
  fail_input("attempt-#{run} contains the wrong run identity") unless attempt["run"] == run
  fail_input("attempt-#{run} has invalid status") unless %w[pending failed completed].include?(attempt["status"])
  identity = attempt.values_at("version", "build", "artifactSHA256")
  unless identity[0].is_a?(String) && !identity[0].empty? && identity[1].is_a?(Integer) && identity[1].positive? && identity[2].is_a?(String) && identity[2].match?(SHA_PATTERN)
    fail_input("attempt-#{run} has invalid artifact identity")
  end

  record = record_by_run[run]
  if %w[completed failed].include?(attempt["status"])
    fail_input("attempt-#{run} is completed but has no measurement") if attempt["status"] == "completed" && !record
    fail_input("attempt-#{run} is failed but has a measurement") if attempt["status"] == "failed" && record
    manifest_path = File.join(directory, "manifest.json")
    manifest_sha = Digest::SHA256.file(manifest_path).hexdigest rescue fail_input("attempt-#{run} is missing manifest.json")
    unless attempt["manifestSHA256"] == manifest_sha && (attempt["status"] == "failed" || record["attemptManifestSHA256"] == manifest_sha)
      fail_input("attempt-#{run} manifest hash does not match its attempt and measurement")
    end
    manifest = read_json(manifest_path, "attempt manifest")
    unless manifest.values_at("run", "version", "build", "artifactSHA256") == [run, *identity]
      fail_input("attempt-#{run} manifest is not bound to the run and artifact")
    end
    raw_log_path = File.join(directory, "unified-log.ndjson")
    unless File.file?(raw_log_path) && manifest["rawLogSHA256"] == Digest::SHA256.file(raw_log_path).hexdigest
      fail_input("attempt-#{run} raw log does not match its manifest")
    end
    if manifest["observationSHA256"]
      observation_name = attempt["status"] == "completed" ? "observation.json" : "observation.failed.json"
      observation_path = File.join(directory, observation_name)
      unless File.file?(observation_path) && manifest["observationSHA256"] == Digest::SHA256.file(observation_path).hexdigest
        fail_input("attempt-#{run} observation does not match its manifest")
      end
    end
    Array(manifest["sourceEvidence"]).each do |source|
      source_path = File.join(directory, source["file"].to_s)
      unless File.file?(source_path) && source["sha256"] == Digest::SHA256.file(source_path).hexdigest && source["bytes"] == File.size(source_path)
        fail_input("attempt-#{run} source evidence does not match its manifest")
      end
    end
    matching_index = index_entries.select { |entry| entry["run"] == run }
    unless matching_index.length == 1 && matching_index.first.values_at("status", "artifactSHA256", "manifestSHA256") == [attempt["status"], identity[2], manifest_sha]
      fail_input("attempt-#{run} has no unique matching manifest index entry")
    end
  elsif record
    fail_input("attempt-#{run} is #{attempt['status']} but has a measurement")
  end
  [attempt, identity]
end
finalized_count = attempts.count { |attempt, _identity| %w[completed failed].include?(attempt["status"]) }
fail_input("attempt index contains unaccounted entries") unless index_entries.length == finalized_count

identities = attempts.map(&:last).uniq
fail_input("artifact identity must be consistent across all attempts") unless identities.length == 1
identity = identities.first

numeric_keys = %w[processStartNs firstFrameNs controlConfirmedNs dockSettledNs]
records.each do |record|
  run = record["run"]
  unless record.values_at("version", "build", "artifactSHA256") == identity
    fail_input("run #{run} artifact identity conflicts with its attempt")
  end
  numeric_keys.each { |key| fail_input("run #{run} has non-integer #{key}") unless record[key].is_a?(Integer) }
  process_start, first_frame, control, dock = record.values_at(*numeric_keys)
  unless process_start <= first_frame && first_frame <= [control, dock].min
    fail_input("run #{run} has invalid process, frame, control, or Dock ordering")
  end
  derived_pass = control < dock
  unless [true, false].include?(record["passed"]) && record["passed"] == derived_pass
    fail_input("run #{run} passed conflicts with measured ordering")
  end
end

completed = attempts.count { |attempt, _identity| attempt["status"] == "completed" }
margins = records.map { |record| record["controlConfirmedNs"] - record["dockSettledNs"] }
pass_count = records.count { |record| record["controlConfirmedNs"] < record["dockSettledNs"] }
p50 = margins.empty? ? nil : nearest_rank(margins, 0.50)
p95 = margins.empty? ? nil : nearest_rank(margins, 0.95)
qualified = completed == 30 && records.length == 30 && pass_count >= 29 && p95 <= -150_000_000

puts JSON.pretty_generate(
  version: identity[0], build: identity[1], artifactSHA256: identity[2],
  attemptCount: 30, completedAttemptCount: completed, failedOrPendingAttemptCount: 30 - completed,
  recordCount: records.length, passCount: pass_count,
  p50ControlMinusDockNs: p50, p95ControlMinusDockNs: p95, qualified: qualified
)
