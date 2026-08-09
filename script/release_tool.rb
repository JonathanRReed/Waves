#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "yaml"

module WavesRelease
  class Error < StandardError; end

  module Validation
    module_function

    def hash!(value, context)
      raise Error, "#{context} must be an object" unless value.is_a?(Hash)

      value
    end

    def exact_keys!(value, keys, context)
      hash!(value, context)
      unknown = value.keys - keys
      missing = keys - value.keys
      raise Error, "#{context} has unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "#{context} is missing key(s): #{missing.join(', ')}" unless missing.empty?
    end

    def nonempty_string!(value, context)
      raise Error, "#{context} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?
    end

    def revision!(value, context = "source revision")
      raise Error, "#{context} must be a lowercase 40-character Git revision" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
    end

    def sha256!(value, context)
      raise Error, "#{context} must be a lowercase SHA-256 digest" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def passed_result!(value, context, allowed_statuses: ["passed"])
      exact_keys!(value, %w[status detail], context)
      raise Error, "#{context} status must be #{allowed_statuses.join(' or ')}" unless allowed_statuses.include?(value["status"])
      nonempty_string!(value["detail"], "#{context}.detail")
    end

    def run(*command, chdir: nil, stdin_data: nil, allow_failure: false)
      stdout, stderr, status = Open3.capture3(*command, chdir: chdir, stdin_data: stdin_data)
      return [stdout, stderr, status] if allow_failure
      raise Error, "#{command.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end
  end

  class DuplicateCheckingHash < Hash
    def []=(key, value)
      raise Error, "malformed JSON: duplicate key #{key.inspect}" if key?(key)

      super
    end
  end

  module StrictJSON
    module_function

    def parse(text, context: "JSON")
      JSON.parse(text, object_class: DuplicateCheckingHash, create_additions: false)
    rescue JSON::ParserError => error
      raise Error, "malformed JSON in #{context}: #{error.message}"
    end

    def load(path)
      raise Error, "JSON file not found at #{path}" unless File.file?(path)

      parse(File.read(path), context: path)
    end
  end

  module Metadata
    KEYS = %w[schemaVersion version build minimumMacOSVersion].freeze

    module_function

    def load(path)
      raise Error, "release metadata not found at #{path}" unless File.file?(path)

      value = StrictJSON.parse(File.read(path), context: path)
      Validation.exact_keys!(value, KEYS, "release metadata")
      raise Error, "release metadata schemaVersion must be integer 1" unless value["schemaVersion"] == 1

      version = value["version"]
      raise Error, "release metadata version must be a canonical X.Y.Z string without leading zeroes" unless version.is_a?(String) && version.match?(/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/)

      build = value["build"]
      raise Error, "release metadata build must be a positive integer" unless build.is_a?(Integer) && build.positive?

      floor = value["minimumMacOSVersion"]
      raise Error, "release metadata minimum macOS version must be canonical major.minor without leading zeroes" unless floor.is_a?(String) && floor.match?(/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\z/)

      value.freeze
    end
  end

  module CanonicalJSON
    module_function

    def sort(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, sort(value.fetch(key))] }
      when Array
        value.map { |item| sort(item) }
      else
        value
      end
    end

    def generate(value)
      JSON.pretty_generate(sort(value)) + "\n"
    end

    def sha256(contents)
      Digest::SHA256.hexdigest(contents)
    end
  end

  module Evidence
    REQUIRED_TESTS = %w[swift renderedUI threadSanitizer].freeze
    REQUIRED_PERFORMANCE = %w[launchTime idleCPU steadyMemory activeMixing].freeze
    REQUIRED_PLATFORMS = %w[
      goldenGateNative rosetta tahoeAppleSilicon sequoiaAppleSilicon sonomaPhysical
    ].freeze
    REQUIRED_GATES = %w[
      localQA securityScan sanitizer routeLifecycleStress socketStress activeSoak
      idleSoak updater renderedUI pluginTypecheck pluginUnitTests pluginValidation
      pluginPackage pluginLiveSocket packageVerification remoteElgato
    ].freeze
    INPUT_KEYS = %w[
      source toolchain tests performance platforms package gates skippedGates
      skipCIEquivalentEvidence publicationEligible
    ].freeze
    MANIFEST_KEYS = %w[
      schemaVersion sealProfile release source toolchain tests performance platforms
      package gates skippedGates skipCIEquivalentEvidence publicationEligible
    ].freeze

    module_function

    def seal(input:, metadata:, profile:)
      validate_profile!(profile)
      Validation.hash!(input, "evidence input")
      unknown = input.keys - INPUT_KEYS
      required = INPUT_KEYS - ["publicationEligible"]
      missing = required - input.keys
      raise Error, "evidence input has unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "evidence input is missing key(s): #{missing.join(', ')}" unless missing.empty?

      manifest = input.reject { |key, _| key == "publicationEligible" }.merge(
        "schemaVersion" => 1,
        "sealProfile" => profile,
        "release" => metadata.dup,
        "publicationEligible" => profile == "publication"
      )
      validate!(manifest, metadata: metadata, profile: profile)
      manifest
    end

    def validate!(manifest, metadata:, profile:, expected_revision: nil)
      validate_profile!(profile)
      Validation.exact_keys!(manifest, MANIFEST_KEYS, "evidence manifest")
      raise Error, "evidence schemaVersion must be integer 1" unless manifest["schemaVersion"] == 1
      raise Error, "evidence sealProfile must be #{profile}" unless manifest["sealProfile"] == profile
      raise Error, "evidence release metadata does not match release/metadata.json" unless manifest["release"] == metadata
      expected_eligibility = profile == "publication"
      unless manifest["publicationEligible"] == expected_eligibility
        raise Error, "publicationEligible is derived and must be #{expected_eligibility} for #{profile} evidence"
      end

      validate_source!(manifest["source"], expected_revision)
      validate_toolchain!(manifest["toolchain"])
      validate_tests!(manifest["tests"])
      validate_performance!(manifest["performance"])
      validate_platforms!(manifest["platforms"])
      validate_package!(manifest["package"], metadata)
      validate_gates!(manifest["gates"], profile)
      validate_skip_data!(manifest)
      manifest
    end

    def write!(input:, metadata:, profile:, output:)
      manifest = seal(input: input, metadata: metadata, profile: profile)
      contents = CanonicalJSON.generate(manifest)
      digest = CanonicalJSON.sha256(contents)
      FileUtils.mkdir_p(File.dirname(output))
      File.write(output, contents)
      File.write("#{output}.sha256", "#{digest}  #{File.basename(output)}\n")
      manifest
    end

    def verify_file!(path:, digest_path:, metadata:, profile:, expected_revision: nil)
      raise Error, "evidence manifest not found at #{path}" unless File.file?(path)
      raise Error, "evidence SHA-256 sidecar not found at #{digest_path}" unless File.file?(digest_path)

      contents = File.read(path)
      sidecar = File.read(digest_path)
      match = sidecar.match(/\A([0-9a-f]{64})  ([^\n]+)\n?\z/)
      raise Error, "evidence SHA-256 sidecar is malformed" unless match
      raise Error, "evidence SHA-256 sidecar names #{match[2]}, expected #{File.basename(path)}" unless match[2] == File.basename(path)
      raise Error, "evidence SHA-256 does not match sealed manifest" unless match[1] == CanonicalJSON.sha256(contents)

      manifest = StrictJSON.parse(contents, context: path)
      canonical = CanonicalJSON.generate(manifest)
      raise Error, "evidence manifest is not canonical JSON" unless contents == canonical
      validate!(manifest, metadata: metadata, profile: profile, expected_revision: expected_revision)
    end

    def validate_profile!(profile)
      raise Error, "evidence profile must be candidate or publication" unless %w[candidate publication].include?(profile)
    end

    def validate_source!(source, expected_revision)
      Validation.exact_keys!(source, %w[revision trackedDirty], "source evidence")
      Validation.revision!(source["revision"])
      raise Error, "source evidence trackedDirty must be false" unless source["trackedDirty"] == false
      if expected_revision && source["revision"] != expected_revision
        raise Error, "evidence source revision #{source['revision']} does not match expected revision #{expected_revision}"
      end
    end

    def validate_toolchain!(toolchain)
      Validation.exact_keys!(toolchain, %w[swift xcode macOS], "toolchain evidence")
      toolchain.each { |name, value| Validation.nonempty_string!(value, "toolchain.#{name}") }
    end

    def validate_tests!(tests)
      Validation.exact_keys!(tests, REQUIRED_TESTS, "test evidence")
      tests.each do |name, result|
        Validation.exact_keys!(result, %w[passed failed], "tests.#{name}")
        raise Error, "tests.#{name}.passed must be a positive integer" unless result["passed"].is_a?(Integer) && result["passed"].positive?
        raise Error, "tests.#{name}.failed must be integer 0" unless result["failed"] == 0
      end
    end

    def validate_performance!(performance)
      Validation.exact_keys!(performance, REQUIRED_PERFORMANCE, "performance evidence")
      performance.each do |name, metric|
        Validation.exact_keys!(metric, %w[baseline candidate regressionPercent status approvedJustification], "performance.#{name}")
        %w[baseline candidate regressionPercent].each do |field|
          raise Error, "performance.#{name}.#{field} must be numeric" unless metric[field].is_a?(Numeric)
        end
        raise Error, "performance.#{name}.baseline must be greater than zero" unless metric["baseline"].positive?
        calculated = ((metric["candidate"] - metric["baseline"]) / metric["baseline"]) * 100.0
        raise Error, "performance.#{name}.regressionPercent does not match baseline and candidate" if (calculated - metric["regressionPercent"]).abs > 0.01
        if metric["regressionPercent"] <= 10.0
          raise Error, "performance.#{name}.status must be passed" unless metric["status"] == "passed"
        else
          raise Error, "performance.#{name} exceeds 10 percent without an approved exception" unless metric["status"] == "approvedException"
          Validation.nonempty_string!(metric["approvedJustification"], "performance.#{name}.approvedJustification")
        end
      end
    end

    def validate_platforms!(platforms)
      Validation.exact_keys!(platforms, REQUIRED_PLATFORMS, "platform evidence")
      (REQUIRED_PLATFORMS - ["sonomaPhysical"]).each do |name|
        Validation.passed_result!(platforms[name], "platforms.#{name}")
      end
      sonoma = platforms["sonomaPhysical"]
      Validation.exact_keys!(sonoma, %w[status detail], "platforms.sonomaPhysical")
      raise Error, "platforms.sonomaPhysical must honestly record unavailable" unless sonoma["status"] == "unavailable"
      Validation.nonempty_string!(sonoma["detail"], "platforms.sonomaPhysical.detail")
    end

    def validate_package!(package, metadata)
      keys = %w[
        bundleIdentifier version build minimumMacOSVersion architectures hashes
        developerID hardenedRuntime notarization stapling gatekeeper
      ]
      Validation.exact_keys!(package, keys, "package evidence")
      raise Error, "package bundle identifier must be com.jonathanreed.Waves" unless package["bundleIdentifier"] == "com.jonathanreed.Waves"
      %w[version build minimumMacOSVersion].each do |key|
        metadata_key = key == "minimumMacOSVersion" ? key : key
        raise Error, "package #{key} does not match release metadata" unless package[key] == metadata[metadata_key]
      end
      raise Error, "package architectures must be exactly arm64 and x86_64" unless package["architectures"].is_a?(Array) && package["architectures"].sort == %w[arm64 x86_64]
      Validation.exact_keys!(package["hashes"], %w[appExecutable dmg dSYM], "package hashes")
      package["hashes"].each { |name, digest| Validation.sha256!(digest, "package hash #{name}") }
      Validation.exact_keys!(package["developerID"], %w[status identity], "package developerID")
      raise Error, "package Developer ID signature must have passed" unless package["developerID"]["status"] == "passed"
      Validation.nonempty_string!(package["developerID"]["identity"], "package developerID.identity")
      %w[hardenedRuntime notarization stapling gatekeeper].each do |name|
        Validation.passed_result!(package[name], "package.#{name}")
      end
    end

    def validate_gates!(gates, profile)
      Validation.exact_keys!(gates, REQUIRED_GATES, "gate evidence")
      (REQUIRED_GATES - ["remoteElgato"]).each do |name|
        Validation.passed_result!(gates[name], "gates.#{name}")
      end
      allowed_remote = profile == "candidate" ? %w[pending passed] : ["passed"]
      Validation.passed_result!(gates["remoteElgato"], "gates.remoteElgato", allowed_statuses: allowed_remote)
      if profile == "publication" && gates["remoteElgato"]["status"] != "passed"
        raise Error, "gates.remoteElgato must pass before publication"
      end
    end

    def validate_skip_data!(manifest)
      skipped = manifest["skippedGates"]
      raise Error, "skippedGates must be an array" unless skipped.is_a?(Array)
      raise Error, "candidate or publication evidence cannot contain skipped gates" unless skipped.empty?

      equivalent = manifest["skipCIEquivalentEvidence"]
      raise Error, "skipCIEquivalentEvidence must be an array" unless equivalent.is_a?(Array)
      equivalent.each_with_index do |entry, index|
        Validation.exact_keys!(entry, %w[commit status qualityGate], "skipCIEquivalentEvidence[#{index}]")
        Validation.revision!(entry["commit"], "skipCIEquivalentEvidence[#{index}].commit")
        raise Error, "skipCIEquivalentEvidence[#{index}] must record a passed full quality gate" unless entry["status"] == "passed" && entry["qualityGate"] == "full"
      end
    end
  end

  module TagEnvelope
    HEADER = "WAVES-RELEASE-EVIDENCE-V1"
    START = "-----BEGIN WAVES RELEASE EVIDENCE-----"
    FINISH = "-----END WAVES RELEASE EVIDENCE-----"
    DIGEST_PREFIX = "SHA256: "

    module_function

    def build(json:, digest:)
      Validation.sha256!(digest, "tag envelope digest")
      raise Error, "tag envelope digest does not match canonical JSON" unless digest == CanonicalJSON.sha256(json)

      "#{HEADER}\n#{START}\n#{json}#{FINISH}\n#{DIGEST_PREFIX}#{digest}\n"
    end

    def parse(contents)
      pattern = /\A#{Regexp.escape(HEADER)}\n#{Regexp.escape(START)}\n(.*)#{Regexp.escape(FINISH)}\n#{Regexp.escape(DIGEST_PREFIX)}([0-9a-f]{64})\n?\z/m
      match = contents.match(pattern)
      raise Error, "annotated tag does not contain the Waves evidence envelope" unless match

      json = match[1]
      digest = match[2]
      raise Error, "tag evidence SHA-256 does not match the embedded manifest" unless digest == CanonicalJSON.sha256(json)
      manifest = StrictJSON.parse(json, context: "annotated tag evidence")
      raise Error, "tag evidence JSON is not canonical" unless CanonicalJSON.generate(manifest) == json

      {"manifest" => manifest, "digest" => digest}
    end
  end

  module ArtifactEvidence
    module_function

    def default_paths(root)
      {
        "appExecutable" => File.join(root, "dist/Waves.app/Contents/MacOS/Waves"),
        "dmg" => File.join(root, "dist/Waves.dmg"),
        "dSYM" => File.join(root, "dist/Waves.app.dSYM/Contents/Resources/DWARF/Waves"),
      }
    end

    def verify_hashes!(manifest:, paths:)
      expected = manifest.dig("package", "hashes")
      Validation.exact_keys!(expected, %w[appExecutable dmg dSYM], "package hashes")
      Validation.exact_keys!(paths, %w[appExecutable dmg dSYM], "artifact paths")
      paths.each do |name, path|
        raise Error, "#{name} artifact not found at #{path}" unless File.file?(path)
        actual = Digest::SHA256.file(path).hexdigest
        unless actual == expected[name]
          raise Error, "#{name} SHA-256 #{actual} does not match sealed evidence #{expected[name]}"
        end
      end
      true
    end
  end

  module GitContract
    module_function

    def clean_exact_revision!(root:, expected_revision:)
      Validation.revision!(expected_revision, "expected revision")
      actual = Validation.run("git", "rev-parse", "HEAD", chdir: root).strip
      raise Error, "repository revision #{actual} does not match expected revision #{expected_revision}" unless actual == expected_revision
      dirty = Validation.run("git", "status", "--porcelain", "--untracked-files=no", chdir: root)
      raise Error, "release gate requires a clean tracked tree" unless dirty.empty?

      actual
    end
  end

  module History
    SKIP_PATTERN = /\[(?:skip ci|ci skip|skip actions|actions skip)\]/i
    PRODUCT_PATH = %r{\A(?:
      Sources/|Tests/|script/|\.github/|release/|Casks/|Package\.swift\z|Package\.resolved\z|
      CHANGELOG\.md\z|1\.5-update-plan\.md\z|docs/(?:RELEASE|PRODUCT|DESIGN|STREAM-DECK)\.md\z
    )}x

    module_function

    def validate!(repo:, from_revision:, to_revision:, manifest: nil)
      commits = Validation.run("git", "rev-list", "--reverse", "#{from_revision}..#{to_revision}", chdir: repo).lines.map(&:strip)
      equivalents = Array(manifest && manifest["skipCIEquivalentEvidence"])
      commits.each do |commit|
        subject = Validation.run("git", "log", "-1", "--format=%s", commit, chdir: repo).strip
        next unless subject.match?(SKIP_PATTERN)

        paths = Validation.run("git", "diff-tree", "--no-commit-id", "--name-only", "-r", commit, chdir: repo).lines.map(&:strip)
        next unless paths.any? { |path| path.match?(PRODUCT_PATH) }

        equivalent = equivalents.find do |entry|
          entry["commit"] == commit && entry["status"] == "passed" && entry["qualityGate"] == "full"
        end
        next if equivalent

        raise Error, "source-changing skip commit #{commit} lacks exact equivalent local quality-gate evidence"
      end
      true
    end
  end

  module RepositoryContract
    PLACEHOLDER = "RELEASE_WORKFLOW_REPLACES_THIS_SHA256"

    module_function

    def validate!(root:, metadata:)
      changelog = read(root, "CHANGELOG.md")
      heading = /^## \[#{Regexp.escape(metadata['version'])}\](?: - \d{4}-\d{2}-\d{2})?$/
      raise Error, "CHANGELOG.md must contain exactly one #{metadata['version']} release heading" unless changelog.lines.grep(heading).length == 1

      cask = read(root, "Casks/waves.rb")
      versions = cask.scan(/^\s*version\s+"([^"]+)"\s*$/).flatten
      raise Error, "Casks/waves.rb must declare exactly version #{metadata['version']}" unless versions == [metadata["version"]]
      checksums = cask.scan(/^\s*sha256\s+"([^"]+)"\s*$/).flatten
      raise Error, "Casks/waves.rb must contain the invalid checksum placeholder exactly once" unless checksums == [PLACEHOLDER]
      raise Error, "Casks/waves.rb must not use sha256 :no_check" if cask.include?("sha256 :no_check")

      package = read(root, "Package.swift")
      expected_floor = %(.macOS("#{metadata['minimumMacOSVersion']}"))
      raise Error, "Package.swift deployment floor does not match canonical metadata" unless package.include?(expected_floor)

      %w[script/build_and_run.sh script/make_appcast.sh].each do |relative|
        script = read(root, relative)
        unless script.include?("release_tool.rb") && script.include?("metadata")
          raise Error, "#{relative} must consume canonical metadata through release_tool.rb"
        end
        if script.match?(/APP_VERSION="\$\{APP_VERSION:-\d/) || script.match?(/APP_BUILD="\$\{APP_BUILD:-\d/)
          raise Error, "#{relative} contains a default outside canonical metadata"
        end
      end

      workflows = %w[.github/workflows/ci.yml .github/workflows/release.yml].map { |path| read(root, path) }.join("\n")
      if workflows.match?(/\bRELEASE_BUILD\b/) || workflows.match?(/\bAPP_(?:VERSION|BUILD)\b/)
        raise Error, "workflow contains duplicated release metadata"
      end
      true
    end

    def read(root, relative)
      path = File.join(root, relative)
      raise Error, "required release contract file not found at #{path}" unless File.file?(path)

      File.read(path)
    end
  end

  module WorkflowContract
    ACTIONS = {
      "actions/checkout" => "3d3c42e5aac5ba805825da76410c181273ba90b1",
      "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
      "actions/download-artifact" => "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
      "softprops/action-gh-release" => "3d0d9888cb7fd7b750713d6e236d1fcb99157228",
    }.freeze

    module_function

    def validate!(root:)
      ci_path = File.join(root, ".github/workflows/ci.yml")
      release_path = File.join(root, ".github/workflows/release.yml")
      ci = parse(ci_path)
      release = parse(release_path)
      ci_source = File.read(ci_path)
      release_source = File.read(release_path)

      on_ci = trigger(ci)
      raise Error, "CI workflow must run for pull requests and pushes to main" unless on_ci.is_a?(Hash) && on_ci.key?("pull_request") && on_ci.key?("push")
      permissions_read!(ci, "CI workflow")
      concurrency!(ci, cancel: true, context: "CI workflow")
      jobs_with_timeouts!(ci, "CI workflow")
      raise Error, "CI workflow bypasses the shared quality-gate" unless ci_source.include?("./script/quality-gate.sh full")
      raise Error, "CI artifact retention must be 14 days" unless ci_source.match?(/retention-days:\s*14\b/)

      on_release = trigger(release)
      unless on_release.is_a?(Hash) && on_release.keys == ["workflow_dispatch"]
        raise Error, "release workflow must remain manual-only"
      end
      permissions_read!(release, "release workflow")
      concurrency!(release, cancel: false, context: "release workflow")
      jobs_with_timeouts!(release, "release workflow")
      validate_release_job_permissions!(release)
      raise Error, "release workflow must call the shared quality-gate" unless release_source.include?("./script/quality-gate.sh full")
      raise Error, "release workflow must call the candidate release-gate" unless release_source.include?("./script/release-gate.sh candidate")
      raise Error, "release workflow must call the publication release-gate" unless release_source.include?("./script/release-gate.sh publication")
      raise Error, "release artifact retention must be 14 days" unless release_source.match?(/retention-days:\s*14\b/)

      validate_action_pins!(ci_source, "CI workflow")
      validate_action_pins!(release_source, "release workflow")
      if [ci_source, release_source].any? { |source| source.match?(/\bRELEASE_BUILD\b|\bAPP_(?:VERSION|BUILD)\b/) }
        raise Error, "workflow contains duplicated version or build metadata"
      end
      true
    end

    def parse(path)
      raise Error, "workflow not found at #{path}" unless File.file?(path)

      value = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
      Validation.hash!(value, path)
    rescue Psych::SyntaxError => error
      raise Error, "workflow YAML is malformed at #{path}: #{error.message}"
    end

    def trigger(workflow)
      workflow["on"] || workflow[true]
    end

    def permissions_read!(workflow, context)
      permissions = workflow["permissions"]
      unless permissions.is_a?(Hash) && permissions["contents"] == "read"
        raise Error, "#{context} must declare top-level contents: read"
      end
    end

    def concurrency!(workflow, cancel:, context:)
      concurrency = workflow["concurrency"]
      unless concurrency.is_a?(Hash) && concurrency["group"].is_a?(String) && !concurrency["group"].empty? && concurrency["cancel-in-progress"] == cancel
        raise Error, "#{context} concurrency contract is missing or unsafe"
      end
    end

    def jobs_with_timeouts!(workflow, context)
      jobs = workflow["jobs"]
      raise Error, "#{context} must define jobs" unless jobs.is_a?(Hash) && !jobs.empty?
      missing = jobs.each_with_object([]) do |(name, job), result|
        unless job.is_a?(Hash) && job["timeout-minutes"].is_a?(Integer) && job["timeout-minutes"].positive?
          result << name
        end
      end
      raise Error, "#{context} job timeout is missing for #{missing.join(', ')}" unless missing.empty?
    end

    def validate_release_job_permissions!(workflow)
      jobs = workflow.fetch("jobs")
      raise Error, "release workflow must define draft-publication job" unless jobs.key?("draft-publication")
      jobs.each do |name, job|
        contents = job.is_a?(Hash) && job["permissions"].is_a?(Hash) ? job["permissions"]["contents"] : nil
        expected = name == "draft-publication" ? "write" : "read"
        raise Error, "release job #{name} must use contents: #{expected}" unless contents == expected
      end
    end

    def validate_action_pins!(source, context)
      source.scan(/^\s*-?\s*uses:\s*([^@\s]+)@([^\s#]+)/).each do |name, revision|
        raise Error, "#{context} action #{name} must be pinned to a full commit SHA" unless revision.match?(/\A[0-9a-f]{40}\z/)
        expected = ACTIONS[name]
        raise Error, "#{context} action #{name} uses an unverified commit" if expected && revision != expected
      end
    end
  end

  module PublicationTag
    module_function

    def validate!(root:, tag:, metadata:)
      expected_tag = "v#{metadata['version']}"
      raise Error, "publication tag must be exactly #{expected_tag}" unless tag == expected_tag
      type = Validation.run("git", "cat-file", "-t", "refs/tags/#{tag}", chdir: root).strip
      raise Error, "publication tag #{tag} must be annotated, not lightweight" unless type == "tag"
      tag_revision = Validation.run("git", "rev-list", "-n", "1", tag, chdir: root).strip
      head_revision = Validation.run("git", "rev-parse", "HEAD", chdir: root).strip
      raise Error, "publication tag #{tag} does not name HEAD" unless tag_revision == head_revision
      origin_main = Validation.run("git", "rev-parse", "refs/remotes/origin/main", chdir: root).strip
      raise Error, "publication tag #{tag} does not name exact origin/main" unless tag_revision == origin_main
      annotation = Validation.run("git", "for-each-ref", "refs/tags/#{tag}", "--format=%(contents)", chdir: root)
      annotation = annotation.sub(/\n+\z/, "\n")
      parsed = TagEnvelope.parse(annotation)
      Evidence.validate!(
        parsed.fetch("manifest"),
        metadata: metadata,
        profile: "publication",
        expected_revision: tag_revision
      )
      parsed
    end
  end

  module CLI
    module_function

    def run(arguments)
      root = File.expand_path("..", __dir__)
      metadata_path = ENV.fetch("WAVES_RELEASE_METADATA", File.join(root, "release/metadata.json"))
      command = arguments.shift
      case command
      when "metadata"
        metadata = Metadata.load(metadata_path)
        field = arguments.shift
        if field.nil? || field == "validate"
          puts CanonicalJSON.generate(metadata)
        elsif metadata.key?(field)
          puts metadata.fetch(field)
        else
          raise Error, "unknown metadata field #{field.inspect}"
        end
      when "validate-repository"
        metadata = Metadata.load(metadata_path)
        RepositoryContract.validate!(root: root, metadata: metadata)
        puts "Release repository contract is valid."
      when "validate-workflows"
        WorkflowContract.validate!(root: root)
        puts "Repository workflow contracts are valid."
      when "evidence"
        evidence_command = arguments.shift
        metadata = Metadata.load(metadata_path)
        case evidence_command
        when "seal"
          profile, input_path, output_path = arguments
          raise Error, "usage: release_tool.rb evidence seal PROFILE INPUT OUTPUT" unless output_path
          input = StrictJSON.load(input_path)
          Evidence.write!(input: input, metadata: metadata, profile: profile, output: output_path)
          puts "Sealed #{profile} evidence at #{output_path}."
        when "validate"
          profile, manifest_path, expected_revision = arguments
          raise Error, "usage: release_tool.rb evidence validate PROFILE MANIFEST [REVISION]" unless manifest_path
          Evidence.verify_file!(
            path: manifest_path,
            digest_path: "#{manifest_path}.sha256",
            metadata: metadata,
            profile: profile,
            expected_revision: expected_revision
          )
          puts "Validated #{profile} evidence at #{manifest_path}."
        else
          raise Error, "unknown evidence command #{evidence_command.inspect}"
        end
      when "tag-envelope"
        manifest_path, output_path = arguments
        raise Error, "usage: release_tool.rb tag-envelope MANIFEST OUTPUT" unless output_path
        json = File.read(manifest_path)
        manifest = StrictJSON.parse(json, context: manifest_path)
        raise Error, "evidence manifest is not canonical JSON" unless CanonicalJSON.generate(manifest) == json
        digest_sidecar = File.read("#{manifest_path}.sha256")
        digest = digest_sidecar[/\A([0-9a-f]{64})/, 1]
        raise Error, "evidence SHA-256 sidecar is malformed" unless digest
        File.write(output_path, TagEnvelope.build(json: json, digest: digest))
        puts "Wrote annotated-tag evidence envelope to #{output_path}."
      when "history"
        from_revision, to_revision, manifest_path = arguments
        raise Error, "usage: release_tool.rb history FROM TO [MANIFEST]" unless to_revision
        manifest = manifest_path ? StrictJSON.load(manifest_path) : nil
        History.validate!(repo: root, from_revision: from_revision, to_revision: to_revision, manifest: manifest)
        puts "Release source history policy passed for #{from_revision}..#{to_revision}."
      when "publication-tag"
        tag = arguments.shift
        raise Error, "usage: release_tool.rb publication-tag TAG [OUTPUT_MANIFEST]" unless tag
        metadata = Metadata.load(metadata_path)
        parsed = PublicationTag.validate!(root: root, tag: tag, metadata: metadata)
        if (output = arguments.shift)
          File.write(output, CanonicalJSON.generate(parsed.fetch("manifest")))
          File.write("#{output}.sha256", "#{parsed.fetch('digest')}  #{File.basename(output)}\n")
        end
        puts "Annotated publication tag #{tag} carries valid exact-revision evidence."
      when "verify-artifacts"
        manifest_path = arguments.shift
        raise Error, "usage: release_tool.rb verify-artifacts MANIFEST" unless manifest_path
        manifest = StrictJSON.load(manifest_path)
        ArtifactEvidence.verify_hashes!(manifest: manifest, paths: ArtifactEvidence.default_paths(root))
        puts "Signed candidate artifact hashes match sealed evidence."
      else
        raise Error, "usage: release_tool.rb metadata|validate-repository|validate-workflows|evidence|tag-envelope|history|publication-tag|verify-artifacts"
      end
    rescue Error => error
      warn "Error: #{error.message}"
      1
    end
  end
end

exit(WavesRelease::CLI.run(ARGV) || 0) if $PROGRAM_NAME == __FILE__
