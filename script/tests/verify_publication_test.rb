#!/usr/bin/ruby --disable-gems
# frozen_string_literal: true

require "minitest/autorun"
require "base64"
require "digest"
require "json"
require "stringio"
require_relative "../verify-publication"

class VerifyPublicationTest < Minitest::Test
  VERSION = "1.7.4"
  BUILD = "22"
  # RFC 8032 section 7.1, test 2: a one-byte message, its public key and its
  # signature stand in for the DMG, the pinned Sparkle key and the appcast.
  DMG = "\x72".b
  PUBLIC_KEY = ["3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"].pack("H*")
  SIGNATURE = Base64.strict_encode64(
    ["92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da" \
     "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"].pack("H*")
  )
  SHA = Digest::SHA256.hexdigest(DMG)
  API = "https://api.github.com/repos/JonathanRReed/Waves/releases"
  DMG_URL = "https://github.com/JonathanRReed/Waves/releases/download/v1.7.4/Waves.dmg"
  SITE = "https://waves.jonathanrreed.com"

  def appcast(version: VERSION, build: BUILD, url: DMG_URL, length: DMG.bytesize, signature: SIGNATURE)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:version>#{build}</sparkle:version><sparkle:shortVersionString>#{version}</sparkle:shortVersionString>
          <enclosure url="#{url}" length="#{length}" type="application/octet-stream" sparkle:edSignature="#{signature}"/></item>
        <item><sparkle:version>21</sparkle:version><sparkle:shortVersionString>1.7.3</sparkle:shortVersionString>
          <enclosure url="https://github.com/JonathanRReed/Waves/releases/download/v1.7.3/Waves.dmg" length="1" sparkle:edSignature="x"/></item>
      </channel></rss>
    XML
  end

  def responses
    release = {"tag_name" => "v1.7.4", "draft" => false, "prerelease" => false,
               "assets" => [{"name" => "Waves.dmg", "browser_download_url" => DMG_URL}]}
    {
      "#{API}/tags/v1.7.4" => JSON.generate(release),
      "#{API}/latest" => JSON.generate(release),
      DMG_URL => DMG,
      "#{DMG_URL}.sha256" => "#{SHA}  Waves.dmg\n",
      "#{SITE}/appcast.xml" => appcast,
      "#{SITE}/" => %(<a href="https://github.com/JonathanRReed/Waves/releases/download/v1.7.4/Waves.dmg">Download</a>),
      "#{SITE}/changelog/" => %(<h2 id="v1-7-4">1.7.4</h2><h2 id="v1-7-3">1.7.3</h2>),
      WavesPublication::CASK_URL => %(cask "waves" do\n  version "1.7.4"\n  sha256 "#{SHA}"\n) +
        %(  url "https://github.com/JonathanRReed/Waves/releases/download/v\#{version}/Waves.dmg"\nend\n),
    }
  end

  def run_with(canned)
    out = StringIO.new
    fetch = lambda do |url|
      value = canned.fetch(url) { raise WavesPublication::Failure, "HTTP 404 from #{url}" }
      raise value if value.is_a?(Exception)

      value
    end
    status = WavesPublication.run([VERSION, BUILD], out: out, fetch: fetch, public_key: PUBLIC_KEY)
    [status, out.string]
  end

  def assert_only_failure(canned, check, pattern)
    status, output = run_with(canned)
    assert_equal 1, status, output
    failures = output.lines.grep(/\AFAIL/)
    assert_equal 1, failures.length, output
    assert_match(/\AFAIL  #{Regexp.escape(check)}\s.*#{pattern}/, failures.first)
  end

  def test_all_four_channels_agree
    status, output = run_with(responses)
    assert_equal 0, status, output
    assert_equal 7, output.lines.grep(/\APASS/).length
    assert_match(/live on all four channels/, output)
  end

  def test_draft_or_prerelease_release_fails
    %w[draft prerelease].each do |field|
      canned = responses
      release = JSON.parse(canned["#{API}/tags/v1.7.4"]).merge(field => true)
      canned["#{API}/tags/v1.7.4"] = JSON.generate(release)
      assert_only_failure(canned, "GitHub release", field)
    end
  end

  def test_older_latest_release_fails
    canned = responses
    canned["#{API}/latest"] = JSON.generate("tag_name" => "v1.7.3")
    assert_only_failure(canned, "GitHub latest", /v1\.7\.3/)
  end

  def test_checksum_sidecar_mismatch_fails
    canned = responses
    canned["#{DMG_URL}.sha256"] = "#{'0' * 64}  Waves.dmg\n"
    assert_only_failure(canned, "GitHub DMG", /Waves\.dmg\.sha256/)
  end

  def test_stale_or_wrong_appcast_fails
    {
      appcast(version: "1.7.3", build: "21") => /expected 1\.7\.4 build 22/,
      appcast(url: DMG_URL.sub("v1.7.4", "v1.7.3")) => /enclosure URL/,
      appcast(length: DMG.bytesize + 1) => /enclosure length/,
      appcast(signature: "") => /edSignature/,
      appcast(signature: Base64.strict_encode64("\0" * 64)) => /does not verify/,
      appcast(signature: Base64.strict_encode64(Base64.strict_decode64(SIGNATURE).tap { |raw| raw.setbyte(40, raw.getbyte(40) ^ 1) })) => /does not verify/,
    }.each do |feed, pattern|
      canned = responses
      canned["#{SITE}/appcast.xml"] = feed
      assert_only_failure(canned, "Appcast", pattern)
    end
  end

  def test_stale_site_fails
    canned = responses
    canned["#{SITE}/"] += %(<a href="https://github.com/JonathanRReed/Waves/releases/download/v1.7.3/Waves.dmg">)
    assert_only_failure(canned, "Site download", /v1\.7\.3/)

    canned = responses
    canned["#{SITE}/changelog/"] = %(<h2 id="v1-7-3">1.7.3</h2>)
    assert_only_failure(canned, "Site changelog", /1\.7\.3/)
  end

  def test_stale_tap_fails
    canned = responses
    canned[WavesPublication::CASK_URL] = canned[WavesPublication::CASK_URL].sub(SHA, "f" * 64)
    assert_only_failure(canned, "Homebrew tap", /sha256/)

    canned = responses
    canned[WavesPublication::CASK_URL] = canned[WavesPublication::CASK_URL].sub(%(version "1.7.4"), %(version "1.7.3"))
    assert_only_failure(canned, "Homebrew tap", /1\.7\.3/)

    canned = responses
    canned[WavesPublication::CASK_URL] = canned[WavesPublication::CASK_URL].sub('v#{version}', "v1.7.3")
    assert_only_failure(canned, "Homebrew tap", /cask url resolves to/)
  end

  def test_unreachable_channel_is_reported_and_others_still_run
    canned = responses
    canned.delete(DMG_URL)
    status, output = run_with(canned)
    assert_equal 1, status
    assert_match(/\AFAIL  GitHub DMG\s+HTTP 404/, output.lines.grep(/GitHub DMG/).first)
    assert_match(/\AFAIL  Appcast\s.*did not download/, output.lines.grep(/Appcast/).first)
    assert_match(/\APASS  Site changelog/, output.lines.grep(/Site changelog/).first)
  end

  def test_signature_from_another_key_fails
    other_key = ["d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"].pack("H*")
    out = StringIO.new
    status = WavesPublication.run([VERSION, BUILD], out: out, fetch: ->(url) { responses.fetch(url) }, public_key: other_key)
    assert_equal 1, status, out.string
    assert_match(/\AFAIL  Appcast\s.*does not verify/, out.string.lines.grep(/Appcast/).first)
  end

  def test_rejects_malformed_arguments
    _out, err = capture_io do
      assert_equal 2, WavesPublication.run(["1.7"], fetch: ->(_) { flunk "fetched" }, public_key: PUBLIC_KEY)
      assert_equal 2, WavesPublication.run(["1.7", "22"], fetch: ->(_) { flunk "fetched" }, public_key: PUBLIC_KEY)
      assert_equal 2, WavesPublication.run(["1.7.4", "0"], fetch: ->(_) { flunk "fetched" }, public_key: PUBLIC_KEY)
    end
    assert_match(/usage/, err)
  end
end
