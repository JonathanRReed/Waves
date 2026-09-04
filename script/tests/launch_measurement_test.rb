require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"

ANALYZER = File.expand_path("../analyze_launch_measurements.rb", __dir__)
COLLECTOR = File.expand_path("../measure_launch.sh", __dir__)

class LaunchMeasurementTest < Minitest::Test
  SHA = "a" * 64

  def record(run:, margin: 200_000_000, passed: true, sha: SHA)
    {
      run: run, version: "1.7.1", build: 19, artifactSHA256: sha,
      processStartNs: -20_000_000, firstFrameNs: 80_000_000,
      controlConfirmedNs: 300_000_000, dockSettledNs: 300_000_000 - margin,
      passed: passed
    }
  end

  def write_jsonl(path, records)
    File.write(path, records.map { |value| JSON.generate(value) }.join("\n") + "\n")
  end

  def analyze(records)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "runs.jsonl")
      write_jsonl(path, records)
      stdout, stderr, status = Open3.capture3("/usr/bin/ruby", ANALYZER, path)
      return [stdout, stderr, status]
    end
  end

  def test_exactly_30_consistent_records_qualify
    stdout, stderr, status = analyze((1..30).map { |run| record(run: run, margin: -200_000_000) })
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal true, result.fetch("qualified")
    assert_equal 30, result.fetch("recordCount")
    assert_equal 30, result.fetch("passCount")
    assert_equal(-200_000_000, result.fetch("p50ControlMinusDockNs"))
    assert_equal(-200_000_000, result.fetch("p95ControlMinusDockNs"))
  end

  def test_nearest_rank_percentiles_and_29_pass_threshold
    margins = (1..30).map { |value| value * 10_000_000 }
    records = margins.each_with_index.map do |margin, index|
      record(run: index + 1, margin: margin, passed: index != 0)
    end
    stdout, stderr, status = analyze(records)
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal 29, result.fetch("passCount")
    assert_equal 150_000_000, result.fetch("p50ControlMinusDockNs")
    assert_equal 290_000_000, result.fetch("p95ControlMinusDockNs")
    assert_equal false, result.fetch("qualified")

    records = (1..30).map { |run| record(run: run, margin: -200_000_000, passed: run != 1) }
    stdout, stderr, status = analyze(records)
    assert status.success?, stderr
    assert_equal true, JSON.parse(stdout).fetch("qualified")
  end

  def test_28_passes_do_not_qualify
    records = (1..30).map { |run| record(run: run, margin: -200_000_000, passed: run > 2) }
    stdout, stderr, status = analyze(records)
    assert status.success?, stderr
    assert_equal false, JSON.parse(stdout).fetch("qualified")
  end

  def test_p95_control_minus_dock_must_be_at_most_negative_150_ms
    passing = (1..30).map { |run| record(run: run, margin: -150_000_000) }
    stdout, stderr, status = analyze(passing)
    assert status.success?, stderr
    assert_equal(-150_000_000, JSON.parse(stdout).fetch("p95ControlMinusDockNs"))
    assert_equal true, JSON.parse(stdout).fetch("qualified")

    failing = (1..30).map { |run| record(run: run, margin: -149_999_999) }
    stdout, stderr, status = analyze(failing)
    assert status.success?, stderr
    assert_equal false, JSON.parse(stdout).fetch("qualified")
  end

  def test_missing_milestone_is_rejected
    records = (1..30).map { |run| record(run: run) }
    records[4].delete(:firstFrameNs)
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/firstFrameNs/, stderr)
  end

  def test_inconsistent_artifact_identity_is_rejected
    records = (1..30).map { |run| record(run: run) }
    records[-1][:artifactSHA256] = "b" * 64
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/artifact identity/, stderr)
  end

  def test_malformed_json_duplicate_runs_and_wrong_count_are_rejected
    stdout, stderr, status = Open3.capture3("/usr/bin/ruby", ANALYZER, stdin_data: "{bad\n")
    refute status.success?
    assert_match(/line 1/, stderr)

    records = (1..29).map { |run| record(run: run) }
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/exactly 30/, stderr)

    records << record(run: 29)
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/run identities/, stderr)
  end

  def test_collector_cli_rejects_missing_required_arguments_before_launch
    _stdout, stderr, status = Open3.capture3("/bin/bash", COLLECTOR)
    refute status.success?
    assert_match(/Usage:/, stderr)
  end

  def test_collector_rejects_bad_hash_and_incomplete_observation_without_launching
    Dir.mktmpdir do |directory|
      app = File.join(directory, "Waves.app")
      FileUtils.mkdir_p(File.join(app, "Contents"))
      observation = File.join(directory, "observation.json")
      File.write(observation, JSON.generate(processStartMachContinuousNs: 1))
      output = File.join(directory, "runs.jsonl")
      _stdout, stderr, status = Open3.capture3(
        "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "1", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", "bad", "--observation", observation
      )
      refute status.success?
      assert_match(/64 lowercase hexadecimal/, stderr)
      refute File.exist?(output)
    end
  end

  def test_collector_uses_real_fake_tool_output_to_append_one_record
    Dir.mktmpdir do |directory|
      app = File.join(directory, "Waves.app")
      executable = File.join(app, "Contents", "MacOS", "FixtureWaves")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "fixture executable\n")
      FileUtils.chmod(0o755, executable)
      File.write(File.join(app, "Contents", "Info.plist"), <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleShortVersionString</key><string>1.7.1</string>
          <key>CFBundleVersion</key><string>19</string>
          <key>CFBundleExecutable</key><string>FixtureWaves</string>
          <key>CFBundleIdentifier</key><string>com.example.fixture-waves</string>
        </dict></plist>
      PLIST
      observation = File.join(directory, "observation.json")
      output = File.join(directory, "runs.jsonl")
      fake_log = File.join(directory, "fake-log")
      File.write(fake_log, <<~SH)
        #!/bin/bash
        echo '{"machContinuousTime":1000,"eventMessage":"ProcessInit elapsedNs=10"}'
        echo '{"machContinuousTime":1190,"eventMessage":"FirstControlConfirmed elapsedNs=200"}'
        sleep 10
      SH
      fake_open = File.join(directory, "fake-open")
      File.write(fake_open, <<~SH)
        #!/bin/bash
        printf '%s\n' '{"clock":"machContinuousTimeNanoseconds","processStartMachContinuousNs":900,"firstFrameMachContinuousNs":1100,"dockSettledMachContinuousNs":1390,"processStartEvidenceSHA256":"#{SHA}","firstFrameEvidenceSHA256":"#{SHA}","dockSettledEvidenceSHA256":"#{SHA}"}' > "$WAVES_TEST_OBSERVATION"
      SH
      FileUtils.chmod(0o755, [fake_log, fake_open])
      sha = Digest::SHA256.file(executable).hexdigest
      env = { "WAVES_LOG_TOOL" => fake_log, "WAVES_OPEN_TOOL" => fake_open, "WAVES_TEST_OBSERVATION" => observation }
      stdout, stderr, status = Open3.capture3(
        env, "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "1", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", sha, "--observation", observation, "--timeout", "2"
      )
      assert status.success?, stderr
      assert_match(/Appended run 1/, stdout)
      record = JSON.parse(File.read(output))
      assert_equal(-90, record.fetch("processStartNs"))
      assert_equal 110, record.fetch("firstFrameNs")
      assert_equal 200, record.fetch("controlConfirmedNs")
      assert_equal 400, record.fetch("dockSettledNs")
      assert_equal true, record.fetch("passed")
    end
  end
end
