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

  def record(run:, margin: -200_000_000, passed: nil, sha: SHA)
    passed = margin.negative? if passed.nil?
    {
      run: run, version: "1.7.1", build: 19, artifactSHA256: sha,
      processStartNs: -20_000_000, firstFrameNs: 80_000_000,
      controlConfirmedNs: 300_000_000, dockSettledNs: 300_000_000 - margin,
      passed: passed, attemptManifestSHA256: nil
    }
  end

  def write_jsonl(path, records)
    File.write(path, records.map { |value| JSON.generate(value) }.join("\n") + "\n")
  end

  def analyze(records, failed_runs: [], mutate: nil)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "runs.jsonl")
      evidence_root = "#{path}.evidence"
      FileUtils.mkdir_p(evidence_root)
      index_entries = []
      (1..30).each do |run|
        attempt_directory = File.join(evidence_root, "attempt-#{run}")
        FileUtils.mkdir(attempt_directory)
        source = records.find { |record| record[:run] == run } || record(run: run)
        identity = { run: run, version: source[:version], build: source[:build], artifactSHA256: source[:artifactSHA256] }
        if failed_runs.include?(run)
          raw_log_path = File.join(attempt_directory, "unified-log.ndjson")
          File.write(raw_log_path, "fixture failed log #{run}\n")
          manifest_path = File.join(attempt_directory, "manifest.json")
          File.write(manifest_path, JSON.generate(identity.merge(status: "failed", failure: "fixture failure", rawLogSHA256: Digest::SHA256.file(raw_log_path).hexdigest, sourceEvidence: [])))
          manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
          File.write(File.join(attempt_directory, "attempt.json"), JSON.generate(identity.merge(status: "failed", manifestSHA256: manifest_sha)))
          index_entries << { run: run, status: "failed", artifactSHA256: identity[:artifactSHA256], manifestSHA256: manifest_sha }
        else
          raw_log_path = File.join(attempt_directory, "unified-log.ndjson")
          File.write(raw_log_path, "fixture log #{run}\n")
          manifest = identity.merge(launchedPID: 1000 + run, rawLogSHA256: Digest::SHA256.file(raw_log_path).hexdigest, sourceEvidence: [])
          manifest_path = File.join(attempt_directory, "manifest.json")
          File.write(manifest_path, JSON.generate(manifest))
          manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
          source[:attemptManifestSHA256] = manifest_sha if records.include?(source)
          File.write(File.join(attempt_directory, "attempt.json"), JSON.generate(identity.merge(status: "completed", manifestSHA256: manifest_sha)))
          index_entries << { run: run, status: "completed", artifactSHA256: identity[:artifactSHA256], manifestSHA256: manifest_sha }
        end
      end
      write_jsonl(File.join(evidence_root, "index.jsonl"), index_entries)
      write_jsonl(path, records)
      mutate.call(path, evidence_root) if mutate
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
    margins = (1..30).map { |value| -value * 10_000_000 }
    records = margins.each_with_index.map do |margin, index|
      record(run: index + 1, margin: margin)
    end
    stdout, stderr, status = analyze(records)
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal 30, result.fetch("passCount")
    assert_equal(-160_000_000, result.fetch("p50ControlMinusDockNs"))
    assert_equal(-20_000_000, result.fetch("p95ControlMinusDockNs"))
    assert_equal false, result.fetch("qualified")

    records = (1..29).map { |run| record(run: run, margin: -200_000_000) }
    records << record(run: 30, margin: 100_000_000)
    stdout, stderr, status = analyze(records)
    assert status.success?, stderr
    assert_equal true, JSON.parse(stdout).fetch("qualified")
  end

  def test_28_passes_do_not_qualify
    records = (1..28).map { |run| record(run: run, margin: -200_000_000) }
    records << record(run: 29, margin: 100_000_000)
    records << record(run: 30, margin: 100_000_000)
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
    Dir.mktmpdir do |directory|
      malformed = File.join(directory, "bad.jsonl")
      File.write(malformed, "{bad\n")
      _stdout, stderr, status = Open3.capture3("/usr/bin/ruby", ANALYZER, malformed)
      refute status.success?
      assert_match(/line 1/, stderr)
    end

    records = (1..29).map { |run| record(run: run) }
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/completed but has no measurement/, stderr)

    records << record(run: 29)
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/run identities/, stderr)
  end

  def test_failed_or_pending_attempt_cannot_be_retried_or_qualify
    records = (1..29).map { |run| record(run: run) }
    stdout, stderr, status = analyze(records, failed_runs: [30])
    assert status.success?, stderr
    result = JSON.parse(stdout)
    assert_equal 30, result.fetch("attemptCount")
    assert_equal 1, result.fetch("failedOrPendingAttemptCount")
    assert_equal false, result.fetch("qualified")
  end

  def test_pass_flag_and_milestone_order_are_validated
    records = (1..30).map { |run| record(run: run) }
    records[0][:passed] = false
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/passed conflicts/, stderr)

    records = (1..30).map { |run| record(run: run) }
    records[0][:firstFrameNs] = 400_000_000
    _stdout, stderr, status = analyze(records)
    refute status.success?
    assert_match(/invalid process, frame, control, or Dock ordering/, stderr)
  end

  def test_manifest_tampering_and_extra_attempt_are_rejected
    records = (1..30).map { |run| record(run: run) }
    tamper = lambda do |_path, evidence_root|
      File.open(File.join(evidence_root, "attempt-1", "manifest.json"), "a") { |file| file.write(" ") }
    end
    _stdout, stderr, status = analyze(records, mutate: tamper)
    refute status.success?
    assert_match(/manifest hash does not match/, stderr)

    records = (1..30).map { |run| record(run: run) }
    raw_tamper = lambda do |_path, evidence_root|
      File.open(File.join(evidence_root, "attempt-1", "unified-log.ndjson"), "a") { |file| file.write("tampered\n") }
    end
    _stdout, stderr, status = analyze(records, mutate: raw_tamper)
    refute status.success?
    assert_match(/raw log does not match/, stderr)

    records = (1..30).map { |run| record(run: run) }
    extra = ->(_path, evidence_root) { FileUtils.mkdir(File.join(evidence_root, "attempt-31")) }
    _stdout, stderr, status = analyze(records, mutate: extra)
    refute status.success?
    assert_match(/exactly 1 through 30/, stderr)
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
      process_state = File.join(directory, "launched-pid")
      evidence = File.join(directory, "capture.mov")
      mach_evidence = File.join(directory, "sync-events.jsonl")
      File.write(evidence, "real fixture source bytes\n")
      File.write(mach_evidence, "{\"eventID\":\"sync-start\",\"machContinuousTicks\":24000000}\n{\"eventID\":\"sync-middle\",\"machContinuousTicks\":38000000}\n{\"eventID\":\"sync-end\",\"machContinuousTicks\":48000000}\n")
      fake_log = File.join(directory, "fake-log")
      File.write(fake_log, <<~SH)
        #!/bin/bash
        echo 'Filtering the log data using "subsystem == fixture"'
        while [[ ! -f "$WAVES_TEST_PROCESS_STATE" ]]; do sleep 0.01; done
        echo '{"eventType":"signpostEvent","signpostType":"event","signpostName":"ProcessInit","eventMessage":"elapsedNs=999","processID":999,"processImagePath":"#{executable}","machTimestamp":20000000}'
        echo '{"eventType":"signpostEvent","signpostType":"event","signpostName":"FirstControlConfirmed","eventMessage":"elapsedNs=999","processID":999,"processImagePath":"#{executable}","machTimestamp":21000000}'
        sleep 0.2
        echo '{"eventType":"signpostEvent","signpostType":"event","signpostName":"ProcessInit","eventMessage":"elapsedNs=1000","processID":4242,"processImagePath":"#{executable}","machTimestamp":30000000}'
        echo '{"eventType":"signpostEvent","signpostType":"event","signpostName":"FirstControlConfirmed","eventMessage":"elapsedNs=200000000","processID":4242,"processImagePath":"#{executable}","machTimestamp":34800000}'
        sleep 10
      SH
      fake_open = File.join(directory, "fake-open")
      File.write(fake_open, <<~SH)
        #!/bin/bash
        echo 4242 > "$WAVES_TEST_PROCESS_STATE"
        printf '%s\n' '{"sourceClock":{"name":"video-frame-clock","ticksPerSecond":1000000},"conversionMethod":"linear-interpolation","syncPairs":[{"eventID":"sync-start","sourceTicks":0,"machContinuousTicks":24000000,"sourceEvidenceFile":"#{evidence}","sourceEvidenceLocator":"frame 0","machEvidenceFile":"#{mach_evidence}","machEvidenceLocator":"line 1","machCaptureCommand":"./capture-sync-marker --event sync-start","sourceUncertaintyTicks":1,"machUncertaintyTicks":100},{"eventID":"sync-end","sourceTicks":1000000,"machContinuousTicks":48000000,"sourceEvidenceFile":"#{evidence}","sourceEvidenceLocator":"frame 60","machEvidenceFile":"#{mach_evidence}","machEvidenceLocator":"line 2","machCaptureCommand":"./capture-sync-marker --event sync-end","sourceUncertaintyTicks":1,"machUncertaintyTicks":100}],"processStartSourceTicks":100000,"firstFrameSourceTicks":300000,"dockSettledSourceTicks":900000,"evidenceFiles":["#{evidence}","#{mach_evidence}"]}' > "$WAVES_TEST_OBSERVATION"
      SH
      fake_process = File.join(directory, "fake-process")
      File.write(fake_process, <<~SH)
        #!/bin/bash
        [[ -f "$WAVES_TEST_PROCESS_STATE" ]] && cat "$WAVES_TEST_PROCESS_STATE"
      SH
      FileUtils.chmod(0o755, [fake_log, fake_open, fake_process])
      sha = Digest::SHA256.file(executable).hexdigest
      env = {
        "WAVES_LOG_TOOL" => fake_log, "WAVES_OPEN_TOOL" => fake_open,
        "WAVES_PROCESS_TOOL" => fake_process, "WAVES_TEST_OBSERVATION" => observation,
        "WAVES_TEST_PROCESS_STATE" => process_state
      }
      stdout, stderr, status = Open3.capture3(
        env, "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "1", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", sha, "--observation", observation, "--timeout", "2"
      )
      assert status.success?, stderr
      assert_match(/Appended completed attempt 1/, stdout)
      record = JSON.parse(File.read(output))
      assert_equal(-149_999_000, record.fetch("processStartNs"))
      assert_equal 50_001_000, record.fetch("firstFrameNs")
      assert_equal 200_000_000, record.fetch("controlConfirmedNs")
      assert_equal 650_001_000, record.fetch("dockSettledNs")
      assert_equal true, record.fetch("passed")
      attempt_dir = "#{output}.evidence/attempt-1"
      manifest = JSON.parse(File.read(File.join(attempt_dir, "manifest.json")))
      assert_equal 4242, manifest.fetch("launchedPID")
      assert_equal 1_000, manifest.fetch("selectedSignposts").fetch("ProcessInit").first.fetch("elapsedNs")
      assert_equal "source-01-capture.mov", manifest.fetch("syncPairs").first.fetch("sourceEvidenceFile")
      assert_equal "source-02-sync-events.jsonl", manifest.fetch("syncPairs").first.fetch("machEvidenceFile")
      assert_equal 100, manifest.fetch("syncPairs").first.fetch("machUncertaintyTicks")
      assert_equal Digest::SHA256.file(File.join(attempt_dir, "manifest.json")).hexdigest, record.fetch("attemptManifestSHA256")
      assert File.exist?(File.join(attempt_dir, "unified-log.ndjson"))
      assert File.exist?(File.join(attempt_dir, "source-01-capture.mov"))

      bound_pair = lambda do |event_id, source_ticks, mach_ticks, locator|
        {
          eventID: event_id, sourceTicks: source_ticks, machContinuousTicks: mach_ticks,
          sourceEvidenceFile: evidence, sourceEvidenceLocator: locator,
          machEvidenceFile: mach_evidence, machEvidenceLocator: "event #{event_id}",
          machCaptureCommand: "./capture-sync-marker --event #{event_id}",
          sourceUncertaintyTicks: 1, machUncertaintyTicks: 100
        }
      end
      sidecar = {
        sourceClock: { name: "video-frame-clock", ticksPerSecond: 1_000_000 },
        conversionMethod: "linear-interpolation",
        syncPairs: [bound_pair.call("sync-start", 0, 24_000_000, "frame 0"), bound_pair.call("sync-end", 1_000_000, 48_000_000, "frame 60")],
        processStartSourceTicks: 100_000, firstFrameSourceTicks: 300_000, dockSettledSourceTicks: 900_000,
        evidenceFiles: [evidence, mach_evidence]
      }
      template_open = File.join(directory, "template-open")
      File.write(template_open, <<~SH)
        #!/bin/bash
        echo 4242 > "$WAVES_TEST_PROCESS_STATE"
        cp "$WAVES_TEST_SIDECAR_TEMPLATE" "$WAVES_TEST_OBSERVATION"
      SH
      FileUtils.chmod(0o755, template_open)

      FileUtils.rm_f(process_state)
      missing_template = File.join(directory, "missing-binding-template.json")
      missing_sidecar = Marshal.load(Marshal.dump(sidecar))
      missing_sidecar[:syncPairs][0].delete(:machCaptureCommand)
      File.write(missing_template, JSON.generate(missing_sidecar))
      missing_observation = File.join(directory, "missing-binding-observation.json")
      missing_env = env.merge("WAVES_OPEN_TOOL" => template_open, "WAVES_TEST_OBSERVATION" => missing_observation, "WAVES_TEST_SIDECAR_TEMPLATE" => missing_template)
      _stdout, stderr, status = Open3.capture3(
        missing_env, "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "3", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", sha, "--observation", missing_observation, "--timeout", "2"
      )
      refute status.success?
      assert_match(/missing binding fields: machCaptureCommand/, stderr)

      FileUtils.rm_f(process_state)
      drift_template = File.join(directory, "adjacent-drift-template.json")
      drift_sidecar = Marshal.load(Marshal.dump(sidecar))
      drift_sidecar[:syncPairs].insert(1, bound_pair.call("sync-middle", 500_000, 38_000_000, "frame 30"))
      File.write(drift_template, JSON.generate(drift_sidecar))
      drift_observation = File.join(directory, "adjacent-drift-observation.json")
      drift_env = env.merge("WAVES_OPEN_TOOL" => template_open, "WAVES_TEST_OBSERVATION" => drift_observation, "WAVES_TEST_SIDECAR_TEMPLATE" => drift_template)
      _stdout, stderr, status = Open3.capture3(
        drift_env, "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "4", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", sha, "--observation", drift_observation, "--timeout", "2"
      )
      refute status.success?
      assert_match(/adjacent source-to-Mach calibration/, stderr)

      FileUtils.rm_f(process_state)
      failed_observation = File.join(directory, "failed-observation.json")
      early_log = File.join(directory, "early-log")
      File.write(early_log, <<~SH)
        #!/bin/bash
        echo 'Filtering the log data using "subsystem == fixture"'
      SH
      FileUtils.chmod(0o755, early_log)
      failed_env = env.merge("WAVES_LOG_TOOL" => early_log, "WAVES_TEST_OBSERVATION" => failed_observation)
      _stdout, stderr, status = Open3.capture3(
        failed_env, "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "2", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", sha, "--observation", failed_observation, "--timeout", "2"
      )
      refute status.success?
      assert_match(/unified-log capture exited/, stderr)
      failed_dir = "#{output}.evidence/attempt-2"
      assert_equal "failed", JSON.parse(File.read(File.join(failed_dir, "attempt.json"))).fetch("status")
      assert File.exist?(File.join(failed_dir, "unified-log.ndjson"))
      assert File.exist?(File.join(failed_dir, "manifest.json"))

      FileUtils.rm_f(process_state)
      retry_observation = File.join(directory, "retry-observation.json")
      retry_env = env.merge("WAVES_TEST_OBSERVATION" => retry_observation)
      _stdout, stderr, status = Open3.capture3(
        retry_env, "/bin/bash", COLLECTOR, "--app", app, "--output", output,
        "--run", "2", "--version", "1.7.1", "--build", "19",
        "--artifact-sha256", sha, "--observation", retry_observation, "--timeout", "2"
      )
      refute status.success?
      assert_match(/attempt 2 already exists and cannot be reused/, stderr)
    end
  end
end
