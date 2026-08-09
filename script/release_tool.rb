#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "base64"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tempfile"
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
      options = {}
      options[:chdir] = chdir if chdir
      options[:stdin_data] = stdin_data if stdin_data
      stdout, stderr, status = Open3.capture3(*command, **options)
      return [stdout, stderr, status] if allow_failure
      raise Error, "#{command.join(' ')} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def run_combined(*command, chdir: nil)
      options = {}
      options[:chdir] = chdir if chdir
      stdout, stderr, status = Open3.capture3(*command, **options)
      combined = "#{stdout}#{stderr}"
      raise Error, "#{command.join(' ')} failed: #{combined.strip}" unless status.success?

      combined
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
    KEYS = %w[
      schemaVersion version build minimumMacOSVersion bundleIdentifier developerID
      releaseAuthority sparkle
    ].freeze
    DEVELOPER_ID_KEYS = %w[identity teamIdentifier designatedRequirement].freeze
    RELEASE_AUTHORITY_KEYS = %w[principal publicKey fingerprint receiptIssuers].freeze
    RECEIPT_ISSUER_KEYS = %w[securityScan remoteElgato].freeze
    SPARKLE_KEYS = %w[keychainAccount publicEDKey].freeze

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

      bundle_identifier = value["bundleIdentifier"]
      unless bundle_identifier == "com.jonathanreed.Waves"
        raise Error, "release metadata bundleIdentifier must be com.jonathanreed.Waves"
      end

      developer_id = value["developerID"]
      Validation.exact_keys!(developer_id, DEVELOPER_ID_KEYS, "release metadata developerID")
      developer_id.each do |key, field|
        Validation.nonempty_string!(field, "release metadata developerID.#{key}")
      end
      identity = developer_id["identity"]
      team = developer_id["teamIdentifier"]
      unless identity == "Developer ID Application: Jonathan Reed (AJ9VWBRNZN)"
        raise Error, "release metadata Developer ID identity is not the expected Waves identity"
      end
      unless team == "AJ9VWBRNZN"
        raise Error, "release metadata Developer ID teamIdentifier must be AJ9VWBRNZN"
      end
      unless developer_id["designatedRequirement"].include?(%Q(identifier "#{bundle_identifier}")) &&
          developer_id["designatedRequirement"].include?("certificate leaf[subject.OU] = #{team}")
        raise Error, "release metadata Developer ID designatedRequirement must bind the Waves identifier and team"
      end

      authority = value["releaseAuthority"]
      Validation.exact_keys!(authority, RELEASE_AUTHORITY_KEYS, "release metadata releaseAuthority")
      %w[principal publicKey fingerprint].each do |field|
        Validation.nonempty_string!(authority[field], "release metadata releaseAuthority.#{field}")
      end
      key_parts = authority["publicKey"].split
      unless key_parts.length.between?(2, 3) && key_parts[0] == "ssh-ed25519"
        raise Error, "release metadata releaseAuthority.publicKey must be an inline ssh-ed25519 public key"
      end
      begin
        key_blob = Base64.strict_decode64(key_parts[1])
      rescue ArgumentError
        raise Error, "release metadata releaseAuthority.publicKey is malformed"
      end
      derived_fingerprint = "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(key_blob)).delete('=')}"
      unless authority["fingerprint"] == derived_fingerprint
        raise Error, "release metadata releaseAuthority fingerprint does not match the pinned public key"
      end
      issuers = authority["receiptIssuers"]
      Validation.exact_keys!(issuers, RECEIPT_ISSUER_KEYS, "release metadata receipt issuers")
      issuers.each do |name, issuer|
        Validation.nonempty_string!(issuer, "release metadata receiptIssuers.#{name}")
      end

      sparkle = value["sparkle"]
      Validation.exact_keys!(sparkle, SPARKLE_KEYS, "release metadata sparkle")
      Validation.nonempty_string!(sparkle["keychainAccount"], "release metadata sparkle.keychainAccount")
      raise Error, "release metadata Sparkle account must be Waves-specific" unless sparkle["keychainAccount"] == bundle_identifier
      begin
        public_key_bytes = Base64.strict_decode64(sparkle["publicEDKey"])
      rescue ArgumentError
        raise Error, "release metadata sparkle.publicEDKey must be canonical base64"
      end
      unless public_key_bytes.bytesize == 32 && Base64.strict_encode64(public_key_bytes) == sparkle["publicEDKey"]
        raise Error, "release metadata sparkle.publicEDKey must encode exactly 32 bytes"
      end

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
      skipCIEquivalentEvidence externalReceipts publicationEligible
    ].freeze
    MANIFEST_KEYS = %w[
      schemaVersion sealProfile release source toolchain tests performance platforms
      package gates skippedGates skipCIEquivalentEvidence externalReceipts publicationEligible
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
      validate_external_receipts!(manifest, metadata: metadata, profile: profile)
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
      Validation.exact_keys!(
        source,
        %w[revision trackedDirty untrackedBuildInputs sourceArchiveSHA256 buildRecipeSHA256],
        "source evidence"
      )
      Validation.revision!(source["revision"])
      raise Error, "source evidence trackedDirty must be false" unless source["trackedDirty"] == false
      unless source["untrackedBuildInputs"] == false
        raise Error, "source evidence untrackedBuildInputs must be false"
      end
      Validation.sha256!(source["sourceArchiveSHA256"], "source archive SHA-256")
      Validation.sha256!(source["buildRecipeSHA256"], "build recipe SHA-256")
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
      raise Error, "package bundle identifier does not match release metadata" unless package["bundleIdentifier"] == metadata["bundleIdentifier"]
      %w[version build minimumMacOSVersion].each do |key|
        metadata_key = key == "minimumMacOSVersion" ? key : key
        raise Error, "package #{key} does not match release metadata" unless package[key] == metadata[metadata_key]
      end
      raise Error, "package architectures must be exactly arm64 and x86_64" unless package["architectures"].is_a?(Array) && package["architectures"].sort == %w[arm64 x86_64]
      Validation.exact_keys!(package["hashes"], %w[appExecutable dmg dSYM], "package hashes")
      package["hashes"].each { |name, digest| Validation.sha256!(digest, "package hash #{name}") }
      Validation.exact_keys!(
        package["developerID"],
        %w[status identity teamIdentifier designatedRequirement],
        "package developerID"
      )
      raise Error, "package Developer ID signature must have passed" unless package["developerID"]["status"] == "passed"
      expected_developer_id = metadata.fetch("developerID")
      %w[identity teamIdentifier designatedRequirement].each do |field|
        unless package["developerID"][field] == expected_developer_id[field]
          raise Error, "package Developer ID #{field} does not match the expected Waves release identity"
        end
      end
      %w[hardenedRuntime stapling gatekeeper].each do |name|
        Validation.passed_result!(package[name], "package.#{name}")
      end
      notarization = package["notarization"]
      Validation.exact_keys!(
        notarization,
        %w[status submissionID detail artifactSHA256 logSHA256],
        "package.notarization"
      )
      raise Error, "package.notarization status must be passed" unless notarization["status"] == "passed"
      unless notarization["submissionID"].is_a?(String) && notarization["submissionID"].match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
        raise Error, "package.notarization.submissionID must be an Apple notarization UUID"
      end
      Validation.nonempty_string!(notarization["detail"], "package.notarization.detail")
      Validation.sha256!(notarization["artifactSHA256"], "package.notarization artifact SHA-256")
      Validation.sha256!(notarization["logSHA256"], "package.notarization log SHA-256")
      unless notarization["artifactSHA256"] == package.fetch("hashes").fetch("dmg")
        raise Error, "package notarization receipt is not bound to the sealed DMG"
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

    def validate_external_receipts!(manifest, metadata:, profile:)
      receipts = manifest["externalReceipts"]
      required = ["securityScan"]
      required << "remoteElgato" if profile == "publication"
      allowed = %w[securityScan remoteElgato]
      Validation.hash!(receipts, "external receipt evidence")
      unknown = receipts.keys - allowed
      missing = required - receipts.keys
      raise Error, "external receipt evidence has unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      raise Error, "external receipt evidence is missing receipt(s): #{missing.join(', ')}" unless missing.empty?

      source_revision = manifest.fetch("source").fetch("revision")
      dmg_hash = manifest.fetch("package").fetch("hashes").fetch("dmg")
      issuers = metadata.fetch("releaseAuthority").fetch("receiptIssuers")
      receipts.each do |name, receipt|
        Validation.exact_keys!(
          receipt,
          %w[issuer sourceRevision artifactSHA256 receiptSHA256],
          "external receipt #{name}"
        )
        unless receipt["issuer"] == issuers.fetch(name)
          raise Error, "external receipt #{name} issuer does not match canonical release authority"
        end
        Validation.revision!(receipt["sourceRevision"], "external receipt #{name} source revision")
        Validation.sha256!(receipt["artifactSHA256"], "external receipt #{name} artifact SHA-256")
        Validation.sha256!(receipt["receiptSHA256"], "external receipt #{name} receipt SHA-256")
        unless receipt["sourceRevision"] == source_revision
          raise Error, "external receipt #{name} is not bound to the sealed source revision"
        end
        unless receipt["artifactSHA256"] == dmg_hash
          raise Error, "external receipt #{name} is not bound to the sealed DMG"
        end
      end
      true
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

    def verify_identity_facts!(manifest:, metadata:, facts:)
      keys = %w[
        bundleIdentifier version build minimumMacOSVersion sourceRevision
        sourceArchiveSHA256 buildRecipeSHA256 developerID hardenedRuntime
        notarizedDeveloperID stapling gatekeeper
      ]
      Validation.exact_keys!(facts, keys, "derived artifact facts")
      package = manifest.fetch("package")
      source = manifest.fetch("source")

      {
        "bundleIdentifier" => metadata.fetch("bundleIdentifier"),
        "version" => metadata.fetch("version"),
        "build" => metadata.fetch("build"),
        "minimumMacOSVersion" => metadata.fetch("minimumMacOSVersion"),
      }.each do |field, expected|
        unless facts[field].to_s == expected.to_s && package[field].to_s == expected.to_s
          raise Error, "derived artifact #{field} does not match metadata and sealed evidence"
        end
      end

      {
        "sourceRevision" => ["revision", "source revision"],
        "sourceArchiveSHA256" => ["sourceArchiveSHA256", "source archive"],
        "buildRecipeSHA256" => ["buildRecipeSHA256", "build recipe"],
      }.each do |fact_field, (source_field, label)|
        unless facts[fact_field] == source.fetch(source_field)
          raise Error, "derived artifact #{label} does not match sealed evidence"
        end
      end

      Validation.exact_keys!(facts["developerID"], Metadata::DEVELOPER_ID_KEYS, "derived Developer ID")
      expected_developer_id = metadata.fetch("developerID")
      Metadata::DEVELOPER_ID_KEYS.each do |field|
        unless facts["developerID"][field] == expected_developer_id[field] &&
            package.fetch("developerID")[field] == expected_developer_id[field]
          raise Error, "derived Developer ID #{field} does not match metadata and sealed evidence"
        end
      end

      %w[hardenedRuntime notarizedDeveloperID stapling gatekeeper].each do |field|
        raise Error, "derived artifact #{field} must be true" unless facts[field] == true
      end
      true
    end

    def verify_exact_source_identity!(manifest:, exact_identity:, artifact_facts:)
      source = manifest.fetch("source")
      Validation.exact_keys!(
        exact_identity,
        %w[revision trackedDirty untrackedBuildInputs sourceArchiveSHA256 buildRecipeSHA256],
        "exact-tag source identity"
      )
      unless exact_identity["trackedDirty"] == false && exact_identity["untrackedBuildInputs"] == false
        raise Error, "exact-tag source identity must describe a clean source with no untracked build inputs"
      end

      {
        "revision" => ["sourceRevision", "source revision"],
        "sourceArchiveSHA256" => ["sourceArchiveSHA256", "source archive"],
        "buildRecipeSHA256" => ["buildRecipeSHA256", "build recipe"],
      }.each do |source_field, (artifact_field, label)|
        exact = exact_identity.fetch(source_field)
        unless exact == source.fetch(source_field)
          raise Error, "exact-tag #{label} does not match sealed evidence"
        end
        unless exact == artifact_facts.fetch(artifact_field)
          raise Error, "exact-tag #{label} does not match authenticated artifact metadata"
        end
      end
      true
    end

    def verify_release_artifacts!(manifest:, metadata:, app:, dmg:, dsym:, exact_source_identity:)
      executable = File.join(app, "Contents/MacOS/Waves")
      verify_hashes!(
        manifest: manifest,
        paths: {"appExecutable" => executable, "dmg" => dmg, "dSYM" => dsym}
      )

      info_plist = File.join(app, "Contents/Info.plist")
      raise Error, "release app Info.plist not found at #{info_plist}" unless File.file?(info_plist)

      app_signature = signing_details!(app)
      dmg_signature = signing_details!(dmg, require_designated_requirement: false)
      expected_developer_id = metadata.fetch("developerID")
      %w[identity teamIdentifier].each do |field|
        unless dmg_signature[field] == expected_developer_id[field]
          raise Error, "DMG Developer ID #{field} does not match the expected Waves release identity"
        end
      end

      Validation.run_combined("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
      Validation.run_combined("/usr/bin/codesign", "--verify", "--strict", dmg)
      app_gatekeeper = Validation.run_combined("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=4", app)
      dmg_gatekeeper = Validation.run_combined(
        "/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
        "--verbose=4", dmg
      )
      Validation.run_combined("/usr/bin/xcrun", "stapler", "validate", dmg)

      facts = {
        "bundleIdentifier" => plist_value!(info_plist, "CFBundleIdentifier"),
        "version" => plist_value!(info_plist, "CFBundleShortVersionString"),
        "build" => plist_value!(info_plist, "CFBundleVersion"),
        "minimumMacOSVersion" => plist_value!(info_plist, "LSMinimumSystemVersion"),
        "sourceRevision" => plist_value!(info_plist, "WavesSourceRevision"),
        "sourceArchiveSHA256" => plist_value!(info_plist, "WavesSourceArchiveSHA256"),
        "buildRecipeSHA256" => plist_value!(info_plist, "WavesBuildRecipeSHA256"),
        "developerID" => app_signature.slice(*Metadata::DEVELOPER_ID_KEYS),
        "hardenedRuntime" => app_signature.fetch("hardenedRuntime"),
        "notarizedDeveloperID" =>
          app_gatekeeper.include?("source=Notarized Developer ID") &&
            dmg_gatekeeper.include?("source=Notarized Developer ID"),
        "stapling" => true,
        "gatekeeper" => true,
      }
      verify_identity_facts!(manifest: manifest, metadata: metadata, facts: facts)
      verify_exact_source_identity!(
        manifest: manifest,
        exact_identity: exact_source_identity,
        artifact_facts: facts
      )
    end

    def signing_details!(path, require_designated_requirement: true)
      details = Validation.run_combined("/usr/bin/codesign", "-dvvv", path)
      authority = details.lines.filter_map { |line| line.chomp[/\AAuthority=(.+)\z/, 1] }.first
      team = details.lines.filter_map { |line| line.chomp[/\ATeamIdentifier=(.+)\z/, 1] }.first
      identity = authority&.strip
      unless identity && team
        raise Error, "could not derive Developer ID identity and teamIdentifier from #{path}"
      end

      result = {
        "identity" => identity,
        "teamIdentifier" => team,
        "hardenedRuntime" => details.match?(/^CodeDirectory .*flags=.*\(runtime\)/),
      }
      if require_designated_requirement
        requirement_output = Validation.run_combined("/usr/bin/codesign", "-dr", "-", path)
        requirement = requirement_output.lines.filter_map do |line|
          line.chomp[/\Adesignated => (.+)\z/, 1]
        end.first
        raise Error, "could not derive designated requirement from #{path}" unless requirement

        result["designatedRequirement"] = requirement.strip
      end
      result
    end

    def plist_value!(path, key)
      value = Validation.run("/usr/bin/plutil", "-extract", key, "raw", "-o", "-", path).strip
      Validation.nonempty_string!(value, "#{path} #{key}")
      value
    end
  end

  module SparkleSigningTool
    RELATIVE_PATHS = {
      "sign_update" => "artifacts/sparkle/Sparkle/bin/sign_update",
      "generate_keys" => "artifacts/sparkle/Sparkle/bin/generate_keys",
    }.freeze
    RELATIVE_PATH = RELATIVE_PATHS.fetch("sign_update")

    module_function

    def verify!(scratch_root:, candidate_path:, tool: "sign_update")
      root = File.expand_path(scratch_root)
      relative_path = RELATIVE_PATHS.fetch(tool) { raise Error, "unknown Sparkle tool #{tool.inspect}" }
      expected = File.join(root, relative_path)
      unless File.expand_path(candidate_path) == expected
        raise Error, "#{tool} must come from the expected isolated Sparkle path #{expected}"
      end
      stat = File.lstat(root)
      raise Error, "Sparkle scratch root must be owned by the current user" unless stat.uid == Process.uid
      raise Error, "Sparkle scratch root must have mode 0700" unless (stat.mode & 0o777) == 0o700
      raise Error, "Sparkle #{tool} must not be a symbolic link" if File.symlink?(expected)
      unless File.file?(expected) && File.executable?(expected)
        raise Error, "Sparkle #{tool} is missing or not executable at #{expected}"
      end
      resolved_root = File.realpath(root)
      resolved_expected = File.join(resolved_root, relative_path)
      unless File.realpath(expected) == resolved_expected
        raise Error, "Sparkle #{tool} must resolve inside the exact isolated dependency root"
      end

      expected
    rescue Errno::ENOENT => error
      raise Error, "Sparkle signing tool validation failed: #{error.message}"
    end
  end

  module SparkleKeyBinding
    module_function

    def sign_and_verify!(scratch_root:, artifact:, metadata:, packaged_public_key:)
      sparkle = metadata.fetch("sparkle")
      account = sparkle.fetch("keychainAccount")
      raise Error, "explicit Waves Sparkle account is required" unless account == "com.jonathanreed.Waves"

      sign_update = SparkleSigningTool.verify!(
        scratch_root: scratch_root,
        candidate_path: File.join(scratch_root, SparkleSigningTool::RELATIVE_PATHS.fetch("sign_update")),
        tool: "sign_update"
      )
      generate_keys = SparkleSigningTool.verify!(
        scratch_root: scratch_root,
        candidate_path: File.join(scratch_root, SparkleSigningTool::RELATIVE_PATHS.fetch("generate_keys")),
        tool: "generate_keys"
      )
      derived_public = Validation.run(generate_keys, "--account", account, "-p").strip
      canonical_public = sparkle.fetch("publicEDKey")
      unless derived_public == canonical_public
        raise Error, "Sparkle account public key does not match canonical release metadata"
      end
      unless packaged_public_key == canonical_public
        raise Error, "packaged public key does not match the canonical Sparkle account"
      end

      signature = Validation.run(sign_update, "--account", account, "-p", artifact).strip
      begin
        decoded = Base64.strict_decode64(signature)
      rescue ArgumentError
        raise Error, "Sparkle signer returned an invalid signature encoding"
      end
      unless decoded.bytesize == 64 && Base64.strict_encode64(decoded) == signature
        raise Error, "Sparkle signer returned an invalid signature encoding"
      end
      _stdout, stderr, status = Validation.run(
        sign_update,
        "--account",
        account,
        "--verify",
        artifact,
        signature,
        allow_failure: true
      )
      raise Error, "Sparkle signature verification failed: #{stderr.strip}" unless status.success?

      signature
    end
  end

  module PrivateArtifacts
    module_function

    def capture_identity!(path:)
      stat = File.lstat(path)
      raise Error, "release artifact must not be a symbolic link: #{path}" if stat.symlink?
      unless stat.file? || stat.directory?
        raise Error, "release artifact must be a regular file or directory: #{path}"
      end

      {"path" => File.expand_path(path), "device" => stat.dev, "inode" => stat.ino, "type" => stat.ftype}
    rescue Errno::ENOENT => error
      raise Error, "release artifact identity failed: #{error.message}"
    end

    def with_stable_identity!(path:, identity: nil)
      identity ||= capture_identity!(path: path)
      verify_identity!(path: path, identity: identity)
      result = yield
      verify_identity!(path: path, identity: identity)
      result
    end

    def publish_file!(source: nil, staged_path: nil, destination:)
      staged_path = source || staged_path
      root = File.dirname(destination)
      FileUtils.mkdir_p(root)
      raise Error, "release destination must not be a symbolic link" if File.symlink?(destination)
      source_identity = capture_identity!(path: staged_path)
      raise Error, "published release artifact must be a regular file" unless source_identity["type"] == "file"
      expected = Digest::SHA256.file(staged_path).hexdigest
      temporary = Tempfile.new([".waves-publish-", ".tmp"], root)
      temporary.chmod(0o600)
      begin
        with_stable_identity!(path: staged_path, identity: source_identity) do
          File.open(staged_path, File::RDONLY | File::NOFOLLOW) do |source|
            IO.copy_stream(source, temporary)
          end
        end
        temporary.flush
        temporary.fsync
        actual = Digest::SHA256.file(temporary.path).hexdigest
        raise Error, "finalized release artifact changed during publication" unless actual == expected
        temporary.close
        File.rename(temporary.path, destination)
        final = Digest::SHA256.file(destination).hexdigest
        raise Error, "published release artifact does not match finalized bytes" unless final == expected
      ensure
        temporary.close! if temporary
      end
      expected
    rescue Errno::ELOOP => error
      raise Error, "release artifact must not traverse a symbolic link: #{error.message}"
    end

    def stage_file!(source:, root:, name: File.basename(source))
      validate_private_root!(root)
      identity = capture_identity!(path: source)
      raise Error, "staged release artifact must be a regular file" unless identity["type"] == "file"
      expanded_root = File.expand_path(root)
      destination = File.expand_path(File.join(expanded_root, name))
      unless File.basename(name) == name && File.dirname(destination) == expanded_root
        raise Error, "private staging destination escapes its root"
      end
      raise Error, "private staging destination already exists" if File.exist?(destination) || File.symlink?(destination)
      File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
          with_stable_identity!(path: source, identity: identity) { IO.copy_stream(input, output) }
          output.flush
          output.fsync
        end
      end
      unless Digest::SHA256.file(destination).hexdigest == Digest::SHA256.file(source).hexdigest
        raise Error, "private staged artifact does not match its verified input"
      end
      destination
    rescue Errno::ELOOP => error
      raise Error, "release artifact must not traverse a symbolic link: #{error.message}"
    end

    def stage_directory!(source:, root:, name: File.basename(source))
      validate_private_root!(root)
      identity = capture_identity!(path: source)
      raise Error, "staged release artifact must be a directory" unless identity["type"] == "directory"
      expanded_root = File.expand_path(root)
      destination = File.expand_path(File.join(expanded_root, name))
      unless File.basename(name) == name && File.dirname(destination) == expanded_root
        raise Error, "private staging destination escapes its root"
      end
      raise Error, "private staging destination already exists" if File.exist?(destination) || File.symlink?(destination)
      expected = tree_digest(source)
      with_stable_identity!(path: source, identity: identity) do
        FileUtils.copy_entry(source, destination, true, false, true)
      end
      unless tree_digest(source) == expected && tree_digest(destination) == expected
        raise Error, "private staged artifact changed during verified copy"
      end
      destination
    end

    def stage_release_artifacts!(source_root:, destination_root:)
      validate_private_root!(destination_root)
      raise Error, "release source dist must not be a symbolic link" if File.symlink?(source_root)
      stage_directory!(
        source: File.join(source_root, "Waves.app"),
        root: destination_root,
        name: "Waves.app"
      )
      stage_directory!(
        source: File.join(source_root, "Waves.app.dSYM"),
        root: destination_root,
        name: "Waves.app.dSYM"
      )
      stage_file!(
        source: File.join(source_root, "Waves.dmg"),
        root: destination_root,
        name: "Waves.dmg"
      )
      true
    end

    def publish_directory!(source:, destination:)
      identity = capture_identity!(path: source)
      raise Error, "published release artifact must be a directory" unless identity["type"] == "directory"
      raise Error, "release destination must not be a symbolic link" if File.symlink?(destination)
      parent = File.dirname(destination)
      FileUtils.mkdir_p(parent)
      temporary = Dir.mktmpdir(".waves-publish-", parent)
      staged = File.join(temporary, File.basename(destination))
      expected = tree_digest(source)
      with_stable_identity!(path: source, identity: identity) do
        FileUtils.copy_entry(source, staged, true, false, true)
      end
      raise Error, "finalized release directory changed during publication" unless tree_digest(staged) == expected
      backup = nil
      if File.exist?(destination)
        backup = File.join(parent, ".#{File.basename(destination)}.previous-#{Process.pid}-#{rand(1_000_000)}")
        File.rename(destination, backup)
      end
      File.rename(staged, destination)
      raise Error, "published release directory does not match finalized bytes" unless tree_digest(destination) == expected
      FileUtils.rm_rf(backup) if backup
      expected
    ensure
      FileUtils.rm_rf(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def publish_release_artifacts!(source_root:, destination_root:)
      validate_private_root!(source_root)
      raise Error, "release destination must not be a symbolic link" if File.symlink?(destination_root)
      FileUtils.mkdir_p(destination_root)
      publish_directory!(
        source: File.join(source_root, "Waves.app"),
        destination: File.join(destination_root, "Waves.app")
      )
      publish_directory!(
        source: File.join(source_root, "Waves.app.dSYM"),
        destination: File.join(destination_root, "Waves.app.dSYM")
      )
      publish_file!(
        source: File.join(source_root, "Waves.dmg"),
        destination: File.join(destination_root, "Waves.dmg")
      )
      true
    end

    def validate_private_root!(root)
      stat = File.lstat(root)
      raise Error, "private release root must not be a symbolic link" if stat.symlink?
      raise Error, "private release root must be owned by the current user" unless stat.uid == Process.uid
      raise Error, "private release root must have mode 0700" unless (stat.mode & 0o777) == 0o700
      true
    rescue Errno::ENOENT => error
      raise Error, "private release root is unavailable: #{error.message}"
    end

    def tree_digest(root)
      digest = Digest::SHA256.new
      paths = [root] + Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).reject do |path|
        %w[. ..].include?(File.basename(path))
      end
      paths.sort.each do |path|
        relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
        stat = File.lstat(path)
        digest << relative << "\0" << stat.ftype << "\0" << (stat.mode & 0o7777).to_s(8) << "\0"
        if stat.file?
          digest << Digest::SHA256.file(path).digest
        elsif stat.symlink?
          digest << File.readlink(path)
        end
      end
      digest.hexdigest
    end

    def verify_identity!(path:, identity:)
      current = capture_identity!(path: path)
      raise Error, "release artifact identity changed before sensitive action" unless current == identity

      true
    end
    private_class_method :verify_identity!
  end

  module TrustedToolchain
    module_function

    def validate!(developer_dir:, sdk_path:, swift_path:)
      developer = trusted_realpath!(developer_dir, "developer directory")
      sdk = trusted_realpath!(sdk_path, "SDK")
      swift = trusted_realpath!(swift_path, "Swift compiler")
      accepted = developer == "/Library/Developer/CommandLineTools" ||
        developer.match?(%r{\A/Applications/[^/]+\.app/Contents/Developer\z})
      raise Error, "developer directory is not an accepted Apple toolchain root" unless accepted
      [sdk, swift].each do |path|
        unless path == developer || path.start_with?("#{developer}/")
          raise Error, "toolchain component resolves outside the trusted developer directory"
        end
      end
      {"developerDir" => developer, "sdkPath" => sdk, "swiftPath" => swift}
    end

    def trusted_realpath!(path, label)
      resolved = File.realpath(path)
      current = Pathname.new(resolved)
      loop do
        stat = File.lstat(current.to_s)
        raise Error, "#{label} must be root-owned" unless stat.uid.zero?
        raise Error, "#{label} must not be group or world writable" unless (stat.mode & 0o022).zero?
        break if current.root?

        current = current.parent
      end
      resolved
    rescue Errno::ENOENT => error
      raise Error, "#{label} is unavailable: #{error.message}"
    end
    private_class_method :trusted_realpath!
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

  module ReleaseSource
    BUILD_INPUT_PATHS = %w[
      Package.swift Package.resolved PrivacyInfo.xcprivacy Sources
      script/build_and_run.sh script/release_tool.rb release/metadata.json
    ].freeze
    RECIPE_PATHS = %w[
      Package.swift Package.resolved PrivacyInfo.xcprivacy
      script/build_and_run.sh script/release_tool.rb release/metadata.json
    ].freeze

    module_function

    def identity!(root:, expected_revision:, archive_path: nil)
      GitContract.clean_exact_revision!(root: root, expected_revision: expected_revision)
      reject_untracked_build_inputs!(root)

      archive = if archive_path
                  FileUtils.mkdir_p(File.dirname(archive_path))
                  Validation.run(
                    "git", "archive", "--format=tar", "--output=#{archive_path}", expected_revision,
                    chdir: root
                  )
                  File.binread(archive_path)
                else
                  Validation.run("git", "archive", "--format=tar", expected_revision, chdir: root)
                end
      {
        "revision" => expected_revision,
        "trackedDirty" => false,
        "untrackedBuildInputs" => false,
        "sourceArchiveSHA256" => Digest::SHA256.hexdigest(archive),
        "buildRecipeSHA256" => recipe_digest_from_git(root: root, revision: expected_revision),
      }
    end

    def recipe_digest_from_git(root:, revision:)
      digest = Digest::SHA256.new
      RECIPE_PATHS.each do |path|
        contents = Validation.run("git", "show", "#{revision}:#{path}", chdir: root)
        append_recipe_entry(digest, path, contents)
      end
      digest.hexdigest
    end

    def recipe_digest_from_files(root:)
      digest = Digest::SHA256.new
      RECIPE_PATHS.each do |path|
        full_path = File.join(root, path)
        raise Error, "build recipe file not found at #{full_path}" unless File.file?(full_path)

        append_recipe_entry(digest, path, File.binread(full_path))
      end
      digest.hexdigest
    end

    def reject_untracked_build_inputs!(root)
      untracked = Validation.run(
        "git", "ls-files", "--others", "--exclude-standard", "--", *BUILD_INPUT_PATHS,
        chdir: root
      ).lines.map(&:strip)
      ignored = Validation.run(
        "git", "ls-files", "--others", "--ignored", "--exclude-standard", "--", *BUILD_INPUT_PATHS,
        chdir: root
      ).lines.map(&:strip)
      inputs = (untracked + ignored).reject(&:empty?).uniq.sort
      return if inputs.empty?

      raise Error, "release source contains untracked build input(s): #{inputs.join(', ')}"
    end

    def append_recipe_entry(digest, path, contents)
      digest << path << "\0" << contents.bytesize.to_s << "\0" << contents
    end
  end

  module History
    SKIP_PATTERN = /\[(?:skip ci|ci skip|skip actions|actions skip)\]/i
    ADDITIONAL_PROTECTED_PATH = %r{\A(?:
      Tests/|script/|\.github/|release/|Casks/|
      CHANGELOG\.md\z|1\.5-update-plan\.md\z|docs/(?:RELEASE|PRODUCT|DESIGN|STREAM-DECK)\.md\z
    )}x

    module_function

    def validate!(repo:, from_revision:, to_revision:, manifest: nil)
      commits = Validation.run("git", "rev-list", "--reverse", "#{from_revision}..#{to_revision}", chdir: repo).lines.map(&:strip)
      equivalents = Array(manifest && manifest["skipCIEquivalentEvidence"])
      commits.each do |commit|
        message = Validation.run("git", "log", "-1", "--format=%B", commit, chdir: repo).strip
        next unless message.match?(SKIP_PATTERN)

        paths = Validation.run("git", "diff-tree", "--no-commit-id", "--name-only", "-r", commit, chdir: repo).lines.map(&:strip)
        next unless paths.any? { |path| protected_path?(path) }

        equivalent = equivalents.find do |entry|
          entry["commit"] == commit && entry["status"] == "passed" && entry["qualityGate"] == "full"
        end
        next if equivalent

        raise Error, "source-changing skip commit #{commit} lacks exact equivalent local quality-gate evidence"
      end
      true
    end

    def protected_path?(path)
      ReleaseSource::BUILD_INPUT_PATHS.any? do |input|
        path == input || path.start_with?("#{input}/")
      end || path.match?(ADDITIONAL_PROTECTED_PATH)
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

  module ReleaseScriptContract
    module_function

    def validate!(root:)
      build = read(root, "script/build_and_run.sh")
      appcast = read(root, "script/make_appcast.sh")
      audit = read(root, "script/audit-realtime-callback.sh")

      require_in_order!(
        build,
        [
          'WAVES_RELEASE_OUTPUT_DIR="$ACTIVE_ISOLATION_ROOT/artifacts"',
          'build_app_bundle',
          'publish_finalized_distribution',
        ],
        "distribution artifacts must be finalized in private staging before publication"
      )
      require_in_order!(
        build,
        ["private-stage-release-artifacts", "publication_check()"],
        "existing app, DMG, and dSYM must be staged privately before publication validation"
      )
      raise Error, "distribution build must not target checkout dist" if build.include?('WAVES_RELEASE_OUTPUT_DIR="$checkout_root/dist"')
      %w[/usr/bin/codesign /usr/bin/xcrun /usr/sbin/spctl].each do |tool|
        raise Error, "distribution security action must use trusted absolute tool #{tool}" unless build.include?(tool)
      end
      unless build.include?('/usr/bin/codesign "${args[@]}" --sign')
        raise Error, "distribution signing must use the trusted absolute codesign tool"
      end

      require_in_order!(
        appcast,
        [
          'private-stage-file "$DMG_PATH"',
          '/usr/bin/hdiutil attach "$DMG_PATH"',
          "sparkle-sign-and-verify",
          "private-publish-file",
        ],
        "appcast must stage, verify, sign, and atomically publish in order"
      )
      if appcast.include?('"$SIGN_UPDATE" -p') || !appcast.include?('PACKAGED_SPARKLE_PUBLIC_KEY')
        raise Error, "appcast must bind the exact Sparkle account signature to the packaged public key"
      end
      unless appcast.include?('PATH="/usr/bin:/bin:/usr/sbin:/sbin"') &&
          build.include?('PATH="/usr/bin:/bin:/usr/sbin:/sbin"')
        raise Error, "release scripts must use the minimal trusted system PATH"
      end
      if audit.include?('WAVES_REALTIME_SOURCE:-') || !audit.include?("override is prohibited")
        raise Error, "realtime audit must use only its canonical tracked source"
      end
      true
    end

    def require_in_order!(source, fragments, message)
      offset = 0
      fragments.each do |fragment|
        index = source.index(fragment, offset)
        raise Error, message unless index

        offset = index + fragment.length
      end
    end
    private_class_method :require_in_order!

    def read(root, relative)
      path = File.join(root, relative)
      raise Error, "release security script not found at #{path}" unless File.file?(path)

      File.read(path)
    end
    private_class_method :read
  end

  module WorkflowContract
    REVISION_INPUT_EXPRESSION = "${{ inputs.revision }}"
    REVISION_VALIDATION_SCRIPT = <<~'SHELL'.strip.freeze
      set -euo pipefail
      if [[ ! "$REQUESTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
        echo "::error::revision must be a lowercase 40-character Git revision."
        exit 1
      fi
      test "$(git rev-parse HEAD)" = "$REQUESTED_REVISION"
    SHELL
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
      require_run_step!(ci, "./script/quality-gate.sh full", "CI workflow bypasses the shared quality-gate")
      require_upload_retention!(ci, "CI artifact retention must be 14 days")

      on_release = trigger(release)
      unless on_release.is_a?(Hash) && on_release.keys == ["workflow_dispatch"]
        raise Error, "release workflow must remain manual-only"
      end
      dispatch = on_release["workflow_dispatch"]
      revision_input = dispatch.is_a?(Hash) && dispatch["inputs"].is_a?(Hash) ? dispatch["inputs"]["revision"] : nil
      unless revision_input.is_a?(Hash) && revision_input["required"] == true &&
          !revision_input.key?("default") && [nil, "string"].include?(revision_input["type"])
        raise Error, "release workflow must require an exact revision input"
      end
      permissions_read!(release, "release workflow")
      concurrency!(release, cancel: false, context: "release workflow")
      jobs_with_timeouts!(release, "release workflow")
      validate_release_job_permissions!(release)
      unless release.fetch("jobs").keys == ["verify"]
        raise Error, "hosted release workflow must remain verification-only with no credentialed signing job"
      end
      validate_release_checkouts!(release)
      validate_release_revision_steps!(release)
      require_run_step!(release, "./script/quality-gate.sh full", "release workflow must call the shared quality-gate")
      require_upload_retention!(release, "release artifact retention must be 14 days")
      if release_source.include?("contents: write") || release_source.include?("action-gh-release") || release_source.include?("download-artifact") || release_source.include?("release-gate.sh publication")
        raise Error, "hosted release workflow must remain a read-only candidate builder, not a publication path"
      end
      if release_source.include?("${{ secrets.") ||
          release_source.match?(/\b(?:security import|notarytool store-credentials|--notarize)\b/)
        raise Error, "hosted release workflow must remain verification-only and must not consume signing credentials"
      end

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

    def workflow_steps(workflow, context)
      workflow.fetch("jobs").flat_map do |name, job|
        steps = job.is_a?(Hash) ? job["steps"] : nil
        raise Error, "#{context} job #{name} must define executable steps" unless steps.is_a?(Array) && !steps.empty?

        steps.map.with_index do |step, index|
          raise Error, "#{context} job #{name} step #{index + 1} must be a mapping" unless step.is_a?(Hash)

          step
        end
      end
    end

    def require_run_step!(workflow, command, message)
      matched = workflow_steps(workflow, message).any? do |step|
        step["run"].is_a?(String) && step["run"].strip == command
      end
      raise Error, message unless matched
    end

    def require_upload_retention!(workflow, message)
      uploads = workflow_steps(workflow, message).select do |step|
        step["uses"].is_a?(String) && step["uses"].start_with?("actions/upload-artifact@")
      end
      valid = !uploads.empty? && uploads.all? do |step|
        step["with"].is_a?(Hash) && step["with"]["retention-days"] == 14
      end
      raise Error, message unless valid
    end

    def validate_release_job_permissions!(workflow)
      jobs = workflow.fetch("jobs")
      jobs.each do |name, job|
        contents = job.is_a?(Hash) && job["permissions"].is_a?(Hash) ? job["permissions"]["contents"] : nil
        raise Error, "release job #{name} must remain read-only with contents: read" unless contents == "read"
      end
    end

    def validate_release_checkouts!(workflow)
      expected_action = "actions/checkout@#{ACTIONS.fetch('actions/checkout')}"
      expected_ref = REVISION_INPUT_EXPRESSION
      workflow.fetch("jobs").each do |name, job|
        steps = job.fetch("steps")
        checkouts = steps.select do |step|
          step.is_a?(Hash) && step["uses"].is_a?(String) && step["uses"].start_with?("actions/checkout@")
        end
        raise Error, "release job #{name} must have exactly one checkout step" unless checkouts.length == 1

        checkout = checkouts.fetch(0)
        raise Error, "release job #{name} checkout must use the pinned action" unless checkout["uses"] == expected_action

        inputs = checkout["with"]
        unless inputs.is_a?(Hash) && inputs["ref"] == expected_ref
          raise Error, "release job #{name} checkout ref must be exactly #{expected_ref}"
        end
        unless inputs["fetch-depth"] == 0
          raise Error, "release job #{name} checkout fetch-depth must be 0"
        end
        unless inputs["persist-credentials"] == false
          raise Error, "release job #{name} checkout persist-credentials must be false"
        end
      end
    end

    def validate_release_revision_steps!(workflow)
      jobs = workflow.fetch("jobs")
      verify_steps = release_job_steps!(jobs, "verify")
      validation = verify_steps.find do |step|
        step["run"].is_a?(String) && step["run"].strip == REVISION_VALIDATION_SCRIPT
      end
      validation_env = validation.is_a?(Hash) ? validation["env"] : nil
      unless validation_env.is_a?(Hash) && validation_env["REQUESTED_REVISION"] == REVISION_INPUT_EXPRESSION
        raise Error, "release revision validation must execute against the exact revision input"
      end

      preflight = verify_steps.find do |step|
        step["run"].is_a?(String) && step["run"].strip == "./script/release-gate.sh preflight"
      end
      preflight_env = preflight.is_a?(Hash) ? preflight["env"] : nil
      unless preflight_env.is_a?(Hash) && preflight_env["WAVES_EXPECTED_REVISION"] == REVISION_INPUT_EXPRESSION
        raise Error, "release workflow preflight release-gate must bind the exact revision input"
      end
    end

    def release_job_steps!(jobs, name)
      job = jobs[name]
      steps = job.is_a?(Hash) ? job["steps"] : nil
      raise Error, "release workflow must define the #{name} job steps" unless steps.is_a?(Array) && !steps.empty?

      steps
    end

    def validate_action_pins!(source, context)
      source.scan(/^\s*-?\s*uses:\s*([^@\s]+)@([^\s#]+)/).each do |name, revision|
        raise Error, "#{context} action #{name} must be pinned to a full commit SHA" unless revision.match?(/\A[0-9a-f]{40}\z/)
        expected = ACTIONS[name]
        raise Error, "#{context} action #{name} uses an unverified commit" if expected && revision != expected
      end
    end
  end

  module TagAuthority
    PRINCIPAL = "waves-commit-signing"

    module_function

    def verify!(root:, tag:, authority:)
      Validation.exact_keys!(
        authority,
        %w[principal publicKey fingerprint],
        "release tag authority"
      )
      principal = authority.fetch("principal")
      raise Error, "publication tag principal must be #{PRINCIPAL}" unless principal == PRINCIPAL
      public_key = authority.fetch("publicKey")
      parts = public_key.split
      unless parts.length.between?(2, 3) && parts.first == "ssh-ed25519"
        raise Error, "pinned release key is malformed"
      end
      begin
        fingerprint = "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(Base64.strict_decode64(parts[1]))).delete('=')}"
      rescue ArgumentError
        raise Error, "pinned release key is malformed"
      end
      unless fingerprint == authority.fetch("fingerprint")
        raise Error, "pinned release key fingerprint does not match canonical metadata"
      end

      Tempfile.create("waves-allowed-signers") do |file|
        file.chmod(0o600)
        file.write("#{principal} #{parts.first} #{parts[1]}\n")
        file.flush
        stdout, stderr, status = Validation.run(
          "/usr/bin/git",
          "-c",
          "gpg.format=ssh",
          "-c",
          "gpg.ssh.allowedSignersFile=#{file.path}",
          "verify-tag",
          "--raw",
          tag,
          chdir: root,
          allow_failure: true
        )
        combined = "#{stdout}#{stderr}"
        unless status.success?
          raise Error, "publication tag is not signed by the pinned release key: #{combined.strip}"
        end
        unless combined.include?(principal) && combined.include?(fingerprint)
          raise Error, "publication tag signature did not authenticate the pinned principal and fingerprint"
        end
      end
      {"principal" => principal, "fingerprint" => fingerprint}
    end
  end

  module PublicationTag
    module_function

    def validate!(root:, tag:, metadata:)
      expected_tag = "v#{metadata['version']}"
      raise Error, "publication tag must be exactly #{expected_tag}" unless tag == expected_tag
      type = Validation.run("git", "cat-file", "-t", "refs/tags/#{tag}", chdir: root).strip
      raise Error, "publication tag #{tag} must be annotated, not lightweight" unless type == "tag"
      authority = metadata.fetch("releaseAuthority")
      TagAuthority.verify!(
        root: root,
        tag: tag,
        authority: authority.slice("principal", "publicKey", "fingerprint")
      )
      tag_revision = Validation.run("git", "rev-list", "-n", "1", tag, chdir: root).strip
      head_revision = Validation.run("git", "rev-parse", "HEAD", chdir: root).strip
      raise Error, "publication tag #{tag} does not name HEAD" unless tag_revision == head_revision
      origin_main = Validation.run("git", "rev-parse", "refs/remotes/origin/main", chdir: root).strip
      raise Error, "publication tag #{tag} does not name exact origin/main" unless tag_revision == origin_main
      annotation = Validation.run("git", "for-each-ref", "refs/tags/#{tag}", "--format=%(contents)", chdir: root)
      annotation = annotation.sub(/\n-----BEGIN SSH SIGNATURE-----.*\z/m, "\n")
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
      if ENV.key?("WAVES_RELEASE_METADATA")
        raise Error, "WAVES_RELEASE_METADATA override is prohibited; canonical release metadata is fixed"
      end
      metadata_path = File.join(root, "release/metadata.json")
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
        ReleaseScriptContract.validate!(root: root)
        puts "Release repository contract is valid."
      when "validate-workflows"
        WorkflowContract.validate!(root: root)
        puts "Repository workflow contracts are valid."
      when "source-identity"
        expected_revision, archive_path = arguments
        raise Error, "usage: release_tool.rb source-identity REVISION [ARCHIVE]" unless expected_revision
        identity = ReleaseSource.identity!(
          root: root,
          expected_revision: expected_revision,
          archive_path: archive_path
        )
        puts CanonicalJSON.generate(identity)
      when "build-recipe-digest"
        source_root = arguments.shift || root
        puts ReleaseSource.recipe_digest_from_files(root: source_root)
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
      when "sparkle-signing-tool"
        scratch_root, candidate_path = arguments
        raise Error, "usage: release_tool.rb sparkle-signing-tool SCRATCH_ROOT CANDIDATE" unless candidate_path
        puts SparkleSigningTool.verify!(scratch_root: scratch_root, candidate_path: candidate_path)
      when "sparkle-sign-and-verify"
        scratch_root, artifact, packaged_public_key = arguments
        unless packaged_public_key
          raise Error, "usage: release_tool.rb sparkle-sign-and-verify SCRATCH_ROOT ARTIFACT PACKAGED_PUBLIC_KEY"
        end
        metadata = Metadata.load(metadata_path)
        puts SparkleKeyBinding.sign_and_verify!(
          scratch_root: scratch_root,
          artifact: artifact,
          metadata: metadata,
          packaged_public_key: packaged_public_key
        )
      when "trusted-toolchain"
        developer_dir, sdk_path, swift_path = arguments
        unless swift_path
          raise Error, "usage: release_tool.rb trusted-toolchain DEVELOPER_DIR SDK SWIFT"
        end
        puts CanonicalJSON.generate(
          TrustedToolchain.validate!(
            developer_dir: developer_dir,
            sdk_path: sdk_path,
            swift_path: swift_path
          )
        )
      when "private-stage-file"
        source, private_root, name = arguments
        unless name
          raise Error, "usage: release_tool.rb private-stage-file SOURCE PRIVATE_ROOT NAME"
        end
        puts PrivateArtifacts.stage_file!(source: source, root: private_root, name: name)
      when "private-publish-file"
        source, destination = arguments
        raise Error, "usage: release_tool.rb private-publish-file SOURCE DESTINATION" unless destination
        puts PrivateArtifacts.publish_file!(source: source, destination: destination)
      when "private-stage-release-artifacts"
        source_root, destination_root = arguments
        unless destination_root
          raise Error, "usage: release_tool.rb private-stage-release-artifacts SOURCE_ROOT DESTINATION_ROOT"
        end
        PrivateArtifacts.stage_release_artifacts!(
          source_root: source_root,
          destination_root: destination_root
        )
        puts "Staged existing release artifacts privately."
      when "publish-release-artifacts"
        source_root, destination_root = arguments
        unless destination_root
          raise Error, "usage: release_tool.rb publish-release-artifacts SOURCE_ROOT DESTINATION_ROOT"
        end
        PrivateArtifacts.publish_release_artifacts!(
          source_root: source_root,
          destination_root: destination_root
        )
        puts "Published finalized release artifacts atomically."
      when "verify-release-artifacts"
        manifest_path, app_path, dmg_path, dsym_path, source_identity_path = arguments
        unless source_identity_path
          raise Error, "usage: release_tool.rb verify-release-artifacts MANIFEST APP DMG DSYM SOURCE_IDENTITY"
        end
        metadata = Metadata.load(metadata_path)
        manifest = StrictJSON.load(manifest_path)
        source_identity = StrictJSON.load(source_identity_path)
        profile = manifest["sealProfile"]
        Evidence.validate!(manifest, metadata: metadata, profile: profile)
        ArtifactEvidence.verify_release_artifacts!(
          manifest: manifest,
          metadata: metadata,
          app: app_path,
          dmg: dmg_path,
          dsym: dsym_path,
          exact_source_identity: source_identity
        )
        puts "Release artifact identity and trust facts match sealed evidence."
      when "verify-artifacts"
        manifest_path = arguments.shift
        raise Error, "usage: release_tool.rb verify-artifacts MANIFEST" unless manifest_path
        metadata = Metadata.load(metadata_path)
        manifest = StrictJSON.load(manifest_path)
        profile = manifest["sealProfile"]
        Evidence.validate!(manifest, metadata: metadata, profile: profile)
        source_identity = ReleaseSource.identity!(
          root: root,
          expected_revision: manifest.fetch("source").fetch("revision")
        )
        Dir.mktmpdir("waves-release-artifact-verification") do |private_root|
          FileUtils.chmod(0o700, private_root)
          private_dist = File.join(private_root, "dist")
          FileUtils.mkdir_p(private_dist)
          FileUtils.chmod(0o700, private_dist)
          PrivateArtifacts.stage_release_artifacts!(
            source_root: File.join(root, "dist"),
            destination_root: private_dist
          )
          paths = ArtifactEvidence.default_paths(private_root)
          ArtifactEvidence.verify_release_artifacts!(
            manifest: manifest,
            metadata: metadata,
            app: File.join(private_root, "dist/Waves.app"),
            dmg: paths.fetch("dmg"),
            dsym: paths.fetch("dSYM"),
            exact_source_identity: source_identity
          )
        end
        puts "Signed candidate artifact identity, trust, and hashes match sealed evidence."
      else
        raise Error, "usage: release_tool.rb metadata|validate-repository|validate-workflows|source-identity|build-recipe-digest|evidence|tag-envelope|history|publication-tag|sparkle-signing-tool|verify-release-artifacts|verify-artifacts"
      end
    rescue Error => error
      warn "Error: #{error.message}"
      1
    end
  end
end

exit(WavesRelease::CLI.run(ARGV) || 0) if $PROGRAM_NAME == __FILE__
