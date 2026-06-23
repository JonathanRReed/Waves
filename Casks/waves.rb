# Homebrew cask for Waves.
#
# To publish: copy this into a tap (e.g. JonathanRReed/homebrew-tap) and, on each
# release, set `version` to the tag and `sha256` to the notarized DMG's checksum
# (`shasum -a 256 Waves.dmg`). With Sparkle handling in-app updates you may also
# set `auto_updates true`.
cask "waves" do
  version "1.0.0"
  sha256 :no_check # replace with the released Waves.dmg checksum

  url "https://github.com/JonathanRReed/Waves/releases/download/v#{version}/Waves.dmg",
      verified: "github.com/JonathanRReed/Waves/"
  name "Waves"
  desc "Native macOS per-app audio mixer"
  homepage "https://github.com/JonathanRReed/Waves"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Per-app routing requires Core Audio process taps — macOS 14.2 is the floor
  # (matches LSMinimumSystemVersion). 14.0/14.1 would hit the unsupported-OS path.
  depends_on macos: ">= 14.2"

  app "Waves.app"

  zap trash: [
    "~/Library/Application Support/Waves",
    "~/Library/Preferences/com.jonathanreed.Waves.plist",
  ]
end
