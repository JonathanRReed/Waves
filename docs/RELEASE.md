# Release Checklist

Use this checklist before publishing a Waves build. None of the local commands
below create or push a tag, publish a release, change repository visibility, or
upload an artifact. The GitHub release workflow only runs after a maintainer
separately pushes a valid release tag.

## Prepare Release Metadata

Before creating a tag:

- Move the release notes out of `Unreleased` into exactly one
  `## [X.Y.Z]` or `## [X.Y.Z] - YYYY-MM-DD` heading in `CHANGELOG.md`.
- Set the matching version in `Casks/waves.rb`.
- Leave `sha256 "RELEASE_WORKFLOW_REPLACES_THIS_SHA256"` unchanged. It is an
  intentionally invalid template value and cannot be used as a published cask
  checksum.
- Confirm the intended release commit is the current `origin/main` commit.

The workflow accepts only tags that exactly match `vX.Y.Z` with numeric
components and no leading zeroes. It requires the tagged commit to equal the
fetched `origin/main` commit before reading any signing or notarization secret.

## Unsigned or Ad Hoc Local Validation

These checks require normal macOS build/package tools, but do not require a
Developer ID certificate or notarization credentials:

```bash
swift test
swift build -c release
./script/build_and_run.sh --release-check
./script/build_and_run.sh --verify
./script/build_and_run.sh --package-smoke
```

`--release-check` is the fresh distribution build path. It builds arm64 and
x86_64 release slices, creates `dist/Waves.app`, creates a matching universal
`dist/Waves.app.dSYM` when `dsymutil` is available, stages a clean installer
layout, creates `dist/Waves.dmg`, and runs the common package checks. Without
`SIGN_IDENTITY`, the app is ad hoc signed for local validation.

`--verify` only validates the existing app, dSYM, and DMG. It does not build,
recreate, or overwrite them. `--package-smoke` mounts the existing DMG, launches
the packaged app executable for a short health window with isolated temporary
home and Application Support directories, records a smoke log, verifies that no
session was persisted before privacy consent, and terminates the launched test
process before detaching the image.

Expected unsigned/ad hoc validation results:

- The test suite and release build pass.
- The app and dSYM contain exactly `arm64` and `x86_64`; dSYM UUIDs match the app
  when `dwarfdump` is available.
- The app version, build, bundle identity, and macOS 14.2 minimum match the
  expected release values.
- The app contains its generated icon, SwiftPM `Waves_Waves.bundle`, valid
  `PrivacyInfo.xcprivacy`, and `com.apple.security.device.audio-input = true`.
- The DMG root contains only `Waves.app` and `Applications`, with `Applications`
  linking to `/Applications`.
- The mounted app content and code identity match `dist/Waves.app`.
- The packaged app remains alive for the smoke window and its test process is
  cleaned up.

A local check does not fail solely because the app lacks a Developer ID
signature or the DMG lacks notarization. It is not approval for publication.

## Credential-Dependent Publication Validation

Public builds must be signed with a Developer ID Application certificate and
notarized. Confirm credentials are installed:

```bash
security find-identity -p codesigning -v
xcrun notarytool history --keychain-profile waves-notary
```

Store a notarytool profile once if needed:

```bash
xcrun notarytool store-credentials waves-notary --apple-id <apple-id> --team-id <team-id>
```

Build, sign, submit, staple, and run the shared unsigned package checks:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="waves-notary" \
APP_VERSION="X.Y.Z" \
APP_BUILD="<build-number>" \
./script/build_and_run.sh --notarize
```

Then run the strict publication gate and packaged-app smoke against those
existing artifacts; neither command rebuilds them:

```bash
APP_VERSION="X.Y.Z" APP_BUILD="<build-number>" ./script/build_and_run.sh --publication-check
APP_VERSION="X.Y.Z" APP_BUILD="<build-number>" ./script/build_and_run.sh --package-smoke
```

Publication validation reuses all unsigned package checks and additionally
requires:

- A Developer ID Application signature, not an ad hoc signature.
- A signing team identifier and a valid sealed app bundle.
- Gatekeeper acceptance of the app.
- A valid stapled notarization ticket and Gatekeeper acceptance of the DMG.

The tag-driven workflow performs tests and unsigned checks before importing
credentials. After notarization it runs publication validation and package
smoke, then produces and uploads these workflow artifacts:

- `Waves.dmg`
- `Waves.dmg.sha256`
- `Waves.app.dSYM.zip`
- `waves.rb`, generated from `Casks/waves.rb` with the final checksum
- package, smoke, and publication logs

The workflow creates the GitHub release as a draft with the matching curated
`CHANGELOG.md` section as its body. A maintainer reviews the draft notes and
assets, then clicks **Publish release** manually.

The generated cask is a release artifact; the workflow does not replace the
checksum placeholder in the repository. Audit the generated file before
publishing it to a tap:

```bash
brew audit --cask ./waves.rb
```

The template URL points to GitHub Releases and assumes the DMG is publicly
fetchable. If the repository or release remains private, a standard public
Homebrew cask cannot download that authenticated artifact. Do not publish the
cask to a public tap until the release asset has an intentionally public,
stable URL; this checklist does not change repository visibility or distribution
policy.

## Rollback and Recovery

Before installing a release candidate or production update, quit Waves and back
up both persistence locations if they exist. Back up the preferences plist as a
separate convenience because it is outside those support directories:

```bash
BACKUP="$HOME/Desktop/Waves-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
[ ! -d "$HOME/Library/Application Support/Waves" ] || \
  ditto "$HOME/Library/Application Support/Waves" "$BACKUP/Application Support-Waves"
[ ! -d "$HOME/.Waves" ] || \
  ditto "$HOME/.Waves" "$BACKUP/dot-Waves"
[ ! -f "$HOME/Library/Preferences/com.jonathanreed.Waves.plist" ] || \
  cp "$HOME/Library/Preferences/com.jonathanreed.Waves.plist" "$BACKUP/"
```

Retain the previous known-good DMG, checksum, generated cask, and dSYM. If a
candidate fails validation, do not publish it. If a published release must be
rolled back:

1. Stop directing new installs to the affected artifact and restore the prior
   known-good cask/checksum in the distribution channel.
2. Quit Waves, replace `Waves.app` with the prior known-good build, and verify
   that build with its retained checksum and package checks.
3. If persisted state prevents recovery, move the current
   `~/Library/Application Support/Waves` and `~/.Waves` directories aside, then
   restore both matching backup directories to their original paths. Restore
   the preferences plist only if needed. Do not merge JSON files by hand.
4. Preserve the failed release artifacts and logs for diagnosis, document the
   rollback, and prepare a new patch release rather than reusing a published
   tag or checksum.

Do not assume arbitrary forward or backward data-schema compatibility. The only
compatibility assumption is the documented schema-1 additive policy: schema-1
changes may add fields while retaining existing meanings. There is no broader
promise that an older build can safely consume state written by a newer schema,
so restoring the backup made with the rolled-back build is the safest recovery.

## Privacy and Security Review

Before publishing, confirm:

- URL scheme automation is disabled by default.
- First-run privacy setup blocks audio-backend startup and capture attempts until
  the user records local consent.
- Audio capture usage copy is present in the app bundle.
- Copied diagnostics contain no audio samples and label app/device names or
  identifiers, route/permission state, and error text for review before sharing.
- No secrets, Apple credentials, notary profiles, cookies, or API keys are
  committed.
- `dist/`, `.build/`, `.swiftpm/`, and user-specific Xcode state are ignored.
