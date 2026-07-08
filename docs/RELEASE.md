# Release Checklist

Use this checklist before publishing a Waves build.

## Local Validation

Run these checks before cutting any release candidate:

```bash
swift test
./script/build_and_run.sh --verify
./script/build_and_run.sh --release-check
lipo -archs dist/Waves.app/Contents/MacOS/Waves
```

Expected result:
- The test suite passes.
- The app bundle launches and stays alive.
- `dist/Waves.dmg` is recreated and validates with `hdiutil imageinfo`.
- `lipo -archs` reports `x86_64 arm64` — distribution builds are universal
  (Apple Silicon + Intel), matching the README and cask support claims.
- `dist/Waves.app/Contents/Resources/Waves_Waves.bundle` exists — the SwiftPM
  resource bundle `Bundle.module` loads at launch.
- `dist/Waves.app/Contents/Resources/waves-logo.icns` exists — the public
  app bundle has the generated Dock/Finder icon.
- `dist/Waves.app/Contents/Resources/PrivacyInfo.xcprivacy` exists and passes
  `plutil -lint`.

## Public Distribution Validation

Public builds must be signed with a Developer ID Application certificate and notarized.

Confirm signing and notarization credentials are installed:

```bash
security find-identity -p codesigning -v
xcrun notarytool history --keychain-profile waves-notary
```

Expected result:
- At least one identity is a `Developer ID Application` certificate.
- `notarytool` can read the `waves-notary` keychain profile.

Store a notarytool profile once:

```bash
xcrun notarytool store-credentials waves-notary --apple-id <apple-id> --team-id <team-id>
```

Build, submit, staple, and validate:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE="waves-notary" ./script/build_and_run.sh --notarize
```

Confirm the final artifact is acceptable for distribution:

```bash
./script/build_and_run.sh --publication-check
```

Expected result:
- `codesign` reports a Developer ID signature, not an ad hoc signature.
- `TeamIdentifier` is set.
- The signed app carries `com.apple.security.device.audio-input = true`.
- The app inside `dist/Waves.dmg` matches `dist/Waves.app`.
- `xcrun stapler validate dist/Waves.dmg` succeeds.
- Gatekeeper accepts the app bundle.
- Gatekeeper accepts the DMG.

Before publishing the Homebrew cask, replace `sha256 :no_check` in
`Casks/waves.rb` with the SHA-256 checksum of the signed, notarized DMG:

```bash
shasum -a 256 dist/Waves.dmg
```

Then audit the final cask:

```bash
brew audit --cask ./Casks/waves.rb
```

## Privacy and Security Review

Before publishing, confirm:
- URL scheme automation is disabled by default.
- Audio capture usage copy is present in the app bundle.
- No secrets, Apple credentials, notary profiles, cookies, or API keys are committed.
- `dist/`, `.build/`, `.swiftpm/`, and user-specific Xcode state are ignored.
