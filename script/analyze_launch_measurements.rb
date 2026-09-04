#!/usr/bin/ruby

require "json"

REQUIRED_KEYS = %w[
  run version build artifactSHA256 processStartNs firstFrameNs
  controlConfirmedNs dockSettledNs passed
].freeze

def fail_input(message)
  warn "launch measurements: #{message}"
  exit 2
end

def nearest_rank(values, percentile)
  sorted = values.sort
  rank = (percentile * sorted.length).ceil
  sorted[[rank - 1, 0].max]
end

path = ARGV.shift
fail_input("usage: #{$PROGRAM_NAME} [measurements.jsonl]") unless ARGV.empty?

input = path ? File.open(path, "r") : $stdin
records = []
input.each_line.with_index(1) do |line, line_number|
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
input.close if path

fail_input("expected exactly 30 records, found #{records.length}") unless records.length == 30

runs = records.map { |record| record["run"] }
unless runs.all? { |run| run.is_a?(Integer) && run.positive? } && runs.uniq.length == 30
  fail_input("run identities must be 30 unique positive integers")
end

identity = records.first.values_at("version", "build", "artifactSHA256")
unless records.all? { |record| record.values_at("version", "build", "artifactSHA256") == identity }
  fail_input("artifact identity must be consistent across all records")
end
unless identity[0].is_a?(String) && !identity[0].empty? && identity[1].is_a?(Integer) && identity[1].positive?
  fail_input("version and build must be a non-empty string and positive integer")
end
unless identity[2].is_a?(String) && identity[2].match?(/\A[0-9a-f]{64}\z/)
  fail_input("artifactSHA256 must contain 64 lowercase hexadecimal characters")
end

numeric_keys = %w[processStartNs firstFrameNs controlConfirmedNs dockSettledNs]
records.each do |record|
  numeric_keys.each do |key|
    fail_input("run #{record['run']} has non-integer #{key}") unless record[key].is_a?(Integer)
  end
  fail_input("run #{record['run']} has non-boolean passed") unless [true, false].include?(record["passed"])
end

margins = records.map { |record| record["controlConfirmedNs"] - record["dockSettledNs"] }
pass_count = records.count { |record| record["passed"] }
p50 = nearest_rank(margins, 0.50)
p95 = nearest_rank(margins, 0.95)
qualified = pass_count >= 29 && p95 <= -150_000_000

puts JSON.pretty_generate(
  version: identity[0],
  build: identity[1],
  artifactSHA256: identity[2],
  recordCount: records.length,
  passCount: pass_count,
  p50ControlMinusDockNs: p50,
  p95ControlMinusDockNs: p95,
  qualified: qualified
)
