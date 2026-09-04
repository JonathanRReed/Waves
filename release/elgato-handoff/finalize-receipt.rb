#!/usr/bin/ruby
# frozen_string_literal: true

require "digest"
require "json"
require "time"

module WavesElgatoReceipt
  class Error < StandardError; end

  class DuplicateCheckingHash < Hash
    def []=(key, value)
      raise Error, "duplicate JSON key #{key.inspect}" if key?(key)

      super
    end
  end

  TEST_IDS = %w[
    launch-orders
    routing-ownership
    single-audible-path
    arbitration-cycles
    device-and-relaunch
    stream-deck-controls
  ].freeze
  IMMUTABLE_FILES = %w[
    README.md
    ROLLBACK.md
    TEST-CHECKLIST.md
    Waves-1.5.0-13.dmg
    collect-diagnostics.sh
    com.jonathanreed.waves.streamDeckPlugin
    finalize-receipt.rb
    handoff.json
    release-evidence.candidate.json
    release-evidence.candidate.json.sha256
  ].freeze
  REQUIRED_DIAGNOSTICS = %w[
    TEST-CHECKLIST.md
    audio-and-usb.txt
    handoff-artifact-checksums.txt
    handoff.json
    installed-waves-identity.txt
    kernel.txt
    macos.txt
    relevant-processes.txt
    waves-diagnostics.txt
  ].freeze
  OPTIONAL_DIAGNOSTICS = %w[
    ADD-WAVES-DIAGNOSTICS.txt
    installed-waves-gatekeeper.txt
    installed-waves-signature.txt
    installed-waves-stapling.txt
  ].freeze
  MAX_DIAGNOSTIC_FILE_BYTES = 10 * 1024 * 1024
  MAX_DIAGNOSTIC_TOTAL_BYTES = 32 * 1024 * 1024

  module_function

  def run(arguments)
    trusted_checksums_digest, handoff_root, results_path, diagnostics_root, output_path = arguments
    unless output_path
      raise Error,
        "usage: finalize-receipt.rb TRUSTED_SHA256SUMS_SHA256 HANDOFF_ROOT RESULTS_JSON DIAGNOSTICS_ROOT OUTPUT_JSON"
    end
    raise Error, "receipt output already exists" if File.exist?(output_path) || File.symlink?(output_path)
    raise Error, "receipt digest output already exists" if File.exist?("#{output_path}.sha256") || File.symlink?("#{output_path}.sha256")

    root = verified_directory!(handoff_root, "handoff root")
    handoff = strict_json!(safe_file!(root, "handoff.json"), "handoff manifest")
    validate_handoff!(handoff)
    verify_immutable_files!(root, handoff, trusted_checksums_digest)
    results = strict_json!(results_path, "remote test results")
    validate_results!(results, handoff)
    diagnostics_digest = verify_diagnostics!(diagnostics_root, root)

    receipt = {
      "schemaVersion" => 1,
      "issuer" => handoff.fetch("remoteReceipt").fetch("issuer"),
      "sourceRevision" => handoff.fetch("sourceRevision"),
      "artifactSHA256" => handoff.fetch("artifacts").fetch("dmg").fetch("sha256"),
      "pluginSourceRevision" => handoff.fetch("artifacts").fetch("streamDeckPlugin").fetch("sourceRevision"),
      "pluginSHA256" => handoff.fetch("artifacts").fetch("streamDeckPlugin").fetch("sha256"),
      "candidateEvidenceSHA256" => handoff.fetch("candidateEvidenceSHA256"),
      "diagnosticsSHA256" => diagnostics_digest,
      "completedAt" => Time.now.utc.iso8601,
      "tests" => results.fetch("tests"),
    }
    contents = canonical_json(receipt)
    write_exclusive!(output_path, contents)
    digest = Digest::SHA256.hexdigest(contents)
    write_exclusive!("#{output_path}.sha256", "#{digest}  #{File.basename(output_path)}\n")
    puts "Finalized exact-candidate remote Elgato receipt at #{output_path}."
    0
  rescue Error, SystemCallError, JSON::ParserError => error
    warn "Error: #{error.message}"
    1
  end

  def validate_handoff!(handoff)
    exact_keys!(
      handoff,
      %w[
        schemaVersion issuer sourceRevision version build bundleIdentifier
        candidateEvidenceSHA256 artifacts remoteReceipt
      ],
      "handoff manifest"
    )
    raise Error, "handoff schemaVersion must be 1" unless handoff["schemaVersion"] == 1
    raise Error, "handoff issuer must be waves-release" unless handoff["issuer"] == "waves-release"
    revision!(handoff["sourceRevision"], "handoff source revision")
    sha256!(handoff["candidateEvidenceSHA256"], "candidate evidence SHA-256")
    exact_keys!(handoff["artifacts"], %w[dmg streamDeckPlugin], "handoff artifacts")
    exact_keys!(handoff["artifacts"]["dmg"], %w[name sha256], "handoff DMG")
    sha256!(handoff["artifacts"]["dmg"]["sha256"], "handoff DMG SHA-256")
    exact_keys!(
      handoff["artifacts"]["streamDeckPlugin"],
      %w[name sha256 sourceRevision],
      "handoff Stream Deck plugin"
    )
    sha256!(handoff["artifacts"]["streamDeckPlugin"]["sha256"], "plugin SHA-256")
    revision!(handoff["artifacts"]["streamDeckPlugin"]["sourceRevision"], "plugin revision")
    exact_keys!(handoff["remoteReceipt"], %w[issuer name], "remote receipt")
    unless handoff["remoteReceipt"]["issuer"] == "golden-gate-elgato" &&
        handoff["remoteReceipt"]["name"] == "remote-elgato-receipt.json"
      raise Error, "remote receipt identity is not canonical"
    end
  end

  def verify_immutable_files!(root, handoff, trusted_checksums_digest)
    checksum_path = safe_file!(root, "SHA256SUMS")
    sha256!(trusted_checksums_digest, "trusted handoff checksum digest")
    unless Digest::SHA256.file(checksum_path).hexdigest == trusted_checksums_digest
      raise Error, "handoff checksum file does not match the trusted out-of-band digest"
    end
    checksums = File.readlines(checksum_path, chomp: true).to_h do |line|
      match = line.match(/\A([0-9a-f]{64})  ([^\/\n]+)\z/)
      raise Error, "handoff checksum file is malformed" unless match
      [match[2], match[1]]
    end
    raise Error, "handoff checksum file set is not exact" unless checksums.keys.sort == IMMUTABLE_FILES
    checksums.each do |name, expected|
      actual = Digest::SHA256.file(safe_file!(root, name)).hexdigest
      raise Error, "handoff checksum mismatch for #{name}" unless actual == expected
    end

    dmg = handoff.fetch("artifacts").fetch("dmg")
    plugin = handoff.fetch("artifacts").fetch("streamDeckPlugin")
    unless Digest::SHA256.file(safe_file!(root, dmg.fetch("name"))).hexdigest == dmg.fetch("sha256")
      raise Error, "handoff DMG changed after preparation"
    end
    unless Digest::SHA256.file(safe_file!(root, plugin.fetch("name"))).hexdigest == plugin.fetch("sha256")
      raise Error, "Stream Deck package changed after preparation"
    end
    evidence_path = safe_file!(root, "release-evidence.candidate.json")
    evidence_digest = Digest::SHA256.file(evidence_path).hexdigest
    unless evidence_digest == handoff.fetch("candidateEvidenceSHA256")
      raise Error, "candidate evidence changed after preparation"
    end
    sidecar = File.read(safe_file!(root, "release-evidence.candidate.json.sha256"))
    unless sidecar == "#{evidence_digest}  release-evidence.candidate.json\n"
      raise Error, "candidate evidence sidecar does not match"
    end
  end

  def validate_results!(results, handoff)
    exact_keys!(results, %w[schemaVersion sourceRevision artifactSHA256 tests], "test results")
    raise Error, "test results schemaVersion must be 1" unless results["schemaVersion"] == 1
    unless results["sourceRevision"] == handoff["sourceRevision"]
      raise Error, "test results are not bound to the handoff source revision"
    end
    unless results["artifactSHA256"] == handoff.dig("artifacts", "dmg", "sha256")
      raise Error, "test results are not bound to the handoff DMG"
    end
    exact_keys!(results["tests"], TEST_IDS, "test result groups")
    results["tests"].each do |identifier, result|
      exact_keys!(result, %w[status detail], "test result #{identifier}")
      raise Error, "test result #{identifier} must pass" unless result["status"] == "passed"
      unless result["detail"].is_a?(String) && !result["detail"].strip.empty?
        raise Error, "test result #{identifier} detail must be non-empty"
      end
    end
  end

  def verify_diagnostics!(diagnostics_root, handoff_root)
    root = verified_directory!(diagnostics_root, "diagnostics root")
    entries = Dir.children(root).sort
    missing = REQUIRED_DIAGNOSTICS - entries
    raise Error, "diagnostics are missing #{missing.join(', ')}" unless missing.empty?
    unexpected = entries - REQUIRED_DIAGNOSTICS - OPTIONAL_DIAGNOSTICS
    raise Error, "diagnostics contain unexpected file #{unexpected.first}" unless unexpected.empty?
    total_bytes = entries.sum do |name|
      path = safe_file!(root, name)
      size = File.size(path)
      if size > MAX_DIAGNOSTIC_FILE_BYTES
        raise Error, "diagnostic file exceeds the 10 MiB size limit: #{name}"
      end
      size
    end
    if total_bytes > MAX_DIAGNOSTIC_TOTAL_BYTES
      raise Error, "diagnostic evidence exceeds the 32 MiB total size limit"
    end
    %w[handoff.json TEST-CHECKLIST.md].each do |name|
      unless Digest::SHA256.file(File.join(root, name)).hexdigest ==
          Digest::SHA256.file(File.join(handoff_root, name)).hexdigest
        raise Error, "diagnostics #{name} does not match the handoff"
      end
    end
    digest = Digest::SHA256.new
    entries.each do |name|
      digest << name << "\0" << Digest::SHA256.file(File.join(root, name)).digest
    end
    digest.hexdigest
  end

  def strict_json!(path, context)
    contents = File.read(path)
    value = JSON.parse(contents, object_class: DuplicateCheckingHash, create_additions: false)
    raise Error, "#{context} is not canonical JSON" unless canonical_json(value) == contents
    value
  end

  def canonical_json(value)
    JSON.pretty_generate(canonical_value(value)) + "\n"
  end

  def canonical_value(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical_value(value[key]) }
    when Array
      value.map { |item| canonical_value(item) }
    else
      value
    end
  end

  def exact_keys!(value, keys, context)
    raise Error, "#{context} must be an object" unless value.is_a?(Hash)
    unknown = value.keys - keys
    missing = keys - value.keys
    raise Error, "#{context} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?
    raise Error, "#{context} is missing keys: #{missing.join(', ')}" unless missing.empty?
  end

  def revision!(value, context)
    raise Error, "#{context} is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{40}\z/)
  end

  def sha256!(value, context)
    raise Error, "#{context} is invalid" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end

  def verified_directory!(path, context)
    expanded = File.expand_path(path)
    stat = File.lstat(expanded)
    raise Error, "#{context} must not be a symbolic link" if stat.symlink?
    raise Error, "#{context} must be a directory" unless stat.directory?
    expanded
  end

  def safe_file!(root, name)
    raise Error, "unsafe evidence filename #{name.inspect}" unless File.basename(name) == name
    path = File.join(root, name)
    stat = File.lstat(path)
    raise Error, "evidence file must not be a symbolic link: #{name}" if stat.symlink?
    raise Error, "evidence entry must be a regular file: #{name}" unless stat.file?
    path
  end

  def write_exclusive!(path, contents)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(contents)
      file.flush
      file.fsync
    end
  end
end

exit(WavesElgatoReceipt.run(ARGV)) if $PROGRAM_NAME == __FILE__
