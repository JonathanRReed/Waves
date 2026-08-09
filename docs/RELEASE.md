# Release Checklist

Use this checklist before publishing a Waves build. None of the local commands
below create or push a tag, publish a release, change repository visibility, or
upload an artifact. The GitHub release workflow only runs after a maintainer
separately pushes a valid release tag.

## Current release boundary

Version 1.4.4 is the latest published release. Version 1.5.0 build 13 is an
in-development candidate, not a downloadable release. Do not update public
download, appcast, Homebrew, or latest-release claims until the exact candidate
passes every local and external gate below.

For 1.5, the separately versioned Stream Deck companion at
`/Users/jonathanreed/Downloads/waves-streamdeck` must pass its Bun typecheck,
unit tests, validator, package build, and live packaged-Waves socket test over
protocol version 1. The companion is not bundled in Waves. A second Golden Gate
machine must then verify real Wave Link and physical Stream Deck hardware,
including both launch orders, claimed and unclaimed apps, mixed output, device
changes, relaunch, route arbitration cycles, dial changes, mute synchronization,
and automatic recovery. This remote result is a hard publication gate and is
not yet complete.

The sealed 1.5 evidence manifest must identify the exact revision and clean-tree
state, toolchain, test counts, performance comparison, package identities,
architectures, hashes, signatures, notarization, Gatekeeper result, local QA,
and remote Elgato result. A source build or local package check cannot substitute
for any missing field.

## Prepare Release Metadata

Before creating a tag:

- Move the release notes out of `Unreleased` into exactly one
  `## [X.Y.Z]` or `## [X.Y.Z] - YYYY-MM-DD` heading in `CHANGELOG.md`.
- Set the matching version in `Casks/waves.rb`.
- Bump the build number in **both** `script/build_and_run.sh` (`APP_BUILD`) and
  `.github/workflows/release.yml` (`RELEASE_BUILD`) to the same new integer, and
  make it strictly greater than the last published build. Sparkle compares
  `sparkle:version` numerically, so a repeated or lower build is never offered —
  which is how 1.3.0 shipped twice under build 6. The workflow now fails if the
  two files disagree, and `make_appcast.sh` fails if the build is not higher
  than everything already in the appcast.
- Leave `sha256 "RELEASE_WORKFLOW_REPLACES_THIS_SHA256"` unchanged. It is an
  intentionally invalid template value and cannot be used as a published cask
  checksum.
- Confirm the intended release commit is the current `origin/main` commit.

## How a release is signed

Releases are built, signed and notarized **on the maintainer's Mac**, using the
Developer ID identity in that machine's keychain and a `notarytool` keychain
profile. The signing key never leaves that Mac and is not stored in GitHub
Actions secrets.

That is deliberate. With a single maintainer, putting a Developer ID private key
in CI adds a large blast radius — anything that can read repository secrets can
sign software as you, and revoking a leaked identity invalidates everything
already shipped — in exchange for convenience this project does not need.

One-time setup, which prompts for an app-specific password from appleid.apple.com:

```bash
xcrun notarytool store-credentials waves-notary --apple-id "<apple-id>" --team-id AJ9VWBRNZN
```

Then, for each release:

```bash
SIGN_IDENTITY="Developer ID Application: Jonathan Reed (AJ9VWBRNZN)" NOTARY_PROFILE=waves-notary ./script/build_and_run.sh --notarize
```

`.github/workflows/release.yml` is therefore **manual-only** (`workflow_dispatch`,
taking an existing tag). Pushing a tag does not start a build. The workflow
remains runnable if CI signing is ever wanted: add the secrets it documents and
dispatch it against a tag. It accepts only tags matching `vX.Y.Z` exactly, and
requires the tagged commit to equal `origin/main` before reading any secret.

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

The dispatched workflow performs tests and unsigned checks before importing
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

## Publish the Appcast

After the GitHub release is public, sign **the published disk image** — not a
local rebuild — and copy the appcast to the site repository.

This matters: DMGs are not reproducible. `codesign` embeds a fresh RFC3161
timestamp on every run, so a locally rebuilt `Waves.dmg` is never byte-identical
to the one CI attached to the release. Signing the local copy produces an
appcast whose EdDSA signature does not match the bytes users download, and
Sparkle rejects the update. `make_appcast.sh` now requires `EXPECTED_SHA256` and
refuses to sign anything else.

Download both assets from the GitHub release, then:

```bash
gh release download "vX.Y.Z" --pattern "Waves.dmg" --pattern "Waves.dmg.sha256" --dir /tmp/waves-release
```

```bash
EXPECTED_SHA256="$(cut -d ' ' -f 1 /tmp/waves-release/Waves.dmg.sha256)" ./script/make_appcast.sh X.Y.Z /tmp/waves-release/Waves.dmg
```

```bash
cp dist/appcast.xml ../Waves-site/public/appcast.xml
```

The script also refuses a build number that is not strictly greater than every
build already in the appcast, since Sparkle compares `sparkle:version`
numerically and would silently never offer the update.

## Update the Site Itself

The appcast alone is not enough, and skipping the rest is not hypothetical — it
already happened. The 1.4.0 publish touched only `public/appcast.xml` and
`src/config/site.ts`, leaving the site's changelog page topped out at 1.3.0 for
the whole release. Sparkle offered 1.4.0 to existing users while the site still
described 1.3.0.

Three files, every time:

```bash
cp CHANGELOG.md ../Waves-site/src/data/CHANGELOG.md
```

Then in `../Waves-site/src/config/site.ts` set `version`, `downloadUrl` (the
`vX.Y.Z` tag in the URL), and `dmgSizeLabel` — read the real size from the
downloaded asset rather than guessing:

```bash
ls -lh /tmp/waves-release/Waves.dmg
```

Confirm before deploying:

```bash
grep -n "version\|downloadUrl\|dmgSizeLabel" ../Waves-site/src/config/site.ts
head -12 ../Waves-site/src/data/CHANGELOG.md
grep -c "sparkle:version" ../Waves-site/public/appcast.xml
```

Review the site change, then deploy the site through its normal release process
(`bun run build && npx wrangler deploy`), and verify what is actually live —
not what you uploaded:

```bash
curl -s https://waves.jonathanrreed.com/appcast.xml | grep -m1 shortVersionString
curl -s https://waves.jonathanrreed.com/ | grep -o "releases/download/v[0-9.]*/Waves.dmg" | sort -u
```

## Update the Homebrew Tap

`brew install --cask jonathanrreed/tap/waves` installs from
[JonathanRReed/homebrew-tap](https://github.com/JonathanRReed/homebrew-tap),
which is a separate repository from the `Casks/waves.rb` template in this one.
Updating only the template updates nobody: the tap sat on 1.3.0 for the whole
1.4.0 release, so every `brew install` served a two-releases-old build.

In the tap's `Casks/waves.rb`, set `version` and `sha256` — the checksum of the
**published** DMG, from the asset you downloaded back:

```bash
cut -d ' ' -f 1 /tmp/waves-release/Waves.dmg.sha256
```

Then confirm it parses and the checksum is the one users will fetch:

```bash
ruby -c Casks/waves.rb && brew audit --cask ./Casks/waves.rb
```

## Release Channels Checklist

Four places carry a version, and a release is not finished until all four agree.
Each has been missed at least once:

- [ ] GitHub release (tag, DMG, checksum, dSYM)
- [ ] `appcast.xml` on the site — Sparkle
- [ ] `site.ts` and `src/data/CHANGELOG.md` on the site — the download button
- [ ] `Casks/waves.rb` in the tap repo — Homebrew

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
