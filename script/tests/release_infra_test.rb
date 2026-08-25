# frozen_string_literal: true

require "fileutils"
require "base64"
require "json"
require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"

require_relative "../release_tool"

class ReleaseInfraTest < Minitest::Test
  VERSION = "1.7.0"
  BUILD = 16
  RELEASE_TAG = "v#{VERSION}"
  HANDOFF_NAME = "Waves-#{VERSION}-#{BUILD}-Elgato-Handoff"
  HANDOFF_DMG_NAME = "Waves-#{VERSION}-#{BUILD}.dmg"
  FLOOR = "14.2"
  REVISION = "a" * 40
  BUNDLE_IDENTIFIER = "com.jonathanreed.Waves"
  DEVELOPER_IDENTITY = "Developer ID Application: Jonathan Reed (AJ9VWBRNZN)"
  TEAM_IDENTIFIER = "AJ9VWBRNZN"
  DESIGNATED_REQUIREMENT = <<~REQUIREMENT.strip
    identifier "com.jonathanreed.Waves" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = AJ9VWBRNZN
  REQUIREMENT
  RELEASE_PRINCIPAL = "waves-commit-signing"
  RELEASE_PUBLIC_KEY =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPJaVZPTQXnIIPdGksw4PmO3yBLuqEkd+qE4SALWpFpQ waves-commit-signing"
  RELEASE_FINGERPRINT = "SHA256:53uCiv5rg7roncACotblHKo4OvHAsvYw/+x/5pU0mCQ"
  SPARKLE_ACCOUNT = "com.jonathanreed.Waves"
  SPARKLE_PUBLIC_KEY = "STuJLAcpixKkpAOx/hk/ZRSWr3KipzbPhluuYqRXlgg="

  def test_dmg_builder_configures_and_verifies_premium_finder_layout
    root = File.expand_path("../..", __dir__)
    build_script = File.read(File.join(root, "script/build_and_run.sh"))
    renderer_path = File.join(root, "script/render-dmg-background.swift")
    finder_script_path = File.join(root, "script/configure-dmg.applescript")

    assert File.file?(renderer_path), "DMG background renderer must be checked in"
    assert File.file?(finder_script_path), "Finder layout script must be checked in"
    assert_includes build_script, "render-dmg-background.swift"
    assert_includes build_script, "configure-dmg.applescript"
    assert_includes build_script, "-format UDRW"
    assert_includes build_script, "hdiutil convert"
    assert_includes build_script, ".background"
    assert_includes build_script, ".DS_Store"
    assert_includes build_script, "finder_metadata_attempt"
    assert_includes build_script, '/private/tmp/waves-dmg-layout.XXXXXX'
    assert_includes build_script, '/private/tmp/waves-dmg-mount.XXXXXX'

    finder_script = File.read(finder_script_path)
    assert_includes finder_script, "set bounds of layoutWindow to {100, 100, 760, 530}"
    assert_includes finder_script, "set icon size of icon view options of layoutWindow to 128"
    assert_includes finder_script, "set toolbar visible of layoutWindow to false"
    assert_includes finder_script, "set sidebar width of layoutWindow to 0"
    assert_includes finder_script,
                    'set backgroundFile to POSIX file (mountPath & "/.background/Waves.png") as alias'
    assert_includes finder_script,
                    "set background picture of icon view options of layoutWindow to backgroundFile"
    assert_includes finder_script,
                    'set position of item ".background" of targetFolder to {590, 80}'
    refute_includes finder_script,
                    'file "Waves.png" of folder ".background" of targetFolder'
  end

  def test_dmg_background_renderer_matches_the_660_by_430_finder_window
    root = File.expand_path("../..", __dir__)
    renderer_path = File.join(root, "script/render-dmg-background.swift")
    Dir.mktmpdir("waves-dmg-background") do |directory|
      output = File.join(directory, "Waves.png")
      swift = Open3.capture2("/usr/bin/xcrun", "--find", "swift").first.strip
      stdout, stderr, status = Open3.capture3(swift, renderer_path, output)
      assert status.success?, "renderer failed: #{stdout}\n#{stderr}"
      assert File.file?(output)

      dimensions, dimension_error, dimension_status = Open3.capture3(
        "/usr/bin/sips",
        "-g",
        "pixelWidth",
        "-g",
        "pixelHeight",
        output
      )
      assert dimension_status.success?, dimension_error
      assert_match(/pixelWidth: 660/, dimensions)
      assert_match(/pixelHeight: 430/, dimensions)

      contrast_probe = File.join(directory, "contrast-probe.swift")
      File.write(
        contrast_probe,
        <<~SWIFT
          import AppKit
          import Foundation

          let url = URL(fileURLWithPath: CommandLine.arguments[1])
          guard let data = try? Data(contentsOf: url),
                let bitmap = NSBitmapImageRep(data: data) else {
            exit(2)
          }
          for point in [NSPoint(x: 170, y: 330), NSPoint(x: 490, y: 330)] {
            guard let color = bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB) else {
              exit(3)
            }
            let luminance = (0.2126 * color.redComponent)
              + (0.7152 * color.greenComponent)
              + (0.0722 * color.blueComponent)
            print(luminance)
          }
        SWIFT
      )
      contrast, contrast_error, contrast_status = Open3.capture3(swift, contrast_probe, output)
      assert contrast_status.success?, contrast_error
      luminances = contrast.lines.map { |line| Float(line) }
      assert_equal 2, luminances.length
      assert luminances.all? { |value| value >= 0.6 },
             "Finder icon label zones must remain light enough for its black labels: #{luminances.inspect}"
    end
  end

  def metadata_hash
    security_metadata_hash
  end

  def legacy_metadata_hash
    {
      "schemaVersion" => 1,
      "version" => VERSION,
      "build" => BUILD,
      "minimumMacOSVersion" => FLOOR,
      "bundleIdentifier" => BUNDLE_IDENTIFIER,
      "developerID" => {
        "identity" => DEVELOPER_IDENTITY,
        "teamIdentifier" => TEAM_IDENTIFIER,
        "designatedRequirement" => DESIGNATED_REQUIREMENT,
      },
    }
  end

  def security_metadata_hash(
    public_key: RELEASE_PUBLIC_KEY,
    fingerprint: RELEASE_FINGERPRINT,
    principal: RELEASE_PRINCIPAL
  )
    legacy_metadata_hash.merge(
      "releaseAuthority" => {
        "principal" => principal,
        "publicKey" => public_key,
        "fingerprint" => fingerprint,
        "receiptIssuers" => {
          "securityScan" => "codex-security",
          "remoteElgato" => "golden-gate-elgato",
        },
      },
      "sparkle" => {
        "keychainAccount" => SPARKLE_ACCOUNT,
        "publicEDKey" => SPARKLE_PUBLIC_KEY,
      }
    )
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(value) + "\n")
  end

  def with_metadata(contents = metadata_hash)
    Dir.mktmpdir("waves-release-metadata") do |directory|
      path = File.join(directory, "metadata.json")
      contents.is_a?(String) ? File.write(path, contents) : write_json(path, contents)
      yield path
    end
  end

  def evidence_input(remote: "pending", revision: REVISION)
    passed_gate = ->(detail) { {"status" => "passed", "detail" => detail} }
    {
      "source" => {
        "revision" => revision,
        "trackedDirty" => false,
        "untrackedBuildInputs" => false,
        "sourceArchiveSHA256" => "4" * 64,
        "buildRecipeSHA256" => "5" * 64,
      },
      "toolchain" => {
        "swift" => "Swift 6.2.1",
        "xcode" => "Xcode 26.1",
        "macOS" => "26.0",
      },
      "tests" => {
        "swift" => {"passed" => 482, "failed" => 0},
        "renderedUI" => {"passed" => 4, "failed" => 0},
        "threadSanitizer" => {"passed" => 12, "failed" => 0},
      },
      "performance" => {
        "launchTime" => performance_metric,
        "idleCPU" => performance_metric,
        "steadyMemory" => performance_metric,
        "activeMixing" => performance_metric,
      },
      "platforms" => {
        "goldenGateNative" => passed_gate.call("native host receipt"),
        "rosetta" => passed_gate.call("x86_64 receipt"),
        "tahoeAppleSilicon" => passed_gate.call("Tahoe receipt"),
        "sequoiaAppleSilicon" => passed_gate.call("Sequoia receipt"),
        "sonomaPhysical" => {
          "status" => "unavailable",
          "detail" => "No physical Sonoma host was available; the 14.2 floor was verified from Mach-O metadata.",
        },
      },
      "package" => {
        "bundleIdentifier" => BUNDLE_IDENTIFIER,
        "version" => VERSION,
        "build" => BUILD,
        "minimumMacOSVersion" => FLOOR,
        "architectures" => ["arm64", "x86_64"],
        "hashes" => {
          "appExecutable" => "1" * 64,
          "dmg" => "2" * 64,
          "dSYM" => "3" * 64,
        },
        "developerID" => {
          "status" => "passed",
          "identity" => DEVELOPER_IDENTITY,
          "teamIdentifier" => TEAM_IDENTIFIER,
          "designatedRequirement" => DESIGNATED_REQUIREMENT,
        },
        "hardenedRuntime" => passed_gate.call("runtime flag"),
        "notarization" => {
          "status" => "passed",
          "submissionID" => "11111111-2222-3333-4444-555555555555",
          "detail" => "accepted submission",
          "artifactSHA256" => "2" * 64,
          "logSHA256" => "8" * 64,
        },
        "stapling" => passed_gate.call("ticket validated"),
        "gatekeeper" => passed_gate.call("app and DMG accepted"),
      },
      "gates" => required_gates.to_h { |name| [name, passed_gate.call("#{name} receipt")] }.merge(
        "remoteElgato" => {
          "status" => remote,
          "detail" => remote == "passed" ? "remote hardware receipt" : "awaiting remote hardware receipt",
        }
      ),
      "skippedGates" => [],
      "skipCIEquivalentEvidence" => [],
      "externalReceipts" => {
        "securityScan" => {
          "issuer" => "codex-security",
          "sourceRevision" => revision,
          "artifactSHA256" => "2" * 64,
          "receiptSHA256" => "6" * 64,
        },
      }.tap do |receipts|
        if remote == "passed"
          receipts["remoteElgato"] = {
            "issuer" => "golden-gate-elgato",
            "sourceRevision" => revision,
            "artifactSHA256" => "2" * 64,
            "receiptSHA256" => "7" * 64,
          }
        end
      end,
    }
  end

  def security_evidence_input(remote: "pending", revision: REVISION)
    input = evidence_input(remote: remote, revision: revision)
    dmg_hash = input.fetch("package").fetch("hashes").fetch("dmg")
    input.fetch("package").fetch("notarization").merge!(
      "artifactSHA256" => dmg_hash,
      "logSHA256" => "8" * 64
    )
    receipts = {
      "securityScan" => {
        "issuer" => "codex-security",
        "sourceRevision" => revision,
        "artifactSHA256" => dmg_hash,
        "receiptSHA256" => "6" * 64,
      },
    }
    if remote == "passed"
      receipts["remoteElgato"] = {
        "issuer" => "golden-gate-elgato",
        "sourceRevision" => revision,
        "artifactSHA256" => dmg_hash,
        "receiptSHA256" => "7" * 64,
      }
    end
    input["externalReceipts"] = receipts
    input
  end

  def performance_metric
    {
      "baseline" => 100.0,
      "candidate" => 105.0,
      "regressionPercent" => 5.0,
      "status" => "passed",
      "approvedJustification" => nil,
    }
  end

  def required_gates
    %w[
      localQA securityScan sanitizer routeLifecycleStress socketStress
      activeSoak idleSoak updater renderedUI pluginTypecheck pluginUnitTests
      pluginValidation pluginPackage pluginLiveSocket packageVerification
    ]
  end

  def load_metadata
    with_metadata { |path| return WavesRelease::Metadata.load(path) }
  end

  def assert_release_error(pattern = nil)
    error = assert_raises(WavesRelease::Error) { yield }
    assert_match(pattern, error.message) if pattern
    error
  end

  def test_metadata_accepts_only_the_canonical_schema
    with_metadata do |path|
      metadata = WavesRelease::Metadata.load(path)
      assert_equal VERSION, metadata.fetch("version")
      assert_equal BUILD, metadata.fetch("build")
      assert_equal FLOOR, metadata.fetch("minimumMacOSVersion")
    end
  end

  def test_tracked_metadata_names_the_current_release_target
    metadata = WavesRelease::Metadata.load(File.expand_path("../../release/metadata.json", __dir__))
    assert_equal VERSION, metadata.fetch("version")
    assert_equal BUILD, metadata.fetch("build")
    assert_equal FLOOR, metadata.fetch("minimumMacOSVersion")
  end

  def test_tracked_metadata_pins_the_waves_release_identity
    metadata = WavesRelease::Metadata.load(File.expand_path("../../release/metadata.json", __dir__))

    assert_equal BUNDLE_IDENTIFIER, metadata["bundleIdentifier"]
    assert_equal DEVELOPER_IDENTITY, metadata.dig("developerID", "identity")
    assert_equal TEAM_IDENTIFIER, metadata.dig("developerID", "teamIdentifier")
    assert_equal DESIGNATED_REQUIREMENT, metadata.dig("developerID", "designatedRequirement")
  end

  def test_metadata_reader_accepts_a_future_canonical_release_without_code_changes
    future = metadata_hash.merge("version" => "1.7.1", "build" => 16)
    with_metadata(future) do |path|
      assert_equal future, WavesRelease::Metadata.load(path)
    end
  end

  def test_metadata_rejects_absent_malformed_duplicate_unknown_and_drifted_values
    assert_release_error(/not found/) { WavesRelease::Metadata.load("/missing/waves-release.json") }

    [
      ["{", /malformed JSON/],
      ['{"schemaVersion":1,"version":"1.6.0","version":"1.6.1","build":14,"minimumMacOSVersion":"14.2"}', /duplicate key/],
      [metadata_hash.merge("extra" => true), /unknown key/],
      [metadata_hash.merge("version" => "01.6.0"), /version/],
      [metadata_hash.merge("build" => "14"), /integer/],
      [metadata_hash.merge("build" => 0), /positive integer/],
      [metadata_hash.merge("minimumMacOSVersion" => "014.2"), /minimum macOS/],
      [metadata_hash.merge("minimumMacOSVersion" => "14.2.0"), /minimum macOS/],
    ].each do |contents, message|
      with_metadata(contents) { |path| assert_release_error(message) { WavesRelease::Metadata.load(path) } }
    end
  end

  def test_candidate_seal_allows_only_remote_elgato_pending_and_derives_ineligibility
    manifest = WavesRelease::Evidence.seal(
      input: evidence_input.merge("publicationEligible" => true),
      metadata: load_metadata,
      profile: "candidate"
    )

    refute manifest.fetch("publicationEligible")
    assert_equal "candidate", manifest.fetch("sealProfile")
    WavesRelease::Evidence.validate!(manifest, metadata: load_metadata, profile: "candidate", expected_revision: REVISION)
  end

  def test_evidence_rejects_missing_failed_skipped_wrong_revision_and_pending_publication
    missing = evidence_input
    missing.fetch("gates").delete("securityScan")
    assert_release_error(/securityScan/) do
      WavesRelease::Evidence.seal(input: missing, metadata: load_metadata, profile: "candidate")
    end

    failed = evidence_input
    failed.fetch("gates").fetch("idleSoak")["status"] = "failed"
    assert_release_error(/idleSoak/) do
      WavesRelease::Evidence.seal(input: failed, metadata: load_metadata, profile: "candidate")
    end

    skipped = evidence_input
    skipped["skippedGates"] = ["socketStress"]
    assert_release_error(/skipped/) do
      WavesRelease::Evidence.seal(input: skipped, metadata: load_metadata, profile: "candidate")
    end

    manifest = WavesRelease::Evidence.seal(input: evidence_input, metadata: load_metadata, profile: "candidate")
    assert_release_error(/revision/) do
      WavesRelease::Evidence.validate!(manifest, metadata: load_metadata, profile: "candidate", expected_revision: "b" * 40)
    end
    assert_release_error(/remoteElgato/) do
      WavesRelease::Evidence.seal(input: evidence_input, metadata: load_metadata, profile: "publication")
    end
  end

  def test_evidence_requires_an_accepted_notarization_submission_identity
    input = evidence_input
    input.fetch("package").fetch("notarization").delete("submissionID")
    assert_release_error(/submissionID/) do
      WavesRelease::Evidence.seal(input: input, metadata: load_metadata, profile: "candidate")
    end
  end

  def test_evidence_rejects_unbound_source_recipe_and_a_different_developer_id
    missing_source_recipe = evidence_input
    missing_source_recipe.fetch("source").delete("sourceArchiveSHA256")
    assert_release_error(/sourceArchiveSHA256/) do
      WavesRelease::Evidence.seal(
        input: missing_source_recipe,
        metadata: load_metadata,
        profile: "candidate"
      )
    end

    wrong_signer = evidence_input
    wrong_signer.fetch("package").fetch("developerID")["identity"] =
      "Developer ID Application: Attacker (EVILTEAM01)"
    assert_release_error(/Developer ID identity/) do
      WavesRelease::Evidence.seal(
        input: wrong_signer,
        metadata: load_metadata,
        profile: "candidate"
      )
    end
  end

  def test_task12d_evidence_binds_external_receipts_and_notary_log_to_source_and_dmg
    assert_respond_to WavesRelease::Evidence, :validate_external_receipts!
    return unless WavesRelease::Evidence.respond_to?(:validate_external_receipts!)

    metadata = security_metadata_hash
    input = security_evidence_input(remote: "passed")
    manifest = WavesRelease::Evidence.seal(input: input, metadata: metadata, profile: "publication")
    WavesRelease::Evidence.validate!(manifest, metadata: metadata, profile: "publication")

    {
      ["externalReceipts", "securityScan", "sourceRevision"] => "b" * 40,
      ["externalReceipts", "remoteElgato", "artifactSHA256"] => "9" * 64,
      ["externalReceipts", "securityScan", "receiptSHA256"] => "not-a-digest",
      ["package", "notarization", "artifactSHA256"] => "9" * 64,
      ["package", "notarization", "logSHA256"] => "not-a-digest",
    }.each do |path, mutation|
      wrong = Marshal.load(Marshal.dump(manifest))
      path[0...-1].reduce(wrong) { |value, key| value.fetch(key) }[path.last] = mutation
      assert_release_error(/receipt|notarization/) do
        WavesRelease::Evidence.validate!(wrong, metadata: metadata, profile: "publication")
      end
    end
  end

  def test_tsan_gate_uses_the_macro_free_harness_instead_of_instrumenting_macro_plugins
    quality_gate = File.read(File.expand_path("../quality-gate.sh", __dir__))
    runner = File.read(File.expand_path("../run-tsan-harness.sh", __dir__))
    harness = File.expand_path("../tsan-harness/Package.swift", __dir__)
    tests = File.expand_path("../tsan-harness/Sources/WavesTSanHarness/main.swift", __dir__)

    assert_includes quality_gate, "run-tsan-harness.sh"
    assert_includes quality_gate, "script/tsan-harness"
    refute_match(/swift test --sanitize=thread --filter/, quality_gate)
    assert File.file?(harness), "expected checked-in TSan harness manifest"
    assert File.file?(tests), "expected checked-in TSan harness coverage"
    refute_includes File.read(harness), "swift-testing"
    assert_includes File.read(tests), "@testable import Waves"
    assert_includes runner, 'ditto "$RESOLVED_FILE" "$HARNESS_ROOT/Package.resolved"'
    assert_includes runner, "--disable-automatic-resolution"
    source_files = Dir.glob(File.expand_path("../../Sources/**/*.swift", __dir__))
    refute source_files.any? { |path| File.read(path).include?("WAVES_TSAN_HARNESS") }
  end

  def test_tsan_runner_fails_before_building_when_the_tracked_lockfile_is_missing
    Dir.mktmpdir("waves-tsan-runner") do |root|
      FileUtils.mkdir_p(File.join(root, "script"))
      runner = File.expand_path("../run-tsan-harness.sh", __dir__)
      copied_runner = File.join(root, "script", "run-tsan-harness.sh")
      FileUtils.cp(runner, copied_runner)

      _stdout, stderr, status = Open3.capture3(copied_runner)
      refute status.success?
      assert_match(/tracked Package\.resolved is required/, stderr)
    end
  end

  def test_tsan_socket_fixture_uses_an_atomic_short_private_directory
    harness = File.read(
      File.expand_path("../tsan-harness/Sources/WavesTSanHarness/main.swift", __dir__)
    )

    assert_includes harness, '"/private/tmp/\(prefix).XXXXXX"'
    assert_includes harness, "Darwin.mkdtemp"
    refute_includes harness, "NSTemporaryDirectory()"
    assert_operator "/private/tmp/waves-tsan-control.XXXXXX/control.sock".bytesize, :<, 104
  end

  def test_quality_gate_isolates_rendered_ui_from_timing_sensitive_tests
    quality_gate = File.read(File.expand_path("../quality-gate.sh", __dir__))

    assert_includes quality_gate, "swift test --skip RenderedUISmokeTests"
    assert_includes quality_gate, "CI=1"
    assert_includes quality_gate, 'WAVES_QA_OUTPUT="$QUALITY_HOME/rendered-ui"'
    assert_includes quality_gate, "swift test --filter RenderedUISmokeTests"
  end

  def test_packager_uses_the_stable_macos_system_bash
    packager = File.expand_path("../build_and_run.sh", __dir__)
    assert_equal "#!/bin/bash -p", File.foreach(packager).first.chomp
  end

  def test_task12d_release_entrypoints_suppress_bash_env_before_the_first_command
    with_startup_attack_fixture do |directory, marker, bash_hook, _ruby_hook|
      entrypoints = [
        ["release-gate.sh", "not-a-phase"],
        ["build_and_run.sh", "not-a-mode"],
        ["make_appcast.sh"],
      ]

      entrypoints.each do |entrypoint, *arguments|
        FileUtils.rm_f(marker)
        _stdout, _stderr, status = Open3.capture3(
          {
            "BASH_ENV" => bash_hook,
            "WAVES_ATTACK_MARKER" => marker,
          },
          File.expand_path("../#{entrypoint}", __dir__),
          *arguments
        )

        refute status.success?, "#{entrypoint} attack fixture must stop on normal argument validation"
        refute File.exist?(marker), "#{entrypoint} must suppress BASH_ENV before its first command"
      end
    end
  end

  def test_task12d_release_entrypoints_clear_ruby_startup_injection_before_system_ruby
    with_startup_attack_fixture do |directory, marker, _bash_hook, ruby_hook|
      entrypoints = [
        ["release-gate.sh", "preflight"],
        ["build_and_run.sh", "not-a-mode"],
        ["make_appcast.sh", VERSION],
      ]

      entrypoints.each do |entrypoint, *arguments|
        FileUtils.rm_f(marker)
        _stdout, _stderr, _status = Open3.capture3(
          {
            "RUBYOPT" => "-rwaves_startup_attack",
            "RUBYLIB" => directory,
            "WAVES_ATTACK_MARKER" => marker,
          },
          File.expand_path("../#{entrypoint}", __dir__),
          *arguments
        )

        refute File.exist?(marker), "#{entrypoint} must clear RUBYOPT and RUBYLIB before system Ruby"
      end
    end
  end

  def test_task12d_evidence_authoring_entrypoints_suppress_bash_env_before_the_first_command
    with_startup_attack_fixture do |_directory, marker, bash_hook, _ruby_hook|
      failures = evidence_authoring_entrypoints.each_with_object([]) do |(entrypoint, _arguments), result|
        unless File.executable?(entrypoint)
          result << "missing protected entrypoint #{File.basename(entrypoint)}"
          next
        end

        FileUtils.rm_f(marker)
        _stdout, _stderr, status = Open3.capture3(
          {
            "BASH_ENV" => bash_hook,
            "WAVES_ATTACK_MARKER" => marker,
          },
          entrypoint
        )
        result << "#{File.basename(entrypoint)} accepted invalid arguments" if status.success?
        result << "#{File.basename(entrypoint)} executed BASH_ENV" if File.exist?(marker)
      end

      assert_empty failures, failures.join(", ")
    end
  end

  def test_task12d_evidence_authoring_entrypoints_clear_ruby_startup_injection
    with_startup_attack_fixture do |directory, marker, _bash_hook, ruby_hook|
      failures = evidence_authoring_entrypoints(directory).each_with_object([]) do |(entrypoint, arguments), result|
        unless File.executable?(entrypoint)
          result << "missing protected entrypoint #{File.basename(entrypoint)}"
          next
        end

        FileUtils.rm_f(marker)
        _stdout, _stderr, _status = Open3.capture3(
          {
            "RUBYOPT" => "-rwaves_startup_attack",
            "RUBYLIB" => directory,
            "WAVES_ATTACK_MARKER" => marker,
          },
          entrypoint,
          *arguments
        )
        result << "#{File.basename(entrypoint)} executed RUBYOPT/RUBYLIB" if File.exist?(marker)
      end

      assert_empty failures, failures.join(", ")
    end
  end

  def test_task12d_evidence_authoring_entrypoints_do_not_select_bash_or_ruby_from_caller_path
    Dir.mktmpdir("waves-authoring-path") do |directory|
      marker = File.join(directory, "path-command-ran")
      %w[bash ruby].each do |name|
        write_executable(File.join(directory, name), <<~SHELL)
          #!/bin/sh
          printf '#{name} ran\n' >> #{Shellwords.escape(marker)}
          exit 93
        SHELL
      end
      failures = evidence_authoring_entrypoints(directory).each_with_object([]) do |(entrypoint, arguments), result|
        unless File.executable?(entrypoint)
          result << "missing protected entrypoint #{File.basename(entrypoint)}"
          next
        end

        FileUtils.rm_f(marker)
        _stdout, _stderr, _status = Open3.capture3(
          {"PATH" => "#{directory}:/usr/bin:/bin"},
          entrypoint,
          *arguments
        )
        result << "#{File.basename(entrypoint)} selected a caller PATH command" if File.exist?(marker)
      end

      assert_empty failures, failures.join(", ")
    end
  end

  def test_task12d_protected_evidence_authoring_round_trips_seal_and_tag_envelope
    Dir.mktmpdir("waves-authoring-round-trip") do |directory|
      input = File.join(directory, "input.json")
      manifest = File.join(directory, "manifest.json")
      envelope = File.join(directory, "tag-envelope.txt")
      write_json(input, evidence_input)

      seal = File.expand_path("../generate-release-evidence.sh", __dir__)
      tag_envelope = File.expand_path("../generate-release-tag-envelope.sh", __dir__)
      assert File.executable?(seal), "expected protected evidence-sealing entrypoint"
      assert File.executable?(tag_envelope), "expected protected tag-envelope entrypoint"
      [seal, tag_envelope].each do |entrypoint|
        source = File.read(entrypoint)
        assert_equal "#!/bin/bash -p", source.lines.first.chomp
        assert_includes source, 'source "$WAVES_RELEASE_ENVIRONMENT_HELPER"'
        assert_includes source, "waves_release_environment_bootstrap"
        assert_includes source, "/usr/bin/ruby --disable-gems"
      end
      _stdout, stderr, status = Open3.capture3(seal, "candidate", input, manifest)
      assert status.success?, stderr
      _stdout, stderr, status = Open3.capture3(tag_envelope, manifest, envelope)
      assert status.success?, stderr

      parsed = WavesRelease::TagEnvelope.parse(File.read(envelope))
      assert_equal "candidate", parsed.fetch("manifest").fetch("sealProfile")
      assert_equal Digest::SHA256.hexdigest(File.read(manifest)), parsed.fetch("digest")
    end
  end

  def test_task12d_release_bootstrap_clears_adjacent_authority_and_restores_only_validated_inputs
    helper = File.expand_path("../release_environment.sh", __dir__)
    assert File.file?(helper), "expected the shared release environment bootstrap"
    return unless File.file?(helper)

    Dir.mktmpdir("waves-release-environment") do |directory|
      probe = File.join(directory, "probe.sh")
      marker = File.join(directory, "git-config-ran")
      expected_revision = "b" * 40
      expected_digest = "c" * 64
      signing_identity = DEVELOPER_IDENTITY
      sip_stdout, sip_stderr, sip_status = Open3.capture3("/usr/bin/csrutil", "status")
      sip_enabled = sip_status.success? && sip_stdout.include?("System Integrity Protection status: enabled.")
      File.write(probe, <<~SHELL)
        #!/bin/bash -p
        source #{Shellwords.escape(helper)}
        waves_release_environment_bootstrap \
          SIGN_IDENTITY NOTARY_PROFILE WAVES_EXPECTED_REVISION WAVES_RELEASE_EVIDENCE \
          WAVES_RELEASE_TAG EXPECTED_SHA256 SMOKE_SECONDS SMOKE_LOG_PATH
        /usr/bin/env
        /usr/bin/stat -f 'WAVES_HOME_STAT=%u:%Lp:%HT' "$HOME"
        /usr/bin/stat -f 'WAVES_TMP_STAT=%u:%Lp:%HT' "$TMPDIR"
      SHELL
      FileUtils.chmod(0o700, probe)

      poisoned = {
        "SIGN_IDENTITY" => signing_identity,
        "NOTARY_PROFILE" => "waves-notary",
        "WAVES_EXPECTED_REVISION" => expected_revision,
        "WAVES_RELEASE_EVIDENCE" => "dist/release-evidence.candidate.json",
        "WAVES_RELEASE_TAG" => RELEASE_TAG,
        "EXPECTED_SHA256" => expected_digest,
        "SMOKE_SECONDS" => "5",
        "SMOKE_LOG_PATH" => File.join(directory, "package-smoke.log"),
        "HOME" => File.join(directory, "attacker-home"),
        "TMPDIR" => File.join(directory, "attacker-tmp"),
        "BASH_ENV" => File.join(directory, "missing-bash-env"),
        "ENV" => File.join(directory, "missing-posix-env"),
        "RUBYOPT" => "-rbundler/setup",
        "RUBYLIB" => directory,
        "GEM_HOME" => directory,
        "GEM_PATH" => directory,
        "BUNDLE_GEMFILE" => File.join(directory, "Gemfile"),
        "RUBYGEMS_GEMDEPS" => "-",
        "GIT_DIR" => File.join(directory, "redirected-git-dir"),
        "GIT_WORK_TREE" => directory,
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "core.fsmonitor",
        "GIT_CONFIG_VALUE_0" => marker,
        "GIT_ASKPASS" => marker,
        "SSH_ASKPASS" => marker,
      }
      if sip_enabled
        poisoned.merge!(
          "DYLD_INSERT_LIBRARIES" => File.join(directory, "attack.dylib"),
          "DYLD_LIBRARY_PATH" => directory,
          "LD_PRELOAD" => File.join(directory, "attack.so")
        )
      else
        assert_match(/System Integrity Protection status: (?:disabled|unknown)/, sip_stdout + sip_stderr)
      end
      stdout, stderr, status = Open3.capture3(poisoned, probe)

      assert status.success?, stderr
      environment = stdout.lines(chomp: true).to_h { |line| line.split("=", 2) }
      assert_equal signing_identity, environment["SIGN_IDENTITY"]
      assert_equal "waves-notary", environment["NOTARY_PROFILE"]
      assert_equal expected_revision, environment["WAVES_EXPECTED_REVISION"]
      assert_equal "dist/release-evidence.candidate.json", environment["WAVES_RELEASE_EVIDENCE"]
      assert_equal RELEASE_TAG, environment["WAVES_RELEASE_TAG"]
      assert_equal expected_digest, environment["EXPECTED_SHA256"]
      assert_equal "5", environment["SMOKE_SECONDS"]
      assert_equal File.join(directory, "package-smoke.log"), environment["SMOKE_LOG_PATH"]
      poisoned.each_key do |name|
        next if %w[
          SIGN_IDENTITY NOTARY_PROFILE WAVES_EXPECTED_REVISION WAVES_RELEASE_EVIDENCE
          WAVES_RELEASE_TAG EXPECTED_SHA256 SMOKE_SECONDS SMOKE_LOG_PATH HOME TMPDIR
          GIT_ASKPASS SSH_ASKPASS
        ].include?(name)

        refute environment.key?(name), "release bootstrap retained #{name}"
      end
      assert_equal "/usr/bin:/bin:/usr/sbin:/sbin", environment["PATH"]
      assert_equal "/dev/null", environment["GIT_CONFIG_GLOBAL"]
      assert_equal "1", environment["GIT_CONFIG_NOSYSTEM"]
      assert_equal "0", environment["GIT_TERMINAL_PROMPT"]
      assert_equal "/usr/bin/false", environment["GIT_ASKPASS"]
      assert_equal "/usr/bin/false", environment["SSH_ASKPASS"]
      assert_equal "C.UTF-8", environment["LC_ALL"]
      assert_match(%r{\A/private/tmp/waves-release-environment\.[^/]+/home\z}, environment.fetch("HOME"))
      assert_match(%r{\A/private/tmp/waves-release-environment\.[^/]+/tmp\z}, environment.fetch("TMPDIR"))
      refute_equal poisoned.fetch("HOME"), environment.fetch("HOME")
      refute_equal poisoned.fetch("TMPDIR"), environment.fetch("TMPDIR")
      assert_equal "#{Process.uid}:700:Directory", environment["WAVES_HOME_STAT"]
      assert_equal "#{Process.uid}:700:Directory", environment["WAVES_TMP_STAT"]
    end
  end

  def test_task12d_release_bootstrap_rejects_invalid_documented_inputs
    helper = File.expand_path("../release_environment.sh", __dir__)
    assert File.file?(helper), "expected the shared release environment bootstrap"
    return unless File.file?(helper)

    Dir.mktmpdir("waves-release-environment") do |directory|
      probe = File.join(directory, "probe.sh")
      File.write(probe, <<~SHELL)
        #!/bin/bash -p
        source #{Shellwords.escape(helper)}
        waves_release_environment_bootstrap WAVES_EXPECTED_REVISION NOTARY_PROFILE
      SHELL
      FileUtils.chmod(0o700, probe)

      _stdout, stderr, status = Open3.capture3(
        {
          "WAVES_EXPECTED_REVISION" => "main",
          "NOTARY_PROFILE" => "profile\ncommand",
        },
        probe
      )

      refute status.success?
      assert_match(/WAVES_EXPECTED_REVISION/, stderr)
    end
  end

  def test_task12d_release_entrypoints_validate_each_documented_input_they_restore
    cases = [
      ["release-gate.sh", ["not-a-phase"], {"WAVES_EXPECTED_REVISION" => "main"}, /WAVES_EXPECTED_REVISION/],
      ["release-gate.sh", ["not-a-phase"], {"WAVES_RELEASE_EVIDENCE" => "bad\npath"}, /WAVES_RELEASE_EVIDENCE/],
      ["release-gate.sh", ["not-a-phase"], {"WAVES_RELEASE_TAG" => "release"}, /WAVES_RELEASE_TAG/],
      ["build_and_run.sh", ["not-a-mode"], {"SIGN_IDENTITY" => "bad\nidentity"}, /SIGN_IDENTITY/],
      ["build_and_run.sh", ["not-a-mode"], {"NOTARY_PROFILE" => "bad/profile"}, /NOTARY_PROFILE/],
      ["build_and_run.sh", ["not-a-mode"], {"SMOKE_SECONDS" => "0"}, /SMOKE_SECONDS/],
      ["build_and_run.sh", ["not-a-mode"], {"SMOKE_LOG_PATH" => "relative.log"}, /SMOKE_LOG_PATH/],
      ["make_appcast.sh", [], {"EXPECTED_SHA256" => "bad"}, /EXPECTED_SHA256/],
      ["make_appcast.sh", [], {"WAVES_RELEASE_TAG" => "release"}, /WAVES_RELEASE_TAG/],
    ]

    cases.each do |entrypoint, arguments, environment, error|
      _stdout, stderr, status = Open3.capture3(
        environment,
        File.expand_path("../#{entrypoint}", __dir__),
        *arguments
      )

      refute status.success?
      assert_match error, stderr
    end
  end

  def test_task12d_tracked_callers_execute_release_entrypoints_directly
    root = File.expand_path("../..", __dir__)
    tracked = git(root, "ls-files", "-z").split("\0")
    offenders = tracked.each_with_object([]) do |relative, result|
      next if relative == "script/tests/release_infra_test.rb"

      path = File.join(root, relative)
      next unless File.file?(path)

      contents = File.binread(path)
      next unless contents.valid_encoding?
      interpreted = contents.match?(
        %r{(?:^|[[:space:]])(?:/bin/)?bash[[:space:]]+(?:\./)?script/(?:release-gate|build_and_run|make_appcast|generate-release-evidence|generate-release-tag-envelope|prepare-elgato-handoff)\.sh}
      )
      sourced = contents.match?(
        %r{(?:^|[[:space:]])(?:source|\.)[[:space:]]+(?:\./)?script/(?:release-gate|build_and_run|make_appcast|generate-release-evidence|generate-release-tag-envelope|prepare-elgato-handoff)\.sh}
      )
      bare_tag_envelope = contents.match?(
        %r{(?:^|[[:space:]])(?:/usr/bin/)?ruby(?:[[:space:]]+--disable-gems)?[[:space:]]+script/release_tool\.rb[[:space:]]+tag-envelope}
      )
      result << relative if interpreted || sourced || bare_tag_envelope
    end

    assert_empty offenders, "release entrypoint shebangs must be honored by every tracked caller: #{offenders.join(', ')}"
  end

  def test_task12d_release_preflight_disables_checkout_local_fsmonitor_program
    assert_release_preflight_disables_fsmonitor(:local)
  end

  def test_task12d_release_preflight_disables_include_imported_fsmonitor_program
    assert_release_preflight_disables_fsmonitor(:included)
  end

  def test_task12d_build_dirty_check_disables_checkout_textconv_programs
    with_production_release_repo do |root, scratch|
      marker = File.join(scratch, "textconv-ran")
      textconv = write_executable(File.join(scratch, "textconv"), <<~SHELL)
        #!/bin/sh
        printf 'textconv ran\n' >> #{Shellwords.escape(marker)}
        /bin/cat "$1"
      SHELL
      FileUtils.mkdir_p(File.join(root, ".git/info"))
      File.write(File.join(root, ".git/info/attributes"), "README.md diff=wavesattack\n")
      git(root, "config", "diff.wavesattack.textconv", textconv)
      File.open(File.join(root, "README.md"), "a") { |file| file << "dirty source\n" }

      _stdout, stderr, status = Open3.capture3(
        File.join(root, "script/build_and_run.sh"),
        "--release-check",
        chdir: root
      )

      refute status.success?, "dirty source fixture must fail the release check"
      assert_match(/clean tracked tree/, stderr)
      refute File.exist?(marker), "diff textconv must not execute during the release source-dirty check"
    end
  end

  def test_task12d_build_dirty_check_disables_checkout_external_diff_programs
    with_production_release_repo do |root, scratch|
      marker = File.join(scratch, "external-diff-ran")
      external_diff = write_executable(File.join(scratch, "external-diff"), <<~SHELL)
        #!/bin/sh
        printf 'external diff ran\n' >> #{Shellwords.escape(marker)}
        exit 1
      SHELL
      git(root, "config", "diff.external", external_diff)
      git(root, "config", "diff.trustExitCode", "true")
      File.open(File.join(root, "README.md"), "a") { |file| file << "dirty source\n" }

      _stdout, stderr, status = Open3.capture3(
        File.join(root, "script/build_and_run.sh"),
        "--release-check",
        chdir: root
      )

      refute status.success?, "dirty source fixture must fail the release check"
      assert_match(/clean tracked tree/, stderr)
      refute File.exist?(marker), "external diff must not execute during the release source-dirty check"
    end
  end

  def test_task12d_tag_authority_pins_system_ssh_keygen_over_checkout_git_config
    with_production_release_repo do |root, scratch|
      with_ephemeral_ssh_keypair("waves-git-policy-tag") do |private_key, _public_key|
        marker = File.join(scratch, "gpg-ssh-program-ran")
        malicious_program = write_executable(File.join(scratch, "gpg-ssh-program"), <<~SHELL)
          #!/bin/sh
          printf 'gpg.ssh.program ran\n' >> #{Shellwords.escape(marker)}
          exit 1
        SHELL
        unless git(root, "tag", "--list", RELEASE_TAG).strip.empty?
          git(root, "tag", "-d", RELEASE_TAG)
        end
        create_signed_tag(root, RELEASE_TAG, "fixture release evidence\n", private_key)
        git(root, "config", "gpg.ssh.program", malicious_program)

        _stdout, stderr, status = Open3.capture3(
          {"WAVES_RELEASE_TAG" => RELEASE_TAG},
          File.join(root, "script/release-gate.sh"),
          "publication",
          chdir: root
        )

        refute status.success?, "fixture tag must fail against the pinned release authority"
        assert_match(/pinned release key/, stderr)
        refute File.exist?(marker), "checkout-local gpg.ssh.program must not execute during tag verification"
      end
    end
  end

  def test_task12d_release_git_calls_use_only_the_repository_policy_launcher
    launcher = File.read(File.expand_path("../release_git", __dir__))
    assert_equal "#!/bin/bash -p", launcher.lines.first.chomp
    assert_includes launcher, "exec /usr/bin/git"
    assert_includes launcher, "-c core.fsmonitor=false"
    assert_includes launcher, "-c gpg.ssh.program=/usr/bin/ssh-keygen"

    release_tool = File.read(File.expand_path("../release_tool.rb", __dir__))
    refute_match(
      /Validation\.run\(\s*(?:"git"|"\/usr\/bin\/git")/m,
      release_tool,
      "Ruby release Git calls must use the canonical GitPolicy launcher"
    )

    %w[release-gate.sh build_and_run.sh make_appcast.sh].each do |entrypoint|
      source = File.read(File.expand_path("../#{entrypoint}", __dir__))
      raw_calls = source.lines.grep(/(?:\$\(|!\s+|^\s*)git(?:\s+-C|\s+rev-|\s+describe)/)
      assert_empty raw_calls, "#{entrypoint} contains raw Git execution: #{raw_calls.join.strip}"
    end

    workflow = File.read(File.expand_path("../../.github/workflows/release.yml", __dir__))
    refute_includes workflow, 'test "$(git rev-parse HEAD)" = "$REQUESTED_REVISION"'
    assert_includes workflow, 'test "$(./script/release_git rev-parse HEAD)" = "$REQUESTED_REVISION"'
  end

  def test_publication_seal_requires_all_results_and_derives_eligibility
    manifest = WavesRelease::Evidence.seal(
      input: evidence_input(remote: "passed"),
      metadata: load_metadata,
      profile: "publication"
    )

    assert manifest.fetch("publicationEligible")
    WavesRelease::Evidence.validate!(manifest, metadata: load_metadata, profile: "publication", expected_revision: REVISION)
  end

  def test_canonical_evidence_sidecar_detects_tampering
    Dir.mktmpdir("waves-evidence") do |directory|
      output = File.join(directory, "evidence.json")
      digest_path = "#{output}.sha256"
      WavesRelease::Evidence.write!(
        input: evidence_input,
        metadata: load_metadata,
        profile: "candidate",
        output: output
      )
      WavesRelease::Evidence.verify_file!(
        path: output,
        digest_path: digest_path,
        metadata: load_metadata,
        profile: "candidate",
        expected_revision: REVISION
      )

      File.write(output, File.read(output).sub("482", "481"))
      assert_release_error(/SHA-256/) do
        WavesRelease::Evidence.verify_file!(
          path: output,
          digest_path: digest_path,
          metadata: load_metadata,
          profile: "candidate",
          expected_revision: REVISION
        )
      end
    end
  end

  def test_tag_envelope_round_trips_and_rejects_tampering
    manifest = WavesRelease::Evidence.seal(
      input: evidence_input(remote: "passed"),
      metadata: load_metadata,
      profile: "publication"
    )
    json = WavesRelease::CanonicalJSON.generate(manifest)
    digest = WavesRelease::CanonicalJSON.sha256(json)
    envelope = WavesRelease::TagEnvelope.build(json: json, digest: digest)
    parsed = WavesRelease::TagEnvelope.parse(envelope)
    assert_equal manifest, parsed.fetch("manifest")

    assert_release_error(/SHA-256/) do
      WavesRelease::TagEnvelope.parse(envelope.sub("482", "481"))
    end
  end

  def test_artifact_hash_contract_rejects_bytes_that_do_not_match_the_manifest
    Dir.mktmpdir("waves-artifact-hashes") do |root|
      app = File.join(root, "Waves")
      dmg = File.join(root, "Waves.dmg")
      dsym = File.join(root, "Waves.dSYM")
      File.write(app, "app bytes")
      File.write(dmg, "dmg bytes")
      File.write(dsym, "dsym bytes")
      manifest = WavesRelease::Evidence.seal(
        input: evidence_input(remote: "passed"),
        metadata: load_metadata,
        profile: "publication"
      )
      manifest.fetch("package")["hashes"] = {
        "appExecutable" => Digest::SHA256.file(app).hexdigest,
        "dmg" => Digest::SHA256.file(dmg).hexdigest,
        "dSYM" => Digest::SHA256.file(dsym).hexdigest,
      }

      WavesRelease::ArtifactEvidence.verify_hashes!(
        manifest: manifest,
        paths: {"appExecutable" => app, "dmg" => dmg, "dSYM" => dsym}
      )
      File.write(dmg, "tampered dmg bytes")
      assert_release_error(/dmg SHA-256/) do
        WavesRelease::ArtifactEvidence.verify_hashes!(
          manifest: manifest,
          paths: {"appExecutable" => app, "dmg" => dmg, "dSYM" => dsym}
        )
      end
    end
  end

  def test_elgato_handoff_prepares_an_exact_candidate_bound_test_kit
    handoff = WavesRelease.const_defined?(:ElgatoHandoff) ? WavesRelease::ElgatoHandoff : nil
    refute_nil handoff, "expected deterministic Elgato handoff assembly"
    return unless handoff

    Dir.mktmpdir("waves-elgato-handoff") do |root|
      dmg = File.join(root, "Waves.dmg")
      plugin = File.join(root, "com.jonathanreed.waves.streamDeckPlugin")
      manifest = File.join(root, "release-evidence.candidate.json")
      output = File.join(root, HANDOFF_NAME)
      File.write(dmg, "signed candidate dmg bytes\n")
      File.write(plugin, "stream deck package bytes\n")

      input = evidence_input
      dmg_hash = Digest::SHA256.file(dmg).hexdigest
      input.fetch("package").fetch("hashes")["dmg"] = dmg_hash
      input.fetch("package").fetch("notarization")["artifactSHA256"] = dmg_hash
      input.fetch("externalReceipts").fetch("securityScan")["artifactSHA256"] = dmg_hash
      WavesRelease::Evidence.write!(
        input: input,
        metadata: load_metadata,
        profile: "candidate",
        output: manifest
      )

      wrong_dmg = File.join(root, "wrong-Waves.dmg")
      rejected_output = File.join(root, "Rejected-Elgato-Handoff")
      File.write(wrong_dmg, "different candidate bytes\n")
      assert_release_error(/DMG.*sealed candidate evidence/) do
        handoff.prepare!(
          manifest_path: manifest,
          metadata: load_metadata,
          dmg_path: wrong_dmg,
          plugin_path: plugin,
          plugin_revision: "b" * 40,
          templates_root: File.expand_path("../../release/elgato-handoff", __dir__),
          output_root: rejected_output
        )
      end
      refute File.exist?(rejected_output)

      handoff.prepare!(
        manifest_path: manifest,
        metadata: load_metadata,
        dmg_path: dmg,
        plugin_path: plugin,
        plugin_revision: "b" * 40,
        templates_root: File.expand_path("../../release/elgato-handoff", __dir__),
        output_root: output
      )

      expected_files = %W[
        README.md
        ROLLBACK.md
        SHA256SUMS
        TEST-CHECKLIST.md
        #{HANDOFF_DMG_NAME}
        collect-diagnostics.sh
        com.jonathanreed.waves.streamDeckPlugin
        finalize-receipt.rb
        handoff.json
        release-evidence.candidate.json
        release-evidence.candidate.json.sha256
        results.json
      ]
      assert_equal expected_files, Dir.children(output).sort

      handoff_manifest = WavesRelease::StrictJSON.load(File.join(output, "handoff.json"))
      assert_equal 1, handoff_manifest.fetch("schemaVersion")
      assert_equal REVISION, handoff_manifest.fetch("sourceRevision")
      assert_equal VERSION, handoff_manifest.fetch("version")
      assert_equal BUILD, handoff_manifest.fetch("build")
      assert_equal dmg_hash, handoff_manifest.dig("artifacts", "dmg", "sha256")
      assert_equal "b" * 40, handoff_manifest.dig("artifacts", "streamDeckPlugin", "sourceRevision")
      assert_equal Digest::SHA256.file(plugin).hexdigest,
        handoff_manifest.dig("artifacts", "streamDeckPlugin", "sha256")
      assert_equal Digest::SHA256.file(manifest).hexdigest,
        handoff_manifest.fetch("candidateEvidenceSHA256")

      checklist = File.read(File.join(output, "TEST-CHECKLIST.md"))
      %w[
        launch-orders
        routing-ownership
        single-audible-path
        arbitration-cycles
        device-and-relaunch
        stream-deck-controls
      ].each { |test_id| assert_includes checklist, test_id }
      assert_includes File.read(File.join(output, "ROLLBACK.md")),
        "5887c0c46b824d610016dbfe7e34a1c1e2da2c4bc270555c15221ca5b694face"
      instructions = File.read(File.join(output, "README.md"))
      assert_includes instructions, "results.json"
      assert_includes instructions, "finalize-receipt.rb"
      assert_includes instructions, "remote-elgato-receipt.json"
      assert_includes instructions, "b" * 40
      assert_includes instructions, Digest::SHA256.file(plugin).hexdigest
      assert_includes instructions, '"$PWD/results.json" \\' + "\n"
      collector = File.read(File.join(output, "collect-diagnostics.sh"))
      assert_equal "#!/bin/bash -p", collector.lines.first.chomp
      assert_includes collector, "/usr/sbin/system_profiler"
      assert_includes collector, 'fetch("artifacts").fetch("dmg").fetch("name")'
      refute_includes collector, "Waves-1.5.0-13.dmg"
      refute_match(/defaults write|tccutil|killall|rm -rf/, collector)

      handoff.verify!(root: output, metadata: load_metadata)
    end
  end

  def test_elgato_handoff_finalizer_requires_every_result_and_binds_returned_diagnostics
    handoff = WavesRelease.const_defined?(:ElgatoHandoff) ? WavesRelease::ElgatoHandoff : nil
    refute_nil handoff, "expected deterministic Elgato handoff assembly"
    return unless handoff

    Dir.mktmpdir("waves-elgato-receipt") do |root|
      dmg = File.join(root, "Waves.dmg")
      plugin = File.join(root, "com.jonathanreed.waves.streamDeckPlugin")
      manifest = File.join(root, "release-evidence.candidate.json")
      output = File.join(root, HANDOFF_NAME)
      diagnostics = File.join(root, "diagnostics")
      receipt = File.join(root, "remote-elgato-receipt.json")
      File.write(dmg, "signed candidate dmg bytes\n")
      File.write(plugin, "stream deck package bytes\n")
      input = evidence_input
      dmg_hash = Digest::SHA256.file(dmg).hexdigest
      input.fetch("package").fetch("hashes")["dmg"] = dmg_hash
      input.fetch("package").fetch("notarization")["artifactSHA256"] = dmg_hash
      input.fetch("externalReceipts").fetch("securityScan")["artifactSHA256"] = dmg_hash
      WavesRelease::Evidence.write!(
        input: input,
        metadata: load_metadata,
        profile: "candidate",
        output: manifest
      )
      handoff.prepare!(
        manifest_path: manifest,
        metadata: load_metadata,
        dmg_path: dmg,
        plugin_path: plugin,
        plugin_revision: "b" * 40,
        templates_root: File.expand_path("../../release/elgato-handoff", __dir__),
        output_root: output
      )

      finalizer = File.join(output, "finalize-receipt.rb")
      results_path = File.join(output, "results.json")
      assert File.executable?(finalizer), "expected a runnable receipt finalizer in the handoff"
      return unless File.executable?(finalizer)

      FileUtils.mkdir_p(diagnostics)
      %w[
        macos.txt
        kernel.txt
        audio-and-usb.txt
        relevant-processes.txt
        handoff-artifact-checksums.txt
        installed-waves-identity.txt
        waves-diagnostics.txt
        handoff.json
        TEST-CHECKLIST.md
      ].each do |name|
        if %w[handoff.json TEST-CHECKLIST.md].include?(name)
          FileUtils.cp(File.join(output, name), File.join(diagnostics, name))
        else
          File.write(File.join(diagnostics, name), "verified #{name}\n")
        end
      end

      _stdout, stderr, status = Open3.capture3(
        "/usr/bin/ruby",
        "--disable-gems",
        finalizer,
        output,
        results_path,
        diagnostics,
        receipt
      )
      refute status.success?
      assert_match(/must pass/i, stderr)
      refute File.exist?(receipt)

      results = JSON.parse(JSON.generate(WavesRelease::StrictJSON.load(results_path)))
      results.fetch("tests").each_value do |result|
        result["status"] = "passed"
        result["detail"] = "Passed on physical Wave Link and Stream Deck hardware."
      end
      write_json(results_path, results)

      unexpected_receipt = File.join(root, "unexpected-remote-elgato-receipt.json")
      File.write(File.join(diagnostics, "browser-cookies.txt"), "unrelated private data\n")
      _stdout, stderr, status = Open3.capture3(
        "/usr/bin/ruby",
        "--disable-gems",
        finalizer,
        output,
        results_path,
        diagnostics,
        unexpected_receipt
      )
      refute status.success?
      assert_match(/unexpected file/, stderr)
      refute File.exist?(unexpected_receipt)
      FileUtils.rm_f(File.join(diagnostics, "browser-cookies.txt"))

      oversized_receipt = File.join(root, "oversized-remote-elgato-receipt.json")
      File.binwrite(File.join(diagnostics, "waves-diagnostics.txt"), "x" * (10 * 1024 * 1024 + 1))
      _stdout, stderr, status = Open3.capture3(
        "/usr/bin/ruby",
        "--disable-gems",
        finalizer,
        output,
        results_path,
        diagnostics,
        oversized_receipt
      )
      refute status.success?
      assert_match(/size limit/, stderr)
      refute File.exist?(oversized_receipt)
      File.write(File.join(diagnostics, "waves-diagnostics.txt"), "verified waves-diagnostics.txt\n")

      tampered_receipt = File.join(root, "tampered-remote-elgato-receipt.json")
      File.open(File.join(diagnostics, "handoff.json"), "a") { |file| file << "tampered\n" }
      _stdout, stderr, status = Open3.capture3(
        "/usr/bin/ruby",
        "--disable-gems",
        finalizer,
        output,
        results_path,
        diagnostics,
        tampered_receipt
      )
      refute status.success?
      assert_match(/diagnostics handoff\.json does not match/, stderr)
      refute File.exist?(tampered_receipt)
      FileUtils.cp(File.join(output, "handoff.json"), File.join(diagnostics, "handoff.json"))

      _stdout, stderr, status = Open3.capture3(
        "/usr/bin/ruby",
        "--disable-gems",
        finalizer,
        output,
        results_path,
        diagnostics,
        receipt
      )
      assert status.success?, stderr
      returned = WavesRelease::StrictJSON.load(receipt)
      assert_equal "golden-gate-elgato", returned.fetch("issuer")
      assert_equal REVISION, returned.fetch("sourceRevision")
      assert_equal dmg_hash, returned.fetch("artifactSHA256")
      assert_equal "b" * 40, returned.fetch("pluginSourceRevision")
      assert_equal Digest::SHA256.file(plugin).hexdigest, returned.fetch("pluginSHA256")
      assert_match(/\A[0-9a-f]{64}\z/, returned.fetch("diagnosticsSHA256"))
      assert returned.fetch("tests").values.all? { |result| result.fetch("status") == "passed" }
      assert_equal Digest::SHA256.file(receipt).hexdigest,
        File.read("#{receipt}.sha256").split.first
    end
  end

  def test_elgato_handoff_entrypoint_requires_the_protected_candidate_gate_before_assembly
    entrypoint = File.expand_path("../prepare-elgato-handoff.sh", __dir__)
    assert File.executable?(entrypoint), "expected protected Elgato handoff entrypoint"
    return unless File.executable?(entrypoint)

    source = File.read(entrypoint)
    assert_equal "#!/bin/bash -p", source.lines.first.chomp
    assert_includes source, 'source "$WAVES_RELEASE_ENVIRONMENT_HELPER"'
    assert_includes source, "waves_release_environment_bootstrap"
    assert_includes source, "/usr/bin/ruby --disable-gems"
    candidate_gate = source.index('release-gate.sh" candidate')
    assembly = source.index("release_tool.rb\" elgato-handoff prepare")
    refute_nil candidate_gate, "handoff entrypoint must run the candidate gate"
    refute_nil assembly, "handoff entrypoint must call canonical assembly"
    assert_operator candidate_gate, :<, assembly
    refute_match(/publication|tag-envelope|notarytool submit|gh release/, source)

    Dir.mktmpdir("waves-elgato-entrypoint") do |directory|
      marker = File.join(directory, "bash-env-ran")
      hook = File.join(directory, "hook.sh")
      File.write(hook, "printf 'ran\\n' > #{Shellwords.escape(marker)}\n")
      _stdout, _stderr, status = Open3.capture3(
        {
          "BASH_ENV" => hook,
          "WAVES_ATTACK_MARKER" => marker,
        },
        entrypoint
      )
      refute status.success?
      refute File.exist?(marker), "handoff entrypoint must suppress BASH_ENV before its first command"
    end
  end

  def test_task12d_private_artifact_stage_rejects_symlinks_and_swaps_before_sensitive_action
    stage = WavesRelease.const_defined?(:PrivateArtifacts) ? WavesRelease::PrivateArtifacts : nil
    refute_nil stage, "private release artifact staging must be implemented"
    return unless stage

    Dir.mktmpdir("waves-private-artifacts") do |root|
      FileUtils.chmod(0o700, root)
      %w[Waves.app Waves.dmg Waves.dSYM appcast.xml].each do |name|
        path = File.join(root, name)
        if name.end_with?(".app", ".dSYM")
          FileUtils.mkdir_p(path)
        else
          File.write(path, "verified #{name}\n")
        end
        identity = stage.capture_identity!(path: path)
        replacement = File.join(root, "replacement-#{name}")
        File.rename(path, replacement)
        if File.directory?(replacement)
          FileUtils.mkdir_p(path)
        else
          File.write(path, "attacker bytes\n")
        end
        sensitive_action_ran = false
        assert_release_error(/identity changed/) do
          stage.with_stable_identity!(path: path, identity: identity) { sensitive_action_ran = true }
        end
        refute sensitive_action_ran, "#{name} must be rejected before the sensitive action"

        FileUtils.rm_rf(path)
        File.symlink(replacement, path)
        assert_release_error(/symbolic link/) { stage.capture_identity!(path: path) }
      end
    end
  end

  def test_task12d_private_artifact_stage_publishes_only_hash_identical_finalized_files
    stage = WavesRelease.const_defined?(:PrivateArtifacts) ? WavesRelease::PrivateArtifacts : nil
    refute_nil stage, "private release artifact staging must be implemented"
    return unless stage

    Dir.mktmpdir("waves-private-publish") do |root|
      private_root = File.join(root, "private")
      public_root = File.join(root, "dist")
      FileUtils.mkdir_p(private_root)
      FileUtils.chmod(0o700, private_root)
      FileUtils.mkdir_p(public_root)
      %w[Waves.dmg Waves.dSYM appcast.xml].each do |name|
        source = File.join(private_root, name)
        destination = File.join(public_root, name)
        File.write(source, "finalized #{name}\n")
        expected = Digest::SHA256.file(source).hexdigest
        stage.publish_file!(source: source, destination: destination)
        assert_equal expected, Digest::SHA256.file(destination).hexdigest

        FileUtils.rm_f(destination)
        File.symlink(File.join(root, "attacker"), destination)
        assert_release_error(/symbolic link/) do
          stage.publish_file!(source: source, destination: destination)
        end
      end
    end
  end

  def test_release_publication_regenerates_checksum_and_symbol_archive_from_finalized_artifacts
    stage = WavesRelease::PrivateArtifacts
    Dir.mktmpdir("waves-release-derivatives") do |root|
      source = File.join(root, "private")
      destination = File.join(root, "dist")
      symbol = File.join(source, "Waves.app.dSYM/Contents/Resources/DWARF/Waves")
      FileUtils.mkdir_p(File.join(source, "Waves.app"))
      FileUtils.mkdir_p(File.dirname(symbol))
      FileUtils.mkdir_p(destination)
      FileUtils.chmod(0o700, source)
      File.write(File.join(source, "Waves.app/Info.plist"), "current app\n")
      File.write(symbol, "current symbols\n")
      File.write(File.join(source, "Waves.dmg"), "current dmg\n")
      File.write(File.join(source, "release-source-identity.json"), "current source identity\n")
      File.write(File.join(source, "notary-log.json"), "current notary log\n")
      File.write(File.join(destination, "Waves.app.dSYM.zip"), "stale symbols\n")
      File.write(File.join(destination, "Waves.dmg.sha256"), "stale checksum\n")
      File.write(File.join(destination, "release-source-identity.json"), "stale source identity\n")
      File.write(File.join(destination, "notary-log.json"), "stale notary log\n")

      stage.publish_release_artifacts!(source_root: source, destination_root: destination)

      expected_dmg = Digest::SHA256.file(File.join(source, "Waves.dmg")).hexdigest
      assert_equal "#{expected_dmg}  Waves.dmg\n", File.read(File.join(destination, "Waves.dmg.sha256"))
      archived_symbols, archive_error, archive_status = Open3.capture3(
        "/usr/bin/unzip",
        "-p",
        File.join(destination, "Waves.app.dSYM.zip"),
        "Waves.app.dSYM/Contents/Resources/DWARF/Waves"
      )
      assert archive_status.success?, archive_error
      assert_equal "current symbols\n", archived_symbols
      assert_equal(
        "current source identity\n",
        File.read(File.join(destination, "release-source-identity.json"))
      )
      assert_equal(
        "current notary log\n",
        File.read(File.join(destination, "notary-log.json"))
      )
    end
  end

  def test_notarized_build_exports_exact_source_identity_and_apple_notary_log
    source = File.read(File.expand_path("../build_and_run.sh", __dir__))

    assert_includes source,
      '"$identity_path" "$WAVES_RELEASE_OUTPUT_DIR" release-source-identity.json'
    assert_includes source,
      'run_notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json'
    assert_includes source, 'run_notarytool log "$submission_id" "$notary_log_path"'
    assert_includes source,
      '"$notary_log_path" "$DIST_DIR" notary-log.json'
  end

  def test_task12d_existing_release_package_is_copied_into_one_private_root_before_validation
    stage = WavesRelease::PrivateArtifacts
    Dir.mktmpdir("waves-existing-package") do |root|
      source = File.join(root, "dist")
      private_root = File.join(root, "private")
      FileUtils.mkdir_p(File.join(source, "Waves.app"))
      FileUtils.mkdir_p(File.join(source, "Waves.app.dSYM"))
      File.write(File.join(source, "Waves.app/Info.plist"), "app")
      File.write(File.join(source, "Waves.app.dSYM/Waves"), "symbols")
      File.write(File.join(source, "Waves.dmg"), "dmg")
      FileUtils.mkdir_p(private_root)
      FileUtils.chmod(0o700, private_root)

      stage.stage_release_artifacts!(source_root: source, destination_root: private_root)
      File.write(File.join(source, "Waves.dmg"), "attacker")
      assert_equal "dmg", File.read(File.join(private_root, "Waves.dmg"))

      FileUtils.rm_rf(private_root)
      FileUtils.mkdir_p(private_root)
      FileUtils.chmod(0o700, private_root)
      FileUtils.rm_rf(File.join(source, "Waves.app"))
      File.symlink(File.join(root, "attacker.app"), File.join(source, "Waves.app"))
      assert_release_error(/symbolic link/) do
        stage.stage_release_artifacts!(source_root: source, destination_root: private_root)
      end
    end
  end

  def test_task12d_private_stage_normalizes_benign_root_spelling_without_permitting_escape
    Dir.mktmpdir("waves-private-root-normalization") do |root|
      source = File.join(root, "Waves.dmg")
      private_root = File.join(root, "private")
      File.write(source, "dmg")
      FileUtils.mkdir_p(private_root)
      FileUtils.chmod(0o700, private_root)

      staged = WavesRelease::PrivateArtifacts.stage_file!(
        source: source,
        root: "#{private_root}/.",
        name: "Waves.dmg"
      )
      assert_equal File.join(private_root, "Waves.dmg"), staged

      assert_release_error(/escapes/) do
        WavesRelease::PrivateArtifacts.stage_file!(
          source: source,
          root: private_root,
          name: "../escaped.dmg"
        )
      end
    end
  end

  def test_derived_artifact_identity_must_match_metadata_and_sealed_evidence
    verifier = WavesRelease::ArtifactEvidence
    assert_respond_to verifier, :verify_identity_facts!
    return unless verifier.respond_to?(:verify_identity_facts!)

    manifest = WavesRelease::Evidence.seal(
      input: evidence_input(remote: "passed"),
      metadata: load_metadata,
      profile: "publication"
    )
    facts = {
      "bundleIdentifier" => BUNDLE_IDENTIFIER,
      "version" => VERSION,
      "build" => BUILD,
      "minimumMacOSVersion" => FLOOR,
      "sourceRevision" => REVISION,
      "sourceArchiveSHA256" => "4" * 64,
      "buildRecipeSHA256" => "5" * 64,
      "developerID" => {
        "identity" => DEVELOPER_IDENTITY,
        "teamIdentifier" => TEAM_IDENTIFIER,
        "designatedRequirement" => DESIGNATED_REQUIREMENT,
      },
      "hardenedRuntime" => true,
      "notarizedDeveloperID" => true,
      "stapling" => true,
      "gatekeeper" => true,
    }

    verifier.verify_identity_facts!(manifest: manifest, metadata: load_metadata, facts: facts)

    wrong_team = Marshal.load(Marshal.dump(facts))
    wrong_team.fetch("developerID")["teamIdentifier"] = "EVILTEAM01"
    assert_release_error(/teamIdentifier/) do
      verifier.verify_identity_facts!(manifest: manifest, metadata: load_metadata, facts: wrong_team)
    end

    wrong_source = Marshal.load(Marshal.dump(facts))
    wrong_source["buildRecipeSHA256"] = "f" * 64
    assert_release_error(/build recipe/) do
      verifier.verify_identity_facts!(manifest: manifest, metadata: load_metadata, facts: wrong_source)
    end
  end

  def test_exact_tag_source_identity_must_match_sealed_evidence_and_artifact_stamps
    verifier = WavesRelease::ArtifactEvidence
    assert_respond_to verifier, :verify_exact_source_identity!
    return unless verifier.respond_to?(:verify_exact_source_identity!)

    manifest = WavesRelease::Evidence.seal(
      input: evidence_input(remote: "passed"),
      metadata: load_metadata,
      profile: "publication"
    )
    exact_identity = manifest.fetch("source").dup
    artifact_facts = {
      "sourceRevision" => REVISION,
      "sourceArchiveSHA256" => "4" * 64,
      "buildRecipeSHA256" => "5" * 64,
    }

    verifier.verify_exact_source_identity!(
      manifest: manifest,
      exact_identity: exact_identity,
      artifact_facts: artifact_facts
    )

    {
      "revision" => ["sourceRevision", "source revision", "b" * 40],
      "sourceArchiveSHA256" => ["sourceArchiveSHA256", "source archive", "6" * 64],
      "buildRecipeSHA256" => ["buildRecipeSHA256", "build recipe", "7" * 64],
    }.each do |source_field, (artifact_field, label, mutation)|
      wrong_evidence = Marshal.load(Marshal.dump(manifest))
      wrong_evidence.fetch("source")[source_field] = mutation
      assert_release_error(/#{label}.*sealed evidence/) do
        verifier.verify_exact_source_identity!(
          manifest: wrong_evidence,
          exact_identity: exact_identity,
          artifact_facts: artifact_facts
        )
      end

      wrong_artifact = artifact_facts.merge(artifact_field => mutation)
      assert_release_error(/#{label}.*artifact/) do
        verifier.verify_exact_source_identity!(
          manifest: manifest,
          exact_identity: exact_identity,
          artifact_facts: wrong_artifact
        )
      end
    end
  end

  def test_release_artifact_verifier_enforces_the_recomputed_exact_source_identity
    Dir.mktmpdir("waves-artifact-source-binding") do |root|
      app = File.join(root, "Waves.app")
      executable = File.join(app, "Contents/MacOS/Waves")
      info_plist = File.join(app, "Contents/Info.plist")
      dmg = File.join(root, "Waves.dmg")
      dsym = File.join(root, "Waves.dSYM")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "app bytes")
      File.write(info_plist, "plist bytes")
      File.write(dmg, "dmg bytes")
      File.write(dsym, "dsym bytes")

      manifest = WavesRelease::Evidence.seal(
        input: evidence_input(remote: "passed"),
        metadata: load_metadata,
        profile: "publication"
      )
      manifest.fetch("package")["hashes"] = {
        "appExecutable" => Digest::SHA256.file(executable).hexdigest,
        "dmg" => Digest::SHA256.file(dmg).hexdigest,
        "dSYM" => Digest::SHA256.file(dsym).hexdigest,
      }
      exact_identity = manifest.fetch("source").merge("sourceArchiveSHA256" => "9" * 64)
      plist_values = {
        "CFBundleIdentifier" => BUNDLE_IDENTIFIER,
        "CFBundleShortVersionString" => VERSION,
        "CFBundleVersion" => BUILD.to_s,
        "LSMinimumSystemVersion" => FLOOR,
        "WavesSourceRevision" => REVISION,
        "WavesSourceArchiveSHA256" => "4" * 64,
        "WavesBuildRecipeSHA256" => "5" * 64,
      }
      signing_details = lambda do |path, **_arguments|
        details = {
          "identity" => DEVELOPER_IDENTITY,
          "teamIdentifier" => TEAM_IDENTIFIER,
          "hardenedRuntime" => true,
        }
        details["designatedRequirement"] = DESIGNATED_REQUIREMENT if path == app
        details
      end
      command_result = lambda do |*arguments, **_options|
        File.basename(arguments.first) == "spctl" ? "source=Notarized Developer ID\n" : ""
      end

      WavesRelease::ArtifactEvidence.stub(:signing_details!, signing_details) do
        WavesRelease::ArtifactEvidence.stub(:plist_value!, ->(_path, key) { plist_values.fetch(key) }) do
          WavesRelease::Validation.stub(:run_combined, command_result) do
            assert_release_error(/source archive.*sealed evidence/) do
              WavesRelease::ArtifactEvidence.verify_release_artifacts!(
                manifest: manifest,
                metadata: load_metadata,
                app: app,
                dmg: dmg,
                dsym: dsym,
                exact_source_identity: exact_identity
              )
            end
          end
        end
      end
    end
  end

  def test_sparkle_signer_accepts_only_the_exact_tool_in_a_private_fresh_root
    resolver = WavesRelease.const_defined?(:SparkleSigningTool) ? WavesRelease::SparkleSigningTool : nil
    refute_nil resolver, "isolated Sparkle signing-tool validation must be implemented"
    return unless resolver

    Dir.mktmpdir("waves-sparkle-tool") do |root|
      FileUtils.chmod(0o700, root)
      expected = File.join(root, "artifacts/sparkle/Sparkle/bin/sign_update")
      FileUtils.mkdir_p(File.dirname(expected))
      File.write(expected, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o700, expected)

      assert_equal expected, resolver.verify!(scratch_root: root, candidate_path: expected)

      planted = File.join(root, "planted/sign_update")
      FileUtils.mkdir_p(File.dirname(planted))
      File.write(planted, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o700, planted)
      assert_release_error(/expected isolated Sparkle path/) do
        resolver.verify!(scratch_root: root, candidate_path: planted)
      end

      FileUtils.chmod(0o755, root)
      assert_release_error(/mode 0700/) do
        resolver.verify!(scratch_root: root, candidate_path: expected)
      end
    end
  end

  def test_task12d_sparkle_signing_binds_explicit_account_public_key_and_signature
    binding = WavesRelease.const_defined?(:SparkleKeyBinding) ? WavesRelease::SparkleKeyBinding : nil
    refute_nil binding, "Sparkle account and packaged-key binding must be implemented"
    return unless binding

    with_ephemeral_sparkle_tools do |scratch, artifact, public_key, signer_marker, tamper_marker|
      metadata = security_metadata_hash
      metadata.fetch("sparkle")["publicEDKey"] = public_key

      wrong_account = Marshal.load(Marshal.dump(metadata))
      wrong_account.fetch("sparkle")["keychainAccount"] = "wrong.account"
      assert_release_error(/account/) do
        binding.sign_and_verify!(
          scratch_root: scratch,
          artifact: artifact,
          metadata: wrong_account,
          packaged_public_key: public_key
        )
      end
      refute File.exist?(signer_marker), "wrong account must fail before signing"

      assert_release_error(/packaged public key/) do
        binding.sign_and_verify!(
          scratch_root: scratch,
          artifact: artifact,
          metadata: metadata,
          packaged_public_key: Base64.strict_encode64("wrong" * 8)
        )
      end
      refute File.exist?(signer_marker), "wrong packaged key must fail before signing"

      File.write(tamper_marker, "tamper\n")
      assert_release_error(/signature verification/) do
        binding.sign_and_verify!(
          scratch_root: scratch,
          artifact: artifact,
          metadata: metadata,
          packaged_public_key: public_key
        )
      end
      FileUtils.rm_f(tamper_marker)

      signature = binding.sign_and_verify!(
        scratch_root: scratch,
        artifact: artifact,
        metadata: metadata,
        packaged_public_key: public_key
      )
      assert_match(/\A[A-Za-z0-9+\/]+={0,2}\z/, signature)
    end
  end

  def test_repository_contract_rejects_default_drift_and_changelog_or_cask_mismatch
    Dir.mktmpdir("waves-contract") do |root|
      write_repository_contract_fixture(root)
      metadata = WavesRelease::Metadata.load(File.join(root, "release/metadata.json"))
      WavesRelease::RepositoryContract.validate!(root: root, metadata: metadata)

      File.write(File.join(root, "script/build_and_run.sh"), 'APP_VERSION="${APP_VERSION:-1.5.0}"')
      assert_release_error(/canonical metadata/) do
        WavesRelease::RepositoryContract.validate!(root: root, metadata: metadata)
      end

      write_repository_contract_fixture(root)
      File.write(File.join(root, ".github/workflows/release.yml"), "env:\n  RELEASE_BUILD: 13\n")
      assert_release_error(/duplicated release metadata/) do
        WavesRelease::RepositoryContract.validate!(root: root, metadata: metadata)
      end

      write_repository_contract_fixture(root)
      File.write(File.join(root, "CHANGELOG.md"), "## [1.4.4]\n")
      assert_release_error(/CHANGELOG/) do
        WavesRelease::RepositoryContract.validate!(root: root, metadata: metadata)
      end

      write_repository_contract_fixture(root)
      File.write(File.join(root, "Casks/waves.rb"), 'version "1.4.4"')
      assert_release_error(/Casks/) do
        WavesRelease::RepositoryContract.validate!(root: root, metadata: metadata)
      end
    end
  end

  def test_git_contract_rejects_dirty_tree_and_wrong_revision
    with_git_repo do |root|
      revision = git(root, "rev-parse", "HEAD").strip
      WavesRelease::GitContract.clean_exact_revision!(root: root, expected_revision: revision)

      assert_release_error(/revision/) do
        WavesRelease::GitContract.clean_exact_revision!(root: root, expected_revision: "f" * 40)
      end

      File.write(File.join(root, "README.md"), "dirty\n")
      assert_release_error(/clean tracked tree/) do
        WavesRelease::GitContract.clean_exact_revision!(root: root, expected_revision: revision)
      end
    end
  end

  def test_release_source_identity_rejects_untracked_and_ignored_build_inputs
    release_source = WavesRelease.const_defined?(:ReleaseSource) ? WavesRelease::ReleaseSource : nil
    refute_nil release_source, "release source identity must be implemented"
    return unless release_source

    with_git_repo do |root|
      revision = git(root, "rev-parse", "HEAD").strip
      FileUtils.mkdir_p(File.join(root, "Sources"))
      File.write(File.join(root, "Sources/injected.swift"), "let injected = true\n")

      assert_release_error(/untracked build input/) do
        release_source.identity!(root: root, expected_revision: revision)
      end
    end

    with_git_repo do |root|
      File.write(File.join(root, ".gitignore"), "Sources/*.swift\n")
      git(root, "add", ".gitignore")
      git(root, "commit", "-m", "chore: ignore fixture")
      revision = git(root, "rev-parse", "HEAD").strip
      FileUtils.mkdir_p(File.join(root, "Sources"))
      File.write(File.join(root, "Sources/injected.swift"), "let injected = true\n")

      assert_release_error(/untracked build input/) do
        release_source.identity!(root: root, expected_revision: revision)
      end
    end
  end

  def test_distribution_builder_uses_a_fresh_private_scratch_root_outside_the_checkout
    with_release_script_repo do |root, helper_root|
      fake_bin = File.join(helper_root, "bin")
      log = File.join(helper_root, "swift-arguments.log")
      FileUtils.mkdir_p(fake_bin)
      fake_swift = File.join(fake_bin, "swift")
      File.write(fake_swift, <<~SH)
        #!/bin/sh
        printf '%s\n' "$@" > "$WAVES_TEST_SWIFT_LOG"
        exit 23
      SH
      FileUtils.chmod(0o700, fake_swift)

      _stdout, _stderr, status = Open3.capture3(
        {
          "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
          "WAVES_TEST_SWIFT_LOG" => log,
        },
        File.join(root, "script/build_and_run.sh"),
        "--release-check",
        chdir: root
      )

      refute status.success?, "the fixture package must stop before producing a release"
      refute File.exist?(log), "release build must never execute the PATH-selected compiler"
      refute Dir.exist?(File.join(root, ".build")), "release build must not create checkout SwiftPM state"
    end
  end

  def test_distribution_builder_rejects_dirty_checkout_even_with_forged_inner_environment
    with_release_script_repo do |root, helper_root|
      fake_bin = File.join(helper_root, "bin")
      compiler_marker = File.join(helper_root, "compiler-ran")
      archive = File.join(helper_root, "caller-source.tar")
      scratch = File.join(helper_root, "caller-scratch")
      output = File.join(helper_root, "caller-output")
      FileUtils.mkdir_p(fake_bin)
      FileUtils.mkdir_p(scratch)
      File.write(archive, "caller-selected archive")
      fake_swift = File.join(fake_bin, "swift")
      File.write(fake_swift, <<~SH)
        #!/bin/sh
        touch "$WAVES_TEST_COMPILER_MARKER"
        exit 23
      SH
      FileUtils.chmod(0o700, fake_swift)

      revision = git(root, "rev-parse", "HEAD").strip
      recipe = WavesRelease::ReleaseSource.recipe_digest_from_files(root: root)
      File.write(File.join(root, "Sources/Fixture.swift"), "let injected = true\n")

      _stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
          "APP_SOURCE_REVISION" => revision,
          "WAVES_BUILD_RECIPE_SHA256" => recipe,
          "WAVES_ISOLATED_RELEASE_BUILD" => "1",
          "WAVES_RELEASE_OUTPUT_DIR" => output,
          "WAVES_RELEASE_SCRATCH_ROOT" => scratch,
          "WAVES_RELEASE_SOURCE_ARCHIVE" => archive,
          "WAVES_SOURCE_ARCHIVE_SHA256" => Digest::SHA256.file(archive).hexdigest,
          "WAVES_TEST_COMPILER_MARKER" => compiler_marker,
        },
        File.join(root, "script/build_and_run.sh"),
        "--release-check",
        chdir: root
      )

      refute status.success?
      assert_match(/clean tracked tree/, stderr)
      refute File.exist?(compiler_marker), "dirty caller source must be rejected before compilation"
    end
  end

  def test_task12d_distribution_builder_never_executes_a_path_selected_compiler_or_canonical_override
    with_release_script_repo do |root, helper_root|
      fake_bin = File.join(helper_root, "poison-bin")
      marker = File.join(helper_root, "poisoned-compiler-ran")
      alternate_metadata = File.join(helper_root, "alternate-metadata.json")
      FileUtils.mkdir_p(fake_bin)
      File.write(File.join(fake_bin, "swift"), <<~SH)
        #!/bin/sh
        touch "$WAVES_TEST_POISON_MARKER"
        exit 23
      SH
      FileUtils.chmod(0o700, File.join(fake_bin, "swift"))
      write_json(alternate_metadata, metadata_hash)

      [
        {"PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}"},
        {"WAVES_RELEASE_METADATA" => alternate_metadata},
        {"SWIFT_SDK" => helper_root},
      ].each do |poison|
        FileUtils.rm_f(marker)
        _stdout, stderr, status = Open3.capture3(
          poison.merge("WAVES_TEST_POISON_MARKER" => marker),
          File.join(root, "script/build_and_run.sh"),
          "--release-check",
          chdir: root
        )
        refute status.success?
        refute File.exist?(marker), "release poison must be rejected before the compiler executes"
        if poison.key?("WAVES_RELEASE_METADATA") || poison.key?("SWIFT_SDK")
          assert_match(/override|release environment/, stderr)
        end
      end
    end
  end

  def test_task12d_realtime_audit_rejects_caller_selected_source
    Dir.mktmpdir("waves-audit-override") do |root|
      fake_source = File.join(root, "Fake.swift")
      File.write(fake_source, <<~SWIFT)
        // REALTIME_CALLBACK_AUDIT_BEGIN
        let safeLookingOverride = true
        // REALTIME_CALLBACK_AUDIT_END
      SWIFT
      _stdout, stderr, status = Open3.capture3(
        {"WAVES_REALTIME_SOURCE" => fake_source},
        File.expand_path("../audit-realtime-callback.sh", __dir__)
      )
      refute status.success?
      assert_match(/override|canonical/, stderr)
    end
  end

  def test_task12d_toolchain_rejects_non_root_owned_developer_and_sdk_roots
    toolchain = WavesRelease.const_defined?(:TrustedToolchain) ? WavesRelease::TrustedToolchain : nil
    refute_nil toolchain, "trusted Apple developer toolchain validation must be implemented"
    return unless toolchain

    Dir.mktmpdir("waves-untrusted-developer") do |root|
      developer = File.join(root, "Developer")
      sdk = File.join(developer, "SDKs/MacOSX.sdk")
      swift = File.join(developer, "usr/bin/swift")
      FileUtils.mkdir_p(sdk)
      FileUtils.mkdir_p(File.dirname(swift))
      File.write(swift, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o700, swift)

      assert_release_error(/root-owned/) do
        toolchain.validate!(developer_dir: developer, sdk_path: sdk, swift_path: swift)
      end
    end
  end

  def test_source_history_blocks_product_skip_without_exact_local_equivalence
    with_git_repo do |root|
      base = git(root, "rev-parse", "HEAD").strip
      FileUtils.mkdir_p(File.join(root, "Sources"))
      File.write(File.join(root, "Sources/change.swift"), "let changed = true\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "fix: product [skip ci]")
      skipped = git(root, "rev-parse", "HEAD").strip

      assert_release_error(/equivalent local quality/) do
        WavesRelease::History.validate!(repo: root, from_revision: base, to_revision: skipped, manifest: nil)
      end

      manifest = {"skipCIEquivalentEvidence" => [{"commit" => skipped, "status" => "passed", "qualityGate" => "full"}]}
      WavesRelease::History.validate!(repo: root, from_revision: base, to_revision: skipped, manifest: manifest)

      FileUtils.mkdir_p(File.join(root, "notes"))
      File.write(File.join(root, "notes/context.md"), "documentation only\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "docs: context [ci skip]")
      WavesRelease::History.validate!(
        repo: root,
        from_revision: skipped,
        to_revision: git(root, "rev-parse", "HEAD").strip,
        manifest: nil
      )
    end
  end

  def test_task12d_source_history_detects_skip_markers_in_commit_bodies
    with_git_repo do |root|
      base = git(root, "rev-parse", "HEAD").strip
      FileUtils.mkdir_p(File.join(root, "Sources"))
      File.write(File.join(root, "Sources/body.swift"), "let bodySkip = true\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "fix: body marker", "-m", "release policy [skip ci]")
      skipped = git(root, "rev-parse", "HEAD").strip

      assert_release_error(/equivalent local quality/) do
        WavesRelease::History.validate!(repo: root, from_revision: base, to_revision: skipped, manifest: nil)
      end
    end
  end

  def test_task12d_source_history_derives_privacy_manifest_from_canonical_build_inputs
    with_git_repo do |root|
      base = git(root, "rev-parse", "HEAD").strip
      File.write(File.join(root, "PrivacyInfo.xcprivacy"), "privacy\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "fix: privacy manifest [skip actions]")
      skipped = git(root, "rev-parse", "HEAD").strip

      assert_includes WavesRelease::ReleaseSource::BUILD_INPUT_PATHS, "PrivacyInfo.xcprivacy"
      assert_release_error(/equivalent local quality/) do
        WavesRelease::History.validate!(repo: root, from_revision: base, to_revision: skipped, manifest: nil)
      end
    end
  end

  def test_publication_tag_requires_an_annotated_version_tag_on_the_current_history
    with_git_repo do |root|
      with_ephemeral_ssh_keypair("waves-release-publication") do |private_key, public_key|
        metadata = security_metadata_hash(
          public_key: File.read(public_key).strip,
          fingerprint: ssh_fingerprint(public_key)
        )
        revision = git(root, "rev-parse", "HEAD").strip
        manifest = WavesRelease::Evidence.seal(
          input: evidence_input(remote: "passed", revision: revision),
          metadata: metadata,
          profile: "publication"
        )
        json = WavesRelease::CanonicalJSON.generate(manifest)
        envelope = WavesRelease::TagEnvelope.build(json: json, digest: WavesRelease::CanonicalJSON.sha256(json))
        git(root, "update-ref", "refs/remotes/origin/main", revision)
        create_signed_tag(root, RELEASE_TAG, envelope, private_key)

        WavesRelease::PublicationTag.validate!(root: root, tag: RELEASE_TAG, metadata: metadata)

        git(root, "tag", "-d", RELEASE_TAG)
        git(root, "tag", RELEASE_TAG)
        assert_release_error(/annotated/) do
          WavesRelease::PublicationTag.validate!(root: root, tag: RELEASE_TAG, metadata: metadata)
        end

        git(root, "tag", "-d", RELEASE_TAG)
        create_signed_tag(root, RELEASE_TAG, envelope, private_key)
        File.write(File.join(root, "next.txt"), "next\n")
        git(root, "add", ".")
        git(root, "commit", "-m", "docs: next")
        git(root, "update-ref", "refs/remotes/origin/main", git(root, "rev-parse", "HEAD").strip)

        WavesRelease::PublicationTag.validate!(root: root, tag: RELEASE_TAG, metadata: metadata)

        git(root, "checkout", "--orphan", "diverged")
        git(root, "rm", "-rf", ".")
        File.write(File.join(root, "diverged.txt"), "diverged\n")
        git(root, "add", ".")
        git(root, "commit", "-m", "docs: divergent history")
        assert_release_error(/ancestor of HEAD/) do
          WavesRelease::PublicationTag.validate!(root: root, tag: RELEASE_TAG, metadata: metadata)
        end
      end
    end
  end

  def test_task12d_publication_tag_requires_the_pinned_ssh_key_and_principal
    authority = WavesRelease.const_defined?(:TagAuthority) ? WavesRelease::TagAuthority : nil
    refute_nil authority, "signed publication tag authority must be implemented"
    return unless authority

    with_git_repo do |root|
      with_ephemeral_ssh_keypair("waves-release-correct") do |correct_private, correct_public|
        with_ephemeral_ssh_keypair("waves-release-wrong") do |wrong_private, _wrong_public|
          expected = {
            "principal" => RELEASE_PRINCIPAL,
            "publicKey" => File.read(correct_public).strip,
            "fingerprint" => ssh_fingerprint(correct_public),
          }

          git_with_input(root, "unsigned evidence\n", "tag", "-a", RELEASE_TAG, "-F", "-")
          assert_release_error(/signed/) do
            authority.verify!(root: root, tag: RELEASE_TAG, authority: expected)
          end
          git(root, "tag", "-d", RELEASE_TAG)

          create_signed_tag(root, RELEASE_TAG, "wrong key evidence\n", wrong_private)
          assert_release_error(/pinned release key|signature/) do
            authority.verify!(root: root, tag: RELEASE_TAG, authority: expected)
          end
          git(root, "tag", "-d", RELEASE_TAG)

          create_signed_tag(root, RELEASE_TAG, "wrong principal evidence\n", correct_private)
          assert_release_error(/principal/) do
            authority.verify!(
              root: root,
              tag: RELEASE_TAG,
              authority: expected.merge("principal" => "untrusted-release")
            )
          end
          git(root, "tag", "-d", RELEASE_TAG)

          create_signed_tag(root, RELEASE_TAG, "trusted evidence\n", correct_private)
          result = authority.verify!(root: root, tag: RELEASE_TAG, authority: expected)
          assert_equal RELEASE_PRINCIPAL, result.fetch("principal")
          assert_equal expected.fetch("fingerprint"), result.fetch("fingerprint")
        end
      end
    end
  end

  def test_workflow_contract_rejects_unpinned_action_missing_guard_or_shared_gate_bypass
    Dir.mktmpdir("waves-workflows") do |root|
      write_workflow_fixtures(root)
      WavesRelease::WorkflowContract.validate!(root: root)

      mutate(root, ".github/workflows/ci.yml", "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7")
      assert_release_error(/pinned/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/ci.yml", "    timeout-minutes: 90\n", "")
      assert_release_error(/timeout/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/ci.yml", "concurrency:\n  group: ci-${{ github.workflow }}-${{ github.ref }}\n  cancel-in-progress: true\n", "")
      assert_release_error(/concurrency/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/ci.yml", "./script/quality-gate.sh full", "swift test")
      assert_release_error(/quality-gate/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/ci.yml", "          fetch-depth: 0\n", "")
      assert_release_error(/CI job.*fetch-depth/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/ci.yml", "          persist-credentials: false\n", "")
      assert_release_error(/CI job.*persist-credentials/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/release.yml", "./script/release-gate.sh preflight", "./script/build_and_run.sh --publication-check")
      assert_release_error(/release-gate/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/release.yml", "      contents: read\n", "      contents: write\n")
      assert_release_error(/read-only/) { WavesRelease::WorkflowContract.validate!(root: root) }
    end
  end

  def test_workflow_contract_rejects_dead_string_gate_and_retention_bypasses
    Dir.mktmpdir("waves-workflows") do |root|
      write_workflow_fixtures(root)
      mutate(
        root,
        ".github/workflows/ci.yml",
        "- run: ./script/quality-gate.sh full",
        "- run: echo './script/quality-gate.sh full'"
      )
      assert_release_error(/quality-gate/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(
        root,
        ".github/workflows/release.yml",
        "run: ./script/release-gate.sh preflight",
        "run: echo './script/release-gate.sh preflight'"
      )
      assert_release_error(/release-gate/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(
        root,
        ".github/workflows/ci.yml",
        "retention-days: 14",
        "retention-days: 7 # retention-days: 14"
      )
      assert_release_error(/retention/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(
        root,
        ".github/workflows/release.yml",
        "retention-days: 14",
        "retention-days: 7 # retention-days: 14"
      )
      assert_release_error(/retention/) { WavesRelease::WorkflowContract.validate!(root: root) }
    end
  end

  def test_release_workflow_requires_exact_revision_checkout_for_every_job
    Dir.mktmpdir("waves-workflows") do |root|
      write_workflow_fixtures(root)
      WavesRelease::WorkflowContract.validate!(root: root)

      mutate(
        root,
        ".github/workflows/release.yml",
        "      - name: Verify checkout\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          ref: ${{ inputs.revision }}\n          fetch-depth: 0\n          persist-credentials: false\n",
        "      - name: Verify checkout\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n        with:\n          fetch-depth: 0\n          persist-credentials: false\n"
      )
      assert_release_error(/checkout.*ref/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/release.yml", "ref: ${{ inputs.revision }}", "ref: refs/heads/main")
      assert_release_error(/checkout.*ref/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/release.yml", "persist-credentials: false", "persist-credentials: true")
      assert_release_error(/persist-credentials/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(root, ".github/workflows/release.yml", "          persist-credentials: false\n", "")
      assert_release_error(/persist-credentials/) { WavesRelease::WorkflowContract.validate!(root: root) }
    end
  end

  def test_release_workflow_binds_revision_validation_and_preflight_to_the_input
    Dir.mktmpdir("waves-workflows") do |root|
      write_workflow_fixtures(root)
      WavesRelease::WorkflowContract.validate!(root: root)

      mutate(
        root,
        ".github/workflows/release.yml",
        "REQUESTED_REVISION: ${{ inputs.revision }}",
        "REQUESTED_REVISION: ${{ github.sha }}"
      )
      assert_release_error(/revision validation/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(
        root,
        ".github/workflows/release.yml",
        'test "$(./script/release_git rev-parse HEAD)" = "$REQUESTED_REVISION"',
        "true"
      )
      assert_release_error(/revision validation/) { WavesRelease::WorkflowContract.validate!(root: root) }

      write_workflow_fixtures(root)
      mutate(
        root,
        ".github/workflows/release.yml",
        "WAVES_EXPECTED_REVISION: ${{ inputs.revision }}",
        "WAVES_EXPECTED_REVISION: ${{ github.sha }}"
      )
      assert_release_error(/preflight.*revision/) { WavesRelease::WorkflowContract.validate!(root: root) }
    end
  end

  def test_release_workflow_rejects_a_structural_second_job_without_credential_strings
    Dir.mktmpdir("waves-workflows") do |root|
      write_workflow_fixtures(root)
      WavesRelease::WorkflowContract.validate!(root: root)
      mutate(
        root,
        ".github/workflows/release.yml",
        "jobs:\n  verify:\n",
        "jobs:\n" \
          "  package:\n" \
          "    timeout-minutes: 30\n" \
          "    permissions:\n" \
          "      contents: read\n" \
          "    steps:\n" \
          "      - run: echo package verification\n" \
          "  verify:\n"
      )
      assert_release_error(/verification-only/) do
        WavesRelease::WorkflowContract.validate!(root: root)
      end
    end
  end

  def test_appcast_refuses_to_reach_update_signing_without_publication_authorization
    Dir.mktmpdir("waves-appcast-auth") do |root|
      dmg = File.join(root, "Waves.dmg")
      signer = File.join(root, "sign_update")
      marker = File.join(root, "signer-ran")
      File.write(dmg, "untrusted bytes")
      File.write(signer, "#!/bin/sh\ntouch \"#{marker}\"\nprintf 'ZmFrZQ=='\n")
      FileUtils.chmod(0o700, signer)

      _stdout, stderr, status = Open3.capture3(
        {
          "EXPECTED_SHA256" => Digest::SHA256.file(dmg).hexdigest,
          "SIGN_UPDATE" => signer,
        },
        File.expand_path("../make_appcast.sh", __dir__),
        VERSION,
        dmg,
        File.join(root, "appcast.xml")
      )

      refute status.success?
      assert_match(/overrides are prohibited|WAVES_RELEASE_TAG/, stderr)
      refute File.exist?(marker), "sign_update must not run before publication authorization"
    end
  end

  def test_task12d_release_scripts_keep_private_artifact_and_key_bound_order
    root = File.expand_path("../..", __dir__)
    WavesRelease::ReleaseScriptContract.validate!(root: root)

    mutations = [
      [
        "script/build_and_run.sh",
        'WAVES_RELEASE_OUTPUT_DIR="$ACTIVE_ISOLATION_ROOT/artifacts"',
        'WAVES_RELEASE_OUTPUT_DIR="$checkout_root/dist"',
        /private staging|checkout dist/,
      ],
      [
        "script/build_and_run.sh",
        '/usr/bin/codesign "${args[@]}" --sign',
        'codesign "${args[@]}" --sign',
        /trusted absolute codesign/,
      ],
      [
        "script/make_appcast.sh",
        'private-stage-file "$DMG_PATH"',
        'printf "%s\\n" "$DMG_PATH"',
        /stage, verify, sign/,
      ],
      [
        "script/make_appcast.sh",
        "sparkle-sign-and-verify",
        "sparkle-signing-tool",
        /stage, verify, sign|Sparkle account signature/,
      ],
      [
        "script/audit-realtime-callback.sh",
        'SOURCE_PATH="$ROOT_DIR/Sources/Waves/Services/Audio/PerAppTapController.swift"',
        'SOURCE_PATH="${WAVES_REALTIME_SOURCE:-$ROOT_DIR/Sources/Waves/Services/Audio/PerAppTapController.swift}"',
        /canonical tracked source/,
      ],
      [
        "script/prepare-elgato-handoff.sh",
        'release-gate.sh" candidate',
        'release-gate.sh" preflight',
        /candidate before assembly/,
      ],
    ]
    mutations.each do |relative, before, after, error|
      Dir.mktmpdir("waves-script-security") do |fixture|
        %w[
          script/build_and_run.sh
          script/make_appcast.sh
          script/audit-realtime-callback.sh
          script/prepare-elgato-handoff.sh
        ].each do |path|
          destination = File.join(fixture, path)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(File.join(root, path), destination)
        end
        mutate(fixture, relative, before, after)
        assert_release_error(error) { WavesRelease::ReleaseScriptContract.validate!(root: fixture) }
      end
    end
  end

  def test_release_signing_binds_each_credential_to_the_validated_login_account
    source = File.read(File.expand_path("../build_and_run.sh", __dir__))

    assert_includes source, "resolve_signing_account_paths"
    assert_includes source, 'SIGNING_USER_HOME=""'
    assert_includes source, 'SIGNING_KEYCHAIN=""'
    assert_includes source, '/usr/bin/dscl . -read "/Users/$account_name" NFSHomeDirectory'
    assert_includes source, "run_signing_security()"
    assert_includes source, 'run_signing_security find-identity -v -p codesigning "$SIGNING_KEYCHAIN"'
    assert_includes source, "/usr/bin/csrutil status"
    assert_includes source, "credentialed release signing requires System Integrity Protection"

    assert_includes source,
      '/usr/bin/codesign --keychain "$SIGNING_KEYCHAIN" "${args[@]}" --sign "$identity" "$target"'
    assert_includes source,
      '/usr/bin/codesign --keychain "$SIGNING_KEYCHAIN" --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"'

    assert_includes source, "run_notarytool()"
    assert_includes source, 'HOME="$SIGNING_USER_HOME"'
    assert_includes source, 'run_notarytool history --keychain-profile "$NOTARY_PROFILE"'
    assert_includes source,
      'run_notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json'
  end

  def test_hosted_quality_gate_uses_the_release_ruby_and_only_a_trusted_apple_toolchain
    root = File.expand_path("../..", __dir__)
    quality_gate = File.read(File.join(root, "script/quality-gate.sh"))
    workflows = %w[ci.yml release.yml].to_h do |name|
      [name, File.read(File.join(root, ".github/workflows", name))]
    end

    assert_includes quality_gate, 'RELEASE_RUBY="/usr/bin/ruby"'
    refute_match(/(?:^|[[:space:]])ruby(?:[[:space:]]|$)/, quality_gate)
    workflows.each do |name, workflow|
      assert_includes workflow, "/Library/Developer/CommandLineTools", name
      assert_includes workflow, "trusted-toolchain", name
      assert_includes workflow, 'sudo xcode-select -s "$TRUSTED_DEVELOPER_DIR"', name
      refute_includes workflow, "Select latest available Xcode", name
    end
  end

  private

  def evidence_authoring_entrypoints(directory = nil)
    scratch = directory || Dir.tmpdir
    [
      [
        File.expand_path("../generate-release-evidence.sh", __dir__),
        ["candidate", File.join(scratch, "missing-input.json"), File.join(scratch, "unused-manifest.json")],
      ],
      [
        File.expand_path("../generate-release-tag-envelope.sh", __dir__),
        [File.join(scratch, "missing-manifest.json"), File.join(scratch, "unused-envelope.txt")],
      ],
    ]
  end

  def assert_release_preflight_disables_fsmonitor(configuration)
    with_production_release_repo do |root, scratch|
      marker = File.join(scratch, "#{configuration}-fsmonitor-ran")
      hook = write_executable(File.join(scratch, "#{configuration}-fsmonitor"), <<~SHELL)
        #!/bin/sh
        printf 'fsmonitor ran\n' >> #{Shellwords.escape(marker)}
        printf 'token\n'
      SHELL
      if configuration == :local
        git(root, "config", "core.fsmonitor", hook)
      else
        included_config = File.join(scratch, "included-git-config")
        File.write(included_config, "[core]\n\tfsmonitor = #{hook.inspect}\n")
        git(root, "config", "include.path", included_config)
      end

      revision = git(root, "rev-parse", "HEAD").strip
      _stdout, stderr, status = Open3.capture3(
        {"WAVES_EXPECTED_REVISION" => revision},
        File.join(root, "script/release-gate.sh"),
        "preflight",
        chdir: root
      )

      assert status.success?, "#{configuration} fsmonitor fixture must preserve preflight: #{stderr}"
      refute File.exist?(marker), "#{configuration} core.fsmonitor must not execute during release preflight"
    end
  end

  def with_production_release_repo
    source_root = File.expand_path("../..", __dir__)
    Dir.mktmpdir("waves-release-git-policy") do |scratch|
      root = File.join(scratch, "repo")
      run_fixture_command!("/usr/bin/git", "clone", "-q", "--no-hardlinks", source_root, root)
      git(root, "config", "user.name", "Waves Test")
      git(root, "config", "user.email", "waves-test@example.com")
      %w[
        .github/workflows/ci.yml
        .github/workflows/release.yml
        script/release_tool.rb
        script/release_environment.sh
        script/release_git
        script/release-gate.sh
        script/build_and_run.sh
        script/make_appcast.sh
        script/prepare-elgato-handoff.sh
      ].each do |relative|
        source = File.join(source_root, relative)
        next unless File.file?(source)

        destination = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(source, destination)
      end
      git(
        root,
        "add",
        ".github/workflows/ci.yml",
        ".github/workflows/release.yml",
        "script/release_tool.rb",
        "script/release_environment.sh",
        "script/release-gate.sh",
        "script/build_and_run.sh",
        "script/make_appcast.sh",
        "script/prepare-elgato-handoff.sh"
      )
      git(root, "add", "script/release_git") if File.file?(File.join(root, "script/release_git"))
      _stdout, _stderr, status = Open3.capture3("/usr/bin/git", "-C", root, "diff", "--cached", "--quiet")
      git(root, "commit", "-q", "-m", "test: overlay release implementation") unless status.success?

      yield root, scratch
    end
  end

  def write_executable(path, contents)
    File.write(path, contents)
    FileUtils.chmod(0o700, path)
    path
  end

  def with_startup_attack_fixture
    Dir.mktmpdir("waves-startup-attack") do |directory|
      marker = File.join(directory, "startup-code-ran")
      bash_hook = File.join(directory, "bash-env.sh")
      ruby_hook = File.join(directory, "waves_startup_attack.rb")
      File.write(bash_hook, <<~SHELL)
        : > "$WAVES_ATTACK_MARKER"
        exit 92
      SHELL
      File.write(ruby_hook, <<~RUBY)
        File.write(ENV.fetch("WAVES_ATTACK_MARKER"), "ruby startup code ran\n")
        exit 91
      RUBY

      yield directory, marker, bash_hook, ruby_hook
    end
  end

  def write_repository_contract_fixture(root)
    write_json(File.join(root, "release/metadata.json"), metadata_hash)
    FileUtils.mkdir_p(File.join(root, "script"))
    File.write(File.join(root, "script/build_and_run.sh"), 'ruby "$ROOT_DIR/script/release_tool.rb" metadata version')
    File.write(File.join(root, "script/make_appcast.sh"), 'ruby "$ROOT_DIR/script/release_tool.rb" metadata version')
    FileUtils.mkdir_p(File.join(root, ".github/workflows"))
    File.write(File.join(root, ".github/workflows/ci.yml"), "run: ./script/quality-gate.sh full\n")
    File.write(File.join(root, ".github/workflows/release.yml"), "run: ./script/release-gate.sh publication\n")
    File.write(File.join(root, "CHANGELOG.md"), "## [#{VERSION}] - 2026-08-09\n\nRelease notes.\n")
    FileUtils.mkdir_p(File.join(root, "Casks"))
    File.write(
      File.join(root, "Casks/waves.rb"),
      "version \"#{VERSION}\"\nsha256 \"RELEASE_WORKFLOW_REPLACES_THIS_SHA256\"\n"
    )
    File.write(File.join(root, "Package.swift"), '.macOS("14.2")')
  end

  def write_workflow_fixtures(root)
    FileUtils.mkdir_p(File.join(root, ".github/workflows"))
    File.write(File.join(root, ".github/workflows/ci.yml"), <<~YAML)
      name: CI
      on:
        pull_request:
        push:
          branches: [main]
      permissions:
        contents: read
      concurrency:
        group: ci-${{ github.workflow }}-${{ github.ref }}
        cancel-in-progress: true
      jobs:
        quality:
          timeout-minutes: 90
          steps:
            - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
              with:
                fetch-depth: 0
                persist-credentials: false
            - run: ./script/quality-gate.sh full
            - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
              with:
                retention-days: 14
    YAML
    File.write(File.join(root, ".github/workflows/release.yml"), <<~YAML)
      name: Release
      on:
        workflow_dispatch:
          inputs:
            revision:
              required: true
      permissions:
        contents: read
      concurrency:
        group: release-${{ github.repository }}
        cancel-in-progress: false
      jobs:
        verify:
          timeout-minutes: 120
          permissions:
            contents: read
          steps:
            - name: Verify checkout
              uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
              with:
                ref: ${{ inputs.revision }}
                fetch-depth: 0
                persist-credentials: false
            - name: Validate revision input
              env:
                REQUESTED_REVISION: ${{ inputs.revision }}
              run: |
                set -euo pipefail
                if [[ ! "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
                  echo "::error::revision must be a lowercase 40-character Git revision."
                  exit 1
                fi
                test "$(./script/release_git rev-parse HEAD)" = "$REQUESTED_REVISION"
            - run: ./script/quality-gate.sh full
            - name: Validate release preflight
              env:
                WAVES_EXPECTED_REVISION: ${{ inputs.revision }}
              run: ./script/release-gate.sh preflight
            - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
              with:
                retention-days: 14
    YAML
  end

  def mutate(root, relative_path, before, after)
    path = File.join(root, relative_path)
    contents = File.read(path)
    raise "mutation target missing: #{before}" unless contents.include?(before)

    File.write(path, contents.sub(before, after))
  end

  def with_git_repo
    Dir.mktmpdir("waves-git-contract") do |root|
      git(root, "init", "-q")
      git(root, "config", "user.name", "Waves Test")
      git(root, "config", "user.email", "waves-test@example.com")
      File.write(File.join(root, "README.md"), "fixture\n")
      git(root, "add", ".")
      git(root, "commit", "-q", "-m", "chore: fixture")
      yield root
    end
  end

  def with_release_script_repo
    Dir.mktmpdir("waves-release-script") do |container|
      root = File.join(container, "repo")
      FileUtils.mkdir_p(File.join(root, "script"))
      FileUtils.mkdir_p(File.join(root, "release"))
      FileUtils.mkdir_p(File.join(root, "Sources"))
      FileUtils.cp(File.expand_path("../build_and_run.sh", __dir__), File.join(root, "script/build_and_run.sh"))
      FileUtils.cp(File.expand_path("../release_environment.sh", __dir__), File.join(root, "script/release_environment.sh"))
      FileUtils.cp(File.expand_path("../release_git", __dir__), File.join(root, "script/release_git"))
      FileUtils.cp(File.expand_path("../release_tool.rb", __dir__), File.join(root, "script/release_tool.rb"))
      write_json(File.join(root, "release/metadata.json"), metadata_hash)
      File.write(File.join(root, "Package.swift"), "// fixture\n")
      File.write(File.join(root, "Package.resolved"), "{}\n")
      File.write(File.join(root, "PrivacyInfo.xcprivacy"), "fixture\n")
      File.write(File.join(root, "Sources/Fixture.swift"), "let fixture = true\n")
      git(root, "init", "-q")
      git(root, "config", "user.name", "Waves Test")
      git(root, "config", "user.email", "waves-test@example.com")
      git(root, "add", ".")
      git(root, "commit", "-q", "-m", "chore: fixture")
      yield root, container
    end
  end

  def with_ephemeral_ssh_keypair(name)
    Dir.mktmpdir(name) do |root|
      private_key = File.join(root, "key")
      _stdout, stderr, status = Open3.capture3(
        "/usr/bin/ssh-keygen",
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-C",
        name,
        "-f",
        private_key
      )
      raise "ssh-keygen failed: #{stderr}" unless status.success?

      yield private_key, "#{private_key}.pub"
    end
  end

  def ssh_fingerprint(public_key)
    stdout, stderr, status = Open3.capture3(
      "/usr/bin/ssh-keygen",
      "-lf",
      public_key,
      "-E",
      "sha256"
    )
    raise "ssh-keygen fingerprint failed: #{stderr}" unless status.success?

    stdout.split.fetch(1)
  end

  def create_signed_tag(root, tag, message, private_key)
    git_with_input(
      root,
      message,
      "-c",
      "gpg.format=ssh",
      "-c",
      "user.signingkey=#{private_key}",
      "tag",
      "-s",
      tag,
      "-F",
      "-"
    )
  end

  def with_ephemeral_sparkle_tools
    openssl = [
      "/opt/homebrew/bin/openssl",
      "/usr/local/bin/openssl",
      "/usr/bin/openssl",
    ].find { |candidate| File.executable?(candidate) }
    raise "OpenSSL is required for the ephemeral Sparkle fixture" unless openssl

    Dir.mktmpdir("waves-sparkle-binding") do |scratch|
      FileUtils.chmod(0o700, scratch)
      bin = File.join(scratch, "artifacts/sparkle/Sparkle/bin")
      keys = File.join(scratch, "fixture-keys")
      FileUtils.mkdir_p(bin)
      FileUtils.mkdir_p(keys)
      private_key = File.join(keys, "private.pem")
      public_key = File.join(keys, "public.pem")
      public_der = File.join(keys, "public.der")
      run_fixture_command!(openssl, "genpkey", "-algorithm", "Ed25519", "-out", private_key)
      run_fixture_command!(openssl, "pkey", "-in", private_key, "-pubout", "-out", public_key)
      run_fixture_command!(
        openssl,
        "pkey",
        "-in",
        private_key,
        "-pubout",
        "-outform",
        "DER",
        "-out",
        public_der
      )
      encoded_public_key = Base64.strict_encode64(File.binread(public_der).bytes.last(32).pack("C*"))
      artifact = File.join(scratch, "Waves.dmg")
      signer_marker = File.join(scratch, "signer-ran")
      tamper_marker = File.join(scratch, "tamper-signature")
      File.binwrite(artifact, "published Waves artifact bytes\n")

      generate_keys = File.join(bin, "generate_keys")
      File.write(generate_keys, <<~RUBY)
        #!/usr/bin/ruby
        expected = ["--account", #{SPARKLE_ACCOUNT.inspect}, "-p"]
        unless ARGV == expected
          warn "explicit Waves account required"
          exit 2
        end
        puts #{encoded_public_key.inspect}
      RUBY
      FileUtils.chmod(0o700, generate_keys)

      sign_update = File.join(bin, "sign_update")
      File.write(sign_update, <<~RUBY)
        #!/usr/bin/ruby
        require "base64"
        require "open3"
        require "tempfile"

        account = #{SPARKLE_ACCOUNT.inspect}
        openssl = #{openssl.inspect}
        private_key = #{private_key.inspect}
        public_key = #{public_key.inspect}
        signer_marker = #{signer_marker.inspect}
        tamper_marker = #{tamper_marker.inspect}

        if ARGV.length == 4 && ARGV[0, 3] == ["--account", account, "-p"]
          artifact = ARGV.fetch(3)
          File.write(signer_marker, "ran\n")
          Tempfile.create("waves-signature") do |signature|
            _stdout, stderr, status = Open3.capture3(
              openssl,
              "pkeyutl",
              "-sign",
              "-rawin",
              "-inkey",
              private_key,
              "-in",
              artifact,
              "-out",
              signature.path
            )
            abort(stderr) unless status.success?
            bytes = File.binread(signature.path)
            bytes.setbyte(0, bytes.getbyte(0) ^ 0xff) if File.exist?(tamper_marker)
            puts Base64.strict_encode64(bytes)
          end
        elsif ARGV.length == 5 && ARGV[0, 3] == ["--account", account, "--verify"]
          artifact = ARGV.fetch(3)
          encoded_signature = ARGV.fetch(4)
          Tempfile.create("waves-signature") do |signature|
            begin
              signature.binmode
              signature.write(Base64.strict_decode64(encoded_signature))
              signature.flush
            rescue ArgumentError
              abort("invalid signature encoding")
            end
            _stdout, stderr, status = Open3.capture3(
              openssl,
              "pkeyutl",
              "-verify",
              "-pubin",
              "-inkey",
              public_key,
              "-rawin",
              "-in",
              artifact,
              "-sigfile",
              signature.path
            )
            abort(stderr) unless status.success?
          end
        else
          warn "explicit Waves account required"
          exit 2
        end
      RUBY
      FileUtils.chmod(0o700, sign_update)

      yield scratch, artifact, encoded_public_key, signer_marker, tamper_marker
    end
  end

  def run_fixture_command!(*arguments)
    _stdout, stderr, status = Open3.capture3(*arguments)
    raise "fixture command failed: #{arguments.join(' ')}: #{stderr}" unless status.success?
  end

  def git(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def git_with_input(root, input, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", root, *arguments, stdin_data: input)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
