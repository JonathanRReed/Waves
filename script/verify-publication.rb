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

  # Ed25519 signature verification (RFC 8032), so the appcast signature can be
  # checked against the downloaded DMG with only the pinned public key. The
  # system Ruby's OpenSSL has no Ed25519. Verification handles no secrets, so
  # plain integer arithmetic is enough.
  module Ed25519
    P = 2**255 - 19
    L = 2**252 + 27_742_317_777_372_353_535_851_937_790_883_648_493
    D = -121_665 * 121_666.pow(P - 2, P) % P
    SQRT_M1 = 2.pow((P - 1) / 4, P)

    module_function

    def recover_x(y, sign)
      return nil if y >= P

      x2 = (y * y - 1) * (D * y * y + 1).pow(P - 2, P) % P
      return sign.zero? ? 0 : nil if x2.zero?

      x = x2.pow((P + 3) / 8, P)
      x = x * SQRT_M1 % P unless ((x * x - x2) % P).zero?
      return nil unless ((x * x - x2) % P).zero?

      (x & 1) == sign ? x : P - x
    end

    def integer(bytes)
      bytes.reverse.unpack1("H*").to_i(16)
    end

    def point(bytes)
      y = integer(bytes)
      sign = y >> 255
      y &= (1 << 255) - 1
      x = recover_x(y, sign)
      x && [x, y, 1, x * y % P]
    end

    def add(p, q)
      a = (p[1] - p[0]) * (q[1] - q[0]) % P
      b = (p[1] + p[0]) * (q[1] + q[0]) % P
      c = 2 * p[3] * q[3] * D % P
      d = 2 * p[2] * q[2] % P
      e, f, g, h = b - a, d - c, d + c, b + a
      [e * f % P, g * h % P, f * g % P, e * h % P]
    end

    def multiply(scalar, p)
      q = [0, 1, 1, 0]
      while scalar.positive?
        q = add(q, p) if scalar.odd?
        p = add(p, p)
        scalar >>= 1
      end
      q
    end

    BASE_Y = 4 * 5.pow(P - 2, P) % P
    BASE_X = recover_x(BASE_Y, 0)
    BASE = [BASE_X, BASE_Y, 1, BASE_X * BASE_Y % P].freeze

    def valid?(public_key, message, signature)
      public_key, signature = public_key.b, signature.b
      return false unless public_key.bytesize == 32 && signature.bytesize == 64

      a = point(public_key)
      r = point(signature[0, 32])
      s = integer(signature[32, 32])
      return false unless a && r && s < L

      h = integer(Digest::SHA512.digest(signature[0, 32] + public_key + message.b)) % L
      left = multiply(s, BASE)
      right = add(r, multiply(h, a))
      ((left[0] * right[2] - right[0] * left[2]) % P).zero? && ((left[1] * right[2] - right[1] * left[2]) % P).zero?
    end
  end

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

  def pinned_public_key
    Base64.strict_decode64(JSON.parse(File.read(METADATA)).fetch("sparkle").fetch("publicEDKey"))
  end

  def verify(version:, build:, fetch: method(:fetch), public_key: pinned_public_key)
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
      dmg = {sha256: Digest::SHA256.hexdigest(bytes), size: bytes.bytesize, bytes: bytes}
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
      require_that.call(Ed25519.valid?(public_key, dmg[:bytes], decoded),
                        "sparkle:edSignature does not verify over the downloaded DMG with the pinned Sparkle key")
      "newest item is #{found}, enclosure matches the release DMG and its EdDSA signature verifies"
    end

    attempt.call("Site download") do
      links = fetch.call("#{SITE}/").scan(%r{[^"'\s<>]*/releases/download/[^"'\s<>]*}).uniq
      require_that.call(links == [dmg_url], "download links point at #{links.empty? ? 'nothing' : links.join(', ')}")
      "every download link is #{dmg_url}"
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
      cask_url = cask[/^\s*url\s+"([^"]+)"/, 1].to_s.gsub('#{version}', cask_version)
      require_that.call(cask_url == dmg_url, "cask url resolves to #{cask_url.inspect}, expected #{dmg_url}")
      require_that.call(dmg, "cask checksum not compared because the DMG did not download")
      require_that.call(cask_sha == dmg[:sha256], "cask sha256 #{cask_sha.inspect} differs from the downloaded DMG")
      "cask is #{version} with the downloaded DMG's sha256"
    end

    checks
  end

  def run(arguments, out: $stdout, fetch: method(:fetch), public_key: pinned_public_key)
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

    checks = verify(version: version, build: build, fetch: fetch, public_key: public_key)
    checks.each { |check| out.puts "#{check.passed ? 'PASS' : 'FAIL'}  #{check.name.ljust(15)} #{check.detail}" }
    failed = checks.count { |check| !check.passed }
    out.puts(failed.zero? ? "Waves #{version} build #{build} is live on all four channels." : "#{failed} check(s) failed for Waves #{version} build #{build}.")
    failed.zero? ? 0 : 1
  end
end

exit WavesPublication.run(ARGV) if $PROGRAM_NAME == __FILE__
