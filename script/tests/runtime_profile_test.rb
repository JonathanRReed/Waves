require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "digest"
require "fileutils"
require "timeout"

ANALYZER = File.expand_path("../analyze_runtime_profile.rb", __dir__)
COLLECTOR = File.expand_path("../profile_runtime.sh", __dir__)

class RuntimeProfileTest < Minitest::Test
  SHA = "a" * 64

  def base_record
    {
      "schemaVersion" => "waves-runtime-profile-v1",
      "scenario" => "steady-1-route",
      "identity" => {
        "pid" => 123,
        "executablePath" => "/tmp/fixture",
        "executableSHA256" => SHA,
        "processStartObservation" => "Fri Sep  4 12:00:00 2026"
      },
      "request" => { "durationSeconds" => 1200.0, "sampleIntervalSeconds" => 60.0 },
      "result" => { "status" => "complete", "actualDurationSeconds" => 1200.0, "interrupted" => false },
      "aggregateMetadata" => { "routeCount" => 1 },
      "tools" => {
        "timeProfiler" => {
          "status" => "recorded",
          "reason" => "",
          "tocValidated" => true,
          "recordingStartSynchronized" => true
        }
      },
      "samples" => (0..20).map do |index|
        {
          "elapsedSeconds" => index * 60.0,
          "cpuPercent" => 2.0,
          "residentBytes" => 10_000_000,
          "threadCount" => 4,
          "descriptorCount" => 8,
          "failures" => []
        }
      end,
      "runtimeTimingEvidence" => {
        "bufferDurationSeconds" => metric(0.01, "seconds"),
        "maximumCallbackDurationSeconds" => metric(0.004, "seconds"),
        "deadlineMissCount" => metric(0, "count"),
        "overloadCount" => metric(0, "count")
      },
      "missingMetrics" => []
    }
  end

  def metric(value, unit)
    {
      "value" => value,
      "unit" => unit,
      "provenance" => {
        "source" => "fixture telemetry",
        "scenario" => "steady-1-route",
        "executableSHA256" => SHA
      }
    }
  end

  def analyze(record)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "summary.json")
      File.write(path, JSON.pretty_generate(record))
      stdout, stderr, status = Open3.capture3("/usr/bin/ruby", ANALYZER, path)
      return [stdout, stderr, status]
    end
  end

  def collect_with_fake_xctrace(mode:, outer_timeout: nil, start_timeout: nil, recorder_timeout: nil)
    Dir.mktmpdir do |directory|
      developer = File.join(directory, "Developer")
      fake_xctrace = File.join(developer, "usr", "bin", "xctrace")
      FileUtils.mkdir_p(File.dirname(fake_xctrace))
      File.write(fake_xctrace, <<~SH)
        #!/bin/bash
        set -u
        [[ "$1" == "xctrace" ]] && shift
        case "$1 $2" in
          "list templates")
            [[ "#{mode}" == "slow-valid" ]] && sleep 6
            [[ "#{mode}" == "discovery-failure" ]] && exit 9
            echo "Time Profiler"
            ;;
          "record --template")
            output=""
            notification_key=""
            while (($#)); do
              case "$1" in
                --output) output="$2"; shift 2 ;;
                --notify-tracing-started) notification_key="$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            case "#{mode}" in
              delayed-ready) sleep 2 ; /usr/bin/notifyutil -p "$notification_key"; mkdir -p "$output"; printf 'trace' >"$output/data"; exit 0 ;;
              missing) /usr/bin/notifyutil -p "$notification_key"; exit 0 ;;
              invalid) /usr/bin/notifyutil -p "$notification_key"; mkdir -p "$output"; printf 'junk' >"$output/data"; exit 0 ;;
              valid|slow-valid) /usr/bin/notifyutil -p "$notification_key"; mkdir -p "$output"; printf 'trace' >"$output/data"; exit 0 ;;
              resistant) echo $$ >"$WAVES_TEST_RECORDER_PID_FILE"; trap '' TERM; while :; do sleep 1; done ;;
              ready-resistant) /usr/bin/notifyutil -p "$notification_key"; echo $$ >"$WAVES_TEST_RECORDER_PID_FILE"; trap '' TERM; while :; do sleep 1; done ;;
            esac
            ;;
          "export --input")
            if [[ "#{mode}" == "valid" || "#{mode}" == "slow-valid" || "#{mode}" == "delayed-ready" ]]; then
              printf '%s\n' '<?xml version="1.0"?><trace-toc></trace-toc>'
              exit 0
            fi
            exit 10
            ;;
          *) exit 2 ;;
        esac
      SH
      FileUtils.chmod(0o755, fake_xctrace)
      output = File.join(directory, "evidence")
      target = Process.spawn("/bin/sleep", "10")
      recorder_pid_file = File.join(directory, "recorder.pid")
      environment = {
        "DEVELOPER_DIR" => developer,
        "WAVES_RUNTIME_TEST_XCRUN_TOOL" => fake_xctrace,
        "WAVES_TEST_RECORDER_PID_FILE" => recorder_pid_file
      }
      environment["WAVES_RUNTIME_TEST_OUTER_TIMEOUT"] = outer_timeout.to_s if outer_timeout
      environment["WAVES_RUNTIME_TEST_START_TIMEOUT"] = start_timeout.to_s if start_timeout
      environment["WAVES_RUNTIME_TEST_RECORDER_TIMEOUT"] = recorder_timeout.to_s if recorder_timeout
      command = [
        "/bin/bash", COLLECTOR,
        "--pid", target.to_s,
        "--executable", "/bin/sleep",
        "--sha256", Digest::SHA256.file("/bin/sleep").hexdigest,
        "--scenario", "current-state",
        "--duration", "0.1",
        "--sample-interval", "0.05",
        "--output", output
      ]
      collector_pid = nil
      begin
        stdout = stderr = ""
        status = nil
        Open3.popen3(environment, *command, pgroup: true) do |stdin, out, err, wait_thread|
          collector_pid = wait_thread.pid
          stdin.close
          stdout_reader = Thread.new { out.read }
          stderr_reader = Thread.new { err.read }
          Timeout.timeout(12) { status = wait_thread.value }
          stdout = stdout_reader.value
          stderr = stderr_reader.value
        end
        summary = File.file?(File.join(output, "summary.json")) ? JSON.parse(File.read(File.join(output, "summary.json"))) : nil
        return [stdout, stderr, status, summary]
      rescue Timeout::Error
        Process.kill("KILL", -collector_pid) rescue nil
        return ["", "test timeout", nil, nil]
      ensure
        if File.file?(recorder_pid_file)
          recorder_pid = Integer(File.read(recorder_pid_file)) rescue nil
          Process.kill("KILL", -recorder_pid) rescue nil if recorder_pid
          Process.kill("KILL", recorder_pid) rescue nil if recorder_pid
        end
        Process.kill("TERM", target) rescue nil
        Process.wait(target) rescue nil
      end
    end
  end

  def test_complete_bound_evidence_is_reported_complete_without_release_pass_claim
    stdout, stderr, status = analyze(base_record)
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal "complete", result.fetch("evidenceStatus")
    refute result.key?("releasePass")
    assert_equal false, result.fetch("soakComparison").fetch("available")
    assert_match(/insufficient/, result.fetch("soakComparison").fetch("reason"))
  end

  def test_malformed_input_and_missing_scenario_or_identity_fail_closed
    Dir.mktmpdir do |directory|
      path = File.join(directory, "bad.json")
      File.write(path, "{bad")
      _stdout, stderr, status = Open3.capture3("/usr/bin/ruby", ANALYZER, path)
      refute status.success?
      assert_match(/not valid JSON/, stderr)
    end

    record = base_record
    record.delete("scenario")
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "failed", result.fetch("evidenceStatus")
    assert_includes result.fetch("reasons").join(" "), "scenario"

    record = base_record
    record.fetch("identity").delete("executableSHA256")
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "failed", result.fetch("evidenceStatus")
    assert_includes result.fetch("reasons").join(" "), "identity"
  end

  def test_missing_timing_metrics_are_incomplete_and_are_not_treated_as_zero
    record = base_record
    record["runtimeTimingEvidence"]["deadlineMissCount"] = nil
    record["missingMetrics"] << "deadlineMissCount: no process-bound telemetry"
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "incomplete", result.fetch("evidenceStatus")
    assert_includes result.fetch("reasons").join(" "), "deadlineMissCount"
  end

  def test_process_start_identity_and_time_profiler_status_are_required
    record = base_record
    record.fetch("identity").delete("processStartObservation")
    stdout, _stderr, status = analyze(record)
    assert status.success?
    assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")

    [nil, {}, { "status" => "bogus" }].each do |time_profiler|
      record = base_record
      record["tools"] = time_profiler.nil? ? nil : { "timeProfiler" => time_profiler }
      stdout, _stderr, status = analyze(record)
      assert status.success?
      assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")
    end

    record = base_record
    record["tools"]["timeProfiler"] = { "status" => "unavailable", "reason" => "template absent", "tocValidated" => false }
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "incomplete", result.fetch("evidenceStatus")
    assert_includes result.fetch("reasons").join(" "), "Time Profiler"

    record = base_record
    record["tools"]["timeProfiler"] = { "status" => "failed", "reason" => "export timeout", "tocValidated" => false }
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "failed", result.fetch("evidenceStatus")
    assert_includes result.fetch("reasons").join(" "), "Time Profiler"

    record = base_record
    record["tools"]["timeProfiler"]["tocValidated"] = false
    stdout, _stderr, status = analyze(record)
    assert status.success?
    assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")
  end

  def test_invalid_numeric_values_and_unbound_provenance_fail_closed
    [-1, "2"].each do |bad_value|
      record = base_record
      record.fetch("samples").first["residentBytes"] = bad_value
      stdout, _stderr, status = analyze(record)
      assert status.success?
      assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")
    end

    Dir.mktmpdir do |directory|
      path = File.join(directory, "summary.json")
      serialized = JSON.pretty_generate(base_record).sub("10000000", "1e1000")
      File.write(path, serialized)
      stdout, stderr, status = Open3.capture3("/usr/bin/ruby", ANALYZER, path)
      assert status.success?, stderr
      assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")
    end

    record = base_record
    record.fetch("runtimeTimingEvidence").fetch("deadlineMissCount").fetch("provenance")["scenario"] = "route-churn"
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "failed", result.fetch("evidenceStatus")
    assert_includes result.fetch("reasons").join(" "), "provenance"
  end

  def test_callback_over_buffer_and_positive_miss_or_overload_fail
    {
      "maximumCallbackDurationSeconds" => metric(0.011, "seconds"),
      "deadlineMissCount" => metric(1, "count"),
      "overloadCount" => metric(1, "count")
    }.each do |key, value|
      record = base_record
      record.fetch("runtimeTimingEvidence")[key] = value
      stdout, _stderr, status = analyze(record)
      assert status.success?
      result = JSON.parse(stdout)
      assert_equal "failed", result.fetch("evidenceStatus"), key
      assert_includes result.fetch("reasons").join(" "), key
    end
  end

  def test_failed_or_interrupted_collector_status_fails_closed
    %w[failed incomplete].each do |collector_status|
      record = base_record
      record.fetch("result")["status"] = collector_status
      stdout, _stderr, status = analyze(record)
      assert status.success?
      assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")
    end

    record = base_record
    record.fetch("result")["interrupted"] = true
    stdout, _stderr, status = analyze(record)
    assert status.success?
    assert_equal "failed", JSON.parse(stdout).fetch("evidenceStatus")
  end

  def test_two_hour_coverage_compares_windows_and_flags_monotonic_growth
    record = base_record
    record.fetch("request")["durationSeconds"] = 7200.0
    record.fetch("result")["actualDurationSeconds"] = 7200.0
    record["samples"] = (0..120).map do |index|
      {
        "elapsedSeconds" => index * 60.0,
        "cpuPercent" => 2.0 + index * 0.01,
        "residentBytes" => 10_000_000 + index * 1000,
        "threadCount" => 4,
        "descriptorCount" => 8,
        "failures" => []
      }
    end
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    comparison = result.fetch("soakComparison")
    assert_equal true, comparison.fetch("available")
    assert_includes comparison.fetch("monotonicGrowthMetrics"), "residentBytes"
    assert_includes comparison.fetch("monotonicGrowthMetrics"), "cpuPercent"
    assert_equal false, comparison.fetch("leakDiagnosis")
  end

  def test_clustered_soak_samples_do_not_satisfy_window_coverage
    record = base_record
    record.fetch("request")["durationSeconds"] = 7200.0
    record.fetch("request")["sampleIntervalSeconds"] = 60.0
    record.fetch("result")["actualDurationSeconds"] = 7200.0
    first = (0...15).map { |index| index * 2.0 }
    middle = (1..90).map { |index| 900.0 + index * 60.0 }
    last = (0...15).map { |index| 7170.0 + index * 2.0 }
    record["samples"] = (first + middle + last).each_with_index.map do |elapsed, index|
      {
        "elapsedSeconds" => elapsed,
        "cpuPercent" => 2.0,
        "residentBytes" => 10_000_000 + index,
        "threadCount" => 4,
        "descriptorCount" => 8,
        "failures" => []
      }
    end
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal false, result.fetch("soakComparison").fetch("available")
    assert_match(/temporal coverage/, result.fetch("soakComparison").fetch("reason"))
  end

  def test_failed_samples_are_reported_as_incomplete_not_zero
    record = base_record
    record.fetch("samples").first["cpuPercent"] = nil
    record.fetch("samples").first["failures"] = ["cpuPercent: ps deadline exceeded"]
    stdout, _stderr, status = analyze(record)
    assert status.success?
    result = JSON.parse(stdout)
    assert_equal "incomplete", result.fetch("evidenceStatus")
    assert_equal 1, result.fetch("sampleFailureCount")
  end

  def test_collector_requires_all_identity_and_bounding_arguments
    _stdout, stderr, status = Open3.capture3("/bin/bash", COLLECTOR)
    refute status.success?
    assert_match(/Usage:/, stderr)

    Dir.mktmpdir do |directory|
      output = File.join(directory, "new-output")
      _stdout, stderr, status = Open3.capture3(
        "/bin/bash", COLLECTOR,
        "--pid", Process.pid.to_s,
        "--executable", RbConfig.ruby,
        "--sha256", SHA,
        "--scenario", "not-documented",
        "--duration", "1",
        "--sample-interval", "1",
        "--output", output
      )
      refute status.success?
      assert_match(/scenario/, stderr)
      refute File.exist?(output)
    end
  end

  def test_collector_does_not_record_missing_or_unusable_trace_artifacts
    %w[missing invalid].each do |mode|
      _stdout, stderr, status, summary = collect_with_fake_xctrace(mode: mode)
      assert status&.success?, stderr
      tool = summary.fetch("tools").fetch("timeProfiler")
      assert_equal "failed", tool.fetch("status"), mode
      assert_equal false, tool.fetch("tocValidated"), mode
    end
  end

  def test_collector_records_trace_only_after_bounded_toc_validation
    _stdout, stderr, status, summary = collect_with_fake_xctrace(mode: "valid")
    assert status&.success?, stderr
    tool = summary.fetch("tools").fetch("timeProfiler")
    assert_equal "recorded", tool.fetch("status")
    assert_equal true, tool.fetch("tocValidated")
  end

  def test_sampling_duration_excludes_trace_setup_and_finalization
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _stdout, stderr, status, summary = collect_with_fake_xctrace(mode: "slow-valid")
    wall_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert status&.success?, stderr
    sampling_duration = summary.fetch("result").fetch("actualDurationSeconds")
    assert_equal "recorded", summary.dig("tools", "timeProfiler", "status")
    assert_operator sampling_duration, :>=, 0.1
    assert_operator sampling_duration, :<, wall_time - 5.5
  end

  def test_sampling_starts_only_after_delayed_darwin_readiness
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _stdout, stderr, status, summary = collect_with_fake_xctrace(mode: "delayed-ready")
    wall_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert status&.success?, stderr
    assert_operator wall_time, :>=, 2
    assert_equal true, summary.dig("tools", "timeProfiler", "recordingStartSynchronized")
    assert_operator summary.dig("result", "actualDurationSeconds"), :<, wall_time - 1.5
  end

  def test_never_posting_term_resistant_recorder_fails_start_and_preserves_numeric_samples
    _stdout, stderr, status, summary = collect_with_fake_xctrace(
      mode: "resistant", outer_timeout: 8, start_timeout: 1
    )
    assert status&.success?, stderr
    tool = summary.fetch("tools").fetch("timeProfiler")
    assert_equal "failed", tool.fetch("status")
    assert_match(/recording-start/, tool.fetch("reason"))
    assert_equal false, tool.fetch("recordingStartSynchronized")
    assert_operator summary.fetch("samples").length, :>=, 1
  end

  def test_absolute_recorder_deadline_stops_ready_term_resistant_recorder
    _stdout, stderr, status, summary = collect_with_fake_xctrace(
      mode: "ready-resistant", outer_timeout: 8, recorder_timeout: 1
    )
    assert status&.success?, stderr
    tool = summary.fetch("tools").fetch("timeProfiler")
    assert_equal "failed", tool.fetch("status")
    assert_match(/absolute recorder deadline/, tool.fetch("reason"))
    assert_equal true, tool.fetch("recordingStartSynchronized")
  end

  def test_installed_time_profiler_discovery_failure_is_failed_not_unavailable
    _stdout, stderr, status, summary = collect_with_fake_xctrace(mode: "discovery-failure")
    assert status&.success?, stderr
    tool = summary.fetch("tools").fetch("timeProfiler")
    assert_equal "failed", tool.fetch("status")
    assert_match(/discovery/, tool.fetch("reason"))
  end

  def test_outer_deadline_stops_term_resistant_recorder
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _stdout, _stderr, status, summary = collect_with_fake_xctrace(mode: "resistant", outer_timeout: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    refute_nil status, "collector exceeded the test's 5-second safety deadline"
    refute status.success?
    assert_operator elapsed, :<, 5
    assert_equal "failed", summary.fetch("result").fetch("status")
  end
end
