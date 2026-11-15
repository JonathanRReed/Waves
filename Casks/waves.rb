# Homebrew cask template for Waves.
#
# Release tooling checks that `version` matches release/metadata.json and that
# the checksum stays an invalid placeholder. The published cask, with the real
# checksum, lives in the JonathanRReed/homebrew-tap repository; see
# docs/RELEASE.md, "Update the Homebrew Tap". Nothing mutates this template.
cask "waves" do
  version "1.7.4"
  sha256 "RELEASE_WORKFLOW_REPLACES_THIS_SHA256"

  url "https://github.com/JonathanRReed/Waves/releases/download/v#{version}/Waves.dmg"
  name "Waves"
  desc "Native per-app audio mixer"
  homepage "https://github.com/JonathanRReed/Waves"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Waves updates itself with Sparkle.
  auto_updates true

  # Per-app routing requires Core Audio process taps — macOS 14.2 is the floor
  # (matches LSMinimumSystemVersion). Homebrew's depends_on only understands
  # major versions, so gate on Sonoma here; the app itself refuses 14.0/14.1
  # with its unsupported-OS path.
  depends_on macos: :sonoma

  app "Waves.app"

  zap trash: [
    "~/.Waves",
    "~/Library/Application Support/Waves",
    "~/Library/Preferences/com.jonathanreed.Waves.plist",
  ]
end
