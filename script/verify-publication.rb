#!/usr/bin/ruby --disable-gems
# frozen_string_literal: true

# Checks that the four public release channels all serve one Waves release:
# the GitHub release, the Sparkle appcast, the website and the Homebrew tap.
# It reads only public URLs, sends no credentials and changes nothing.
#
#   script/verify-publication.rb                # version and build from release/metadata.json
#   script/verify-publication.rb 1.7.4 22       # an explicit version and build

require "base64"
require "digest"
require "json"
require "net/http"
require "rexml/document"
require "uri"

module WavesPublication
  REPOSITORY = "JonathanRReed/Waves"
  SITE = "https://waves.jonathanrreed.com"
  CASK_URL = "https://raw.githubusercontent.com/JonathanRReed/homebrew-tap/main/Casks/waves.rb"
  SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
  METADATA = File.expand_path("../release/metadata.json", __dir__)

  class Failure < StandardError; end
  Check = Struct.new(:name, :passed, :detail)

  module_function

  # Unauthenticated GET that follows HTTPS redirects and returns the body.
  def fetch(url, redirects: 5)
    uri = URI(url)
    raise Failure, "refusing non-HTTPS URL #{url}" unless uri.scheme == "https"

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "waves-publication-verifier"
      http.request(request)
    end
    case response
    when Net::HTTPSuccess then response.body.to_s
    when Net::HTTPRedirection
      raise Failure, "too many redirects for #{url}" if redirects.zero?

      fetch(URI.join(url, response["location"]).to_s, redirects: redirects - 1)
    else
      raise Failure, "HTTP #{response.code} from #{url}"
    end
  end

  def verify(version:, build:, fetch: method(:fetch))
    tag = "v#{version}"
    dmg_url = "https://github.com/#{REPOSITORY}/releases/download/#{tag}/Waves.dmg"
    checks = []
    attempt = lambda do |name, &body|
      checks << Check.new(name, true, body.call)
    rescue StandardError => e
      checks << Check.new(name, false, e.message)
    end
    require_that = ->(condition, message) { raise Failure, message unless condition }
    dmg = nil

    attempt.call("GitHub release") do
      release = JSON.parse(fetch.call("https://api.github.com/repos/#{REPOSITORY}/releases/tags/#{tag}"))
      require_that.call(release["draft"] == false, "#{tag} is a draft")
      require_that.call(release["prerelease"] == false, "#{tag} is marked as a prerelease")
      asset = Array(release["assets"]).find { |entry| entry["name"] == "Waves.dmg" }
      require_that.call(asset && asset["browser_download_url"] == dmg_url, "#{tag} has no Waves.dmg asset at #{dmg_url}")
      "#{tag} is published, not a draft or prerelease"
    end

    attempt.call("GitHub latest") do
      latest = JSON.parse(fetch.call("https://api.github.com/repos/#{REPOSITORY}/releases/latest"))["tag_name"]
      require_that.call(latest == tag, "latest release is #{latest.inspect}, expected #{tag}")
      "#{tag} is the latest release"
    end

    attempt.call("GitHub DMG") do
      bytes = fetch.call(dmg_url)
      dmg = {sha256: Digest::SHA256.hexdigest(bytes), size: bytes.bytesize}
      sidecar = fetch.call("#{dmg_url}.sha256").split.first
      require_that.call(sidecar == dmg[:sha256], "Waves.dmg.sha256 says #{sidecar.inspect}, downloaded DMG is #{dmg[:sha256]}")
      "#{dmg[:size]} bytes, sha256 #{dmg[:sha256]}, matches Waves.dmg.sha256"
    end

    attempt.call("Appcast") do
      document = REXML::Document.new(fetch.call("#{SITE}/appcast.xml"))
      items = REXML::XPath.match(document, "/rss/channel/item")
      require_that.call(!items.empty?, "appcast has no items")
      sparkle = ->(item, name) { REXML::XPath.first(item, "sparkle:#{name}", "sparkle" => SPARKLE_NS)&.text.to_s.strip }
      newest = items.max_by { |item| sparkle.call(item, "version").to_i }
      found = "#{sparkle.call(newest, 'shortVersionString')} build #{sparkle.call(newest, 'version')}"
      require_that.call(found == "#{version} build #{build}", "newest item is #{found}, expected #{version} build #{build}")
      enclosure = REXML::XPath.first(newest, "enclosure")
      require_that.call(enclosure, "newest item has no enclosure")
      require_that.call(enclosure.attributes["url"] == dmg_url, "enclosure URL is #{enclosure.attributes['url'].inspect}")
      require_that.call(dmg, "enclosure length not compared because the DMG did not download")
      length = enclosure.attributes["length"]
      require_that.call(length == dmg[:size].to_s, "enclosure length #{length.inspect} differs from the #{dmg[:size]}-byte DMG")
      signature = enclosure.attribute("edSignature", SPARKLE_NS)&.value.to_s
      decoded = Base64.strict_decode64(signature) rescue ""
      require_that.call(decoded.bytesize == 64, "enclosure has no 64-byte sparkle:edSignature")
      "newest item is #{found}, enclosure matches the release DMG and is EdDSA-signed"
    end

    attempt.call("Site download") do
      links = fetch.call("#{SITE}/").scan(%r{releases/download/([^/"'\s]+)/Waves\.dmg}).flatten.uniq
      require_that.call(links == [tag], "download links point at #{links.empty? ? 'nothing' : links.join(', ')}")
      "every download link points at #{tag}"
    end

    attempt.call("Site changelog") do
      newest = fetch.call("#{SITE}/changelog/")[/id="v(\d+-\d+-\d+)"/, 1].to_s.tr("-", ".")
      require_that.call(newest == version, "newest changelog entry is #{newest.empty? ? 'missing' : newest}")
      "newest changelog entry is #{version}"
    end

    attempt.call("Homebrew tap") do
      cask = fetch.call(CASK_URL)
      cask_version = cask[/^\s*version\s+"([^"]+)"/, 1]
      cask_sha = cask[/^\s*sha256\s+"([^"]+)"/, 1]
      require_that.call(cask_version == version, "cask version is #{cask_version.inspect}")
      require_that.call(dmg, "cask checksum not compared because the DMG did not download")
      require_that.call(cask_sha == dmg[:sha256], "cask sha256 #{cask_sha.inspect} differs from the downloaded DMG")
      "cask is #{version} with the downloaded DMG's sha256"
    end

    checks
  end

  def run(arguments, out: $stdout, fetch: method(:fetch))
    case arguments.length
    when 0
      metadata = JSON.parse(File.read(METADATA))
      version, build = metadata.fetch("version"), metadata.fetch("build").to_s
    when 2
      version, build = arguments
    else
      warn "usage: #{File.basename($PROGRAM_NAME)} [VERSION BUILD]"
      return 2
    end
    unless version.match?(/\A\d+\.\d+\.\d+\z/) && build.match?(/\A[1-9]\d*\z/)
      warn "version must be X.Y.Z and build a positive integer"
      return 2
    end

    checks = verify(version: version, build: build, fetch: fetch)
    checks.each { |check| out.puts "#{check.passed ? 'PASS' : 'FAIL'}  #{check.name.ljust(15)} #{check.detail}" }
    failed = checks.count { |check| !check.passed }
    out.puts(failed.zero? ? "Waves #{version} build #{build} is live on all four channels." : "#{failed} check(s) failed for Waves #{version} build #{build}.")
    failed.zero? ? 0 : 1
  end
end

exit WavesPublication.run(ARGV) if $PROGRAM_NAME == __FILE__
