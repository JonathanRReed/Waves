# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

require_relative "../release_tool"

class ReleaseInfraTest < Minitest::Test
  VERSION = "1.5.0"
  BUILD = 13
  FLOOR = "14.2"
  REVISION = "a" * 40

  def metadata_hash
    {
      "schemaVersion" => 1,
      "version" => VERSION,
      "build" => BUILD,
      "minimumMacOSVersion" => FLOOR,
    }
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
      "source" => {"revision" => revision, "trackedDirty" => false},
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
        "bundleIdentifier" => "com.jonathanreed.Waves",
        "version" => VERSION,
        "build" => BUILD,
        "minimumMacOSVersion" => FLOOR,
        "architectures" => ["arm64", "x86_64"],
        "hashes" => {
          "appExecutable" => "1" * 64,
          "dmg" => "2" * 64,
          "dSYM" => "3" * 64,
        },
        "developerID" => {"status" => "passed", "identity" => "Developer ID Application: Test (TEAMID1234)"},
        "hardenedRuntime" => passed_gate.call("runtime flag"),
        "notarization" => passed_gate.call("accepted submission"),
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
    }
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

  def test_tracked_metadata_names_the_waves_1_5_target
    metadata = WavesRelease::Metadata.load(File.expand_path("../../release/metadata.json", __dir__))
    assert_equal VERSION, metadata.fetch("version")
    assert_equal BUILD, metadata.fetch("build")
    assert_equal FLOOR, metadata.fetch("minimumMacOSVersion")
  end

  def test_metadata_reader_accepts_a_future_canonical_release_without_code_changes
    future = metadata_hash.merge("version" => "1.5.1", "build" => 14)
    with_metadata(future) do |path|
      assert_equal future, WavesRelease::Metadata.load(path)
    end
  end

  def test_metadata_rejects_absent_malformed_duplicate_unknown_and_drifted_values
    assert_release_error(/not found/) { WavesRelease::Metadata.load("/missing/waves-release.json") }

    [
      ["{", /malformed JSON/],
      ['{"schemaVersion":1,"version":"1.5.0","version":"1.5.1","build":13,"minimumMacOSVersion":"14.2"}', /duplicate key/],
      [metadata_hash.merge("extra" => true), /unknown key/],
      [metadata_hash.merge("version" => "01.5.0"), /version/],
      [metadata_hash.merge("build" => "13"), /integer/],
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

  def test_publication_tag_requires_annotated_exact_matching_tag_and_origin_main
    with_git_repo do |root|
      revision = git(root, "rev-parse", "HEAD").strip
      manifest = WavesRelease::Evidence.seal(
        input: evidence_input(remote: "passed", revision: revision),
        metadata: load_metadata,
        profile: "publication"
      )
      json = WavesRelease::CanonicalJSON.generate(manifest)
      envelope = WavesRelease::TagEnvelope.build(json: json, digest: WavesRelease::CanonicalJSON.sha256(json))
      git(root, "update-ref", "refs/remotes/origin/main", revision)
      git_with_input(root, envelope, "tag", "-a", "v1.5.0", "-F", "-")

      WavesRelease::PublicationTag.validate!(root: root, tag: "v1.5.0", metadata: load_metadata)

      git(root, "tag", "-d", "v1.5.0")
      git(root, "tag", "v1.5.0")
      assert_release_error(/annotated/) do
        WavesRelease::PublicationTag.validate!(root: root, tag: "v1.5.0", metadata: load_metadata)
      end

      git(root, "tag", "-d", "v1.5.0")
      git_with_input(root, envelope, "tag", "-a", "v1.5.0", revision, "-F", "-")
      File.write(File.join(root, "next.txt"), "next\n")
      git(root, "add", ".")
      git(root, "commit", "-m", "docs: next")
      assert_release_error(/HEAD/) do
        WavesRelease::PublicationTag.validate!(root: root, tag: "v1.5.0", metadata: load_metadata)
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
      mutate(root, ".github/workflows/release.yml", "./script/release-gate.sh candidate", "./script/build_and_run.sh --publication-check")
      assert_release_error(/release-gate/) { WavesRelease::WorkflowContract.validate!(root: root) }
    end
  end

  private

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
            - run: ./script/quality-gate.sh full
            - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
              with:
                retention-days: 14
    YAML
    File.write(File.join(root, ".github/workflows/release.yml"), <<~YAML)
      name: Release
      on:
        workflow_dispatch:
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
            - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
            - run: ./script/quality-gate.sh full
        sign:
          timeout-minutes: 120
          permissions:
            contents: read
          steps:
            - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
            - run: ./script/release-gate.sh candidate
            - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a
              with:
                retention-days: 14
        draft-publication:
          timeout-minutes: 30
          permissions:
            contents: write
          steps:
            - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c
            - run: ./script/release-gate.sh publication
            - uses: softprops/action-gh-release@3d0d9888cb7fd7b750713d6e236d1fcb99157228
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
