# Release Checklist

Use this checklist before publishing a Waves build. None of the local commands
below create or push a tag, publish a release, change repository visibility, or
upload a release artifact. The hosted verification workflow is manual and
accepts an exact revision only. It does not access signing credentials, accept
tags, sign, notarize, or publish releases.

## Current release boundary

The latest published release is Waves 1.7.4 build 22, published on 2026-11-14
from signed tag `v1.7.4` at revision `88196a37fef2ffd4def1f42c0f1e40473d5d11a3`.
`release/metadata.json` on this revision still describes it. Whether a version
is published is decided by its signed `vX.Y.Z` tag, the GitHub release, and the
Sparkle appcast, never by this document; `script/verify-publication.rb` checks
all four public channels.

Source changes on `main` after the latest release tag are unreleased. They are
listed under `[Unreleased]` in `CHANGELOG.md` and are not published until a new
candidate passes its candidate and publication gates.

The separately versioned Stream Deck companion at
`/Users/jonathanreed/Downloads/waves-streamdeck` must pass its Bun typecheck,
unit tests, validator, package build, and live packaged-Waves socket test over
protocol version 1. The companion is not bundled in Waves. A second Golden Gate
machine should still verify real Wave Link and physical Stream Deck hardware,
including both launch orders, claimed and unclaimed apps, mixed output, device
changes, relaunch, route arbitration cycles, dial changes, mute synchronization,
and automatic recovery. This remote result remains required before claiming
verified physical Elgato compatibility. Any publication waiver is bound to one
release's evidence and does not carry forward.

## Evidence gates

Each sealed evidence manifest identifies the exact revision and clean-tree
state, absence of untracked build inputs, source-archive and build-recipe
hashes, toolchain, and these results, all against the exact candidate:

- `tests`: passed and failed counts for the ordinary Swift suite, the rendered
  UI cases, and the Thread Sanitizer harness.
- `performance`: launch time, idle CPU, steady memory, and active mixing
  against the previous release, each within 10 percent or an approved
  exception. Comparisons are optional: with `benchmarkDeferral` in metadata,
  every metric is recorded as `deferred` with the approved reason.
- `platforms`: native, Rosetta, macOS 26, and macOS 15 runs, with macOS 15
  deferrable through `releaseDeferral`; a physical macOS 14 host is recorded
  honestly as unavailable.
- `package`: identity, universal architectures, deployment floor, app, DMG
  and dSYM hashes, Developer ID, hardened runtime, notarization bound to the
  DMG, stapling, and Gatekeeper.
- `gates`: `localQA`, `securityScan`, `sanitizer`, `routeLifecycleStress`,
  `socketStress`, `boundedRuntimeCheck`, `updater`, `renderedUI`,
  `pluginTypecheck`, `pluginUnitTests`, `pluginValidation`, `pluginPackage`,
  `pluginLiveSocket`, `packageVerification`, and `remoteElgato`, which is
  deferrable through `releaseDeferral`.
- `externalReceipts`: the security-review receipt, and the remote Elgato
  receipt unless that gate is deferred, both bound to the revision and DMG.

`boundedRuntimeCheck` is a short run of the signed candidate in an isolated
home: an owned audio fixture plays, the candidate discovers and manages it and
applies volume and mute changes over the control socket, then it stays up and
answers requests with the audio stopped. It records the whole seconds of the
active and idle phases in `activeSeconds` and `idleSeconds`. It is not a soak.
The release owner retired the 4-, 12- and 72-hour soaks and the 30-run launch
protocol on 2026-11-14; no release requires them. For 1.7.4 the harness was
`dist/release-1.7.4-preparation/run-qa.py` on the release Mac, which is not
tracked.

Evidence never records a check as passed that was not run. A check that cannot
run is deferred through `release/metadata.json` with the owner's approval, or
the release waits. A source build or local package check cannot substitute for
any missing field.

`release/metadata.json` is the only release value and trust-policy authority. Its strict reader
rejects malformed JSON, duplicate or unknown keys, noncanonical versions and
deployment floors, nonpositive build numbers, and any bundle or Developer ID
identity other than the pinned Waves values. The build, appcast, package,
workflow, changelog, cask, and evidence checks all read that file rather than
carrying their own defaults. It also pins the SSH release-tag principal and
public key, the external-receipt issuers, and the Waves-specific Sparkle account
and Ed25519 public key. Private keys and Keychain contents never belong in this
file.

For 1.7.4 build 22, Jonathan approved deferring the macOS 15 runtime test, the
hands-on Stream Deck and device matrix, and fresh performance comparisons on
2026-11-14. The metadata records that approval for that release only; a new
version and build must not inherit it. Tests, security,
sanitizers, stability, local QA, platform coverage, package verification,
Developer ID signing, notarization, stapling, Gatekeeper, provenance, and
artifact validation must be recorded against the exact candidate.

## Publish sequence

This is the order 1.7.4 was published in. Each step is detailed below.

1. Prepare metadata, `CHANGELOG.md`, the cask template version, and the
   `VERSION` and `BUILD` constants and tracked-deferral assertions in
   `script/tests/release_infra_test.rb`. Merge to `main` with a plain
   `git push` (`script/release_git` strips credentials) and wait for CI on the
   exact revision.
2. `build_and_run.sh --notarize`, then `--publication-check` and
   `--package-smoke` on the same package.
3. Run the bounded runtime check, the Rosetta launch and the companion checks
   against the signed candidate. Assemble `dist/release-evidence-input.json`
   and the security-review receipt, citing the CI run for counts that came
   from CI.
4. Seal candidate evidence and run `release-gate.sh candidate`.
5. Collect the remote Elgato receipt, or record its approved deferral.
6. Seal publication evidence, generate the tag envelope, create the signed
   tag with `git tag -s vX.Y.Z -F dist/release-tag-annotation.txt`, and run
   `WAVES_RELEASE_TAG=vX.Y.Z ./script/release-gate.sh publication`.
7. `git push origin vX.Y.Z`, then
   `gh release create vX.Y.Z --verify-tag --latest --notes-file <notes>` with
   `Waves.dmg`, `Waves.dmg.sha256`, `Waves.app.dSYM.zip`, the sealed
   publication evidence and its sidecar, `release-source-identity.json`,
   `notary-log.json`, and the receipt files.
8. Download the DMG back from the release and sign the appcast over it.
9. Fetch and rebase the website and tap checkouts before editing or deploying
   either. 1.7.4's first site deploy came from a stale checkout and briefly
   put an old page design live.
10. Update and deploy the site, then update and push the tap.
11. Run `./script/verify-publication.rb`. The release is finished when it
    passes.

## Protected command environment

Execute `script/release-gate.sh`, `script/build_and_run.sh`,
`script/make_appcast.sh`, `script/generate-release-evidence.sh`, and
`script/generate-release-tag-envelope.sh`, and
`script/prepare-elgato-handoff.sh` directly as shown in this checklist. Do not
invoke or source them through another shell. Their `/bin/bash -p` shebang must
run so Bash suppresses `BASH_ENV`, imported shell functions, and inherited
shell-option startup behavior before the first command.

Each entry point then removes every inherited exported variable with Bash
builtins before it launches Ruby, Git, Swift, or an Apple signing tool. It
installs the fixed system `PATH`, a deterministic UTF-8 locale, noninteractive
Git policy with global and system configuration disabled, and fresh private
mode-0700 `HOME` and `TMPDIR` roots. Release metadata, SDK, artifact staging,
Ruby/Gem/Bundler, Git redirection, prompt, shell-startup, and dynamic-loader
variables are not inherited. Release metadata is always the canonical tracked
`release/metadata.json`, and release Ruby commands use `/usr/bin/ruby` with gems
disabled.

Every release Git operation, including the hosted exact-revision check, runs
the tracked `script/release_git` launcher by its repository path. The launcher
clears inherited exports before executing `/usr/bin/git`, disables filesystem
monitors even when checkout-local or included configuration enables one, and
pins SSH tag verification to `/usr/bin/ssh-keygen`. Source-dirty comparisons
also pass `--no-ext-diff --no-textconv`, so checkout-local attributes and diff
drivers cannot execute helper programs. Repository-local configuration remains
available only for ordinary repository semantics that the release checks need;
included configuration cannot override these command-line safety settings.

Only these documented inputs cross the startup boundary, and each is validated
before restoration:

- `SIGN_IDENTITY` and `NOTARY_PROFILE` for `build_and_run.sh --notarize`;
- `WAVES_EXPECTED_REVISION`, `WAVES_RELEASE_EVIDENCE`, and
  `WAVES_RELEASE_TAG` for the matching release-gate phase;
- `WAVES_RELEASE_TAG` and `EXPECTED_SHA256` for appcast publication;
- bounded absolute `SMOKE_LOG_PATH` and positive `SMOKE_SECONDS` values for the
  packaged smoke runner.

The isolated `HOME` does not create, migrate, or select credentials. Developer
ID, notarytool, signed-tag, and Sparkle private material remains in the current
login Keychain or its separately authorized store and is addressed only by the
validated identity, profile, principal, or account name.

## Prepare Release Metadata

Before creating a tag:

- Set the version, positive integer build, minimum macOS version, bundle
  identifier, Developer ID identity, team, and designated requirement once in
  `release/metadata.json`.
- Move the release notes out of `Unreleased` into exactly one matching
  `## [X.Y.Z]` or `## [X.Y.Z] - YYYY-MM-DD` heading in `CHANGELOG.md`.
- Set the same version in `Casks/waves.rb`. The repository contract rejects a
  mismatch between either file and canonical metadata.
- Keep the build strictly greater than the last published build. Sparkle
  compares `sparkle:version` numerically, so a repeated or lower build is never
  offered. `make_appcast.sh` checks the packaged build against canonical
  metadata and the prior appcast before it writes an entry.
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
in CI adds a large blast radius. Anything that can read repository secrets can
sign software as you, and revoking a leaked identity invalidates everything
already shipped. The convenience is not worth that exposure for this project.

One-time setup, which prompts for an app-specific password from appleid.apple.com:

```bash
xcrun notarytool store-credentials waves-notary --apple-id "<apple-id>" --team-id AJ9VWBRNZN
```

Then, for each release:

```bash
SIGN_IDENTITY="Developer ID Application: Jonathan Reed (AJ9VWBRNZN)" NOTARY_PROFILE=waves-notary ./script/build_and_run.sh --notarize
```

The release environment keeps its build `HOME` private. It resolves the active
macOS account through Directory Services, validates that account's home and
login keychain ownership, passes that keychain explicitly to `codesign`, and
gives only the validated account home to a minimal `notarytool` child process.
The signing identity and named notary profile are checked before either
universal architecture begins compiling.

`.github/workflows/release.yml` is manual-only and accepts an exact lowercase
40-character revision. Pushing a tag does not start a build. The workflow has
one read-only verification job, contains no credentialed signer, and uploads
only 14-day verification logs. Hosted signing must be designed as a separate,
approved trusted-signer system before it can return. It cannot be enabled by
adding secrets to the current workflow.

## Unsigned or Ad Hoc Local Validation

The shared gate below requires normal macOS build/package tools, but does not
require a Developer ID certificate or notarization credentials:

```bash
./script/quality-gate.sh full
```

The same checked-in command runs locally and in CI. It applies process-group
deadlines to strict Swift formatting, debug and release builds, the ordinary
isolated test suite, focused Thread Sanitizer tests, universal package
construction, package verification, packaged GUI smoke, the realtime callback
audit, and release-infrastructure self-tests.

`--release-check` is the fresh distribution build path. It rejects caller
metadata and SDK overrides, ignores caller `PATH` for compiler selection, and
accepts only a root-owned Apple developer directory, SDK, and Swift compiler.
It rejects tracked changes and ordinary or ignored untracked build inputs,
creates an exact Git archive in a private temporary source tree, and uses new
private SwiftPM scratch directories for both slices. It builds arm64 and x86_64,
stamps the full source revision plus source-archive and build-recipe hashes into
`Info.plist`, creates and validates `Waves.app`, and creates a matching universal
`Waves.app.dSYM` when `dsymutil` is available. It then renders the checked-in
660 by 430 Waves background, creates a writable image, configures a 660 by 430
Finder window with 128-point app and Applications icons, and converts the
verified result to `Waves.dmg`. The common package checks run inside one fresh
mode-0700 root. Only
finalized, hash-identical outputs are copied to `dist` through guarded atomic
publication. Without `SIGN_IDENTITY`, the app is ad hoc signed for local
validation.

`--verify` first copies the existing app, dSYM, and DMG into one fresh private
root, then validates only that stable snapshot. It does not build or recreate
them. `--package-smoke` uses the same private snapshot, mounts its DMG, launches
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
- The DMG has exactly two visible root items, `Waves.app` and `Applications`,
  with `Applications` linking to `/Applications`. The only hidden layout inputs
  are `.background/Waves.png` and Finder's `.DS_Store`; the canonical renderer
  bytes, background dimensions, item types, and absence of hidden executables
  are reverified after mounting.
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

Build, sign, submit, and staple using canonical release metadata:

```bash
SIGN_IDENTITY="Developer ID Application: Jonathan Reed (AJ9VWBRNZN)" \
NOTARY_PROFILE="waves-notary" \
./script/build_and_run.sh --notarize
```

The notarized build publishes the exact archive-backed source identity, Apple
notarization log, DMG checksum, and zipped dSYM beside the finalized app and
DMG. Confirm those generated files describe the same candidate before building
the evidence input:

```bash
test "$(/usr/bin/ruby --disable-gems -rjson -e \
  'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("revision")' \
  dist/release-source-identity.json)" = "$(./script/release_git rev-parse HEAD)"
test "$(cut -d ' ' -f 1 dist/Waves.dmg.sha256)" = \
  "$(shasum -a 256 dist/Waves.dmg | cut -d ' ' -f 1)"
/usr/bin/unzip -t dist/Waves.app.dSYM.zip
```

Then assemble the complete evidence input and seal the exact local
candidate. Candidate sealing allows only remote Elgato to remain pending and
always records `publicationEligible: false`:

```bash
./script/generate-release-evidence.sh candidate \
  dist/release-evidence-input.json \
  dist/release-evidence.candidate.json
WAVES_RELEASE_EVIDENCE=dist/release-evidence.candidate.json \
  ./script/release-gate.sh candidate
```

The generator writes canonical key-ordered JSON plus a SHA-256 sidecar. The
candidate gate never signs, notarizes, tags, uploads, or publishes. It validates
the clean exact revision, source history, app, DMG, dSYM, universal
architectures, deployment floor, exact Developer ID identity, team, designated
requirement, hardened runtime, notarized Developer ID status, stapling,
Gatekeeper, source stamps, and artifact hashes. Trust values are derived from
the app and DMG instead of being accepted from the evidence input.

## Prepare the remote Elgato handoff

Only after the candidate gate passes, prepare the exact remote Wave Link and
Stream Deck test kit. The separately packaged plugin must come from a clean,
tested plugin checkout, and `PLUGIN_40_CHARACTER_REVISION` must be replaced by
that checkout's exact lowercase revision. The output directory must not exist.

```bash
./script/prepare-elgato-handoff.sh \
  /ABSOLUTE/PATH/TO/dist/release-evidence.candidate.json \
  /ABSOLUTE/PATH/TO/com.jonathanreed.waves.streamDeckPlugin \
  PLUGIN_40_CHARACTER_REVISION \
  /ABSOLUTE/PATH/TO/Waves-X.Y.Z-BUILD-Elgato-Handoff
```

The command reruns the complete candidate gate, privately snapshots and
verifies the signed Waves app, DMG, and dSYM, binds the exact DMG and plugin
hashes to their source revisions, generates the ordered hardware checklist,
diagnostic collector, rollback guide, pending result record, and receipt
finalizer, verifies the exact handoff file set, then publishes the completed
directory atomically. It does not sign, notarize, tag, push, upload, or publish.

The remote tester verifies `SHA256SUMS`, installs the included DMG and plugin,
runs every checklist group, records each result in `results.json`, collects the
bounded diagnostics, and runs the included `finalize-receipt.rb`. The returned
receipt is accepted only when every required result passes and the receipt is
bound to the handoff revision, DMG, plugin revision and hash, candidate
evidence, and returned diagnostic tree. The finalizer accepts only the named
diagnostic files, caps each file at 10 MiB and the complete tree at 32 MiB, and
rejects symlinks. `ELG-001` remains open until this kit is generated from and
delivered with the final signed and notarized candidate.

After remote Wave Link and Stream Deck hardware evidence passes, seal the
publication profile and create the annotated-tag envelope for review. These
commands still do not create the tag:

```bash
./script/generate-release-evidence.sh publication \
  dist/release-evidence-input.json \
  dist/release-evidence.publication.json
./script/generate-release-tag-envelope.sh \
  dist/release-evidence.publication.json \
  dist/release-tag-annotation.txt
```

Only a cryptographically signed annotated `vX.Y.Z` tag whose annotation embeds
that canonical manifest and sidecar hash can pass
`./script/release-gate.sh publication`. Git verifies the SSH signature against
the public key and `waves-commit-signing` principal pinned in canonical metadata,
without using global Git signing configuration. A lightweight or unsigned tag,
wrong key or principal, wrong revision, dirty tree, a tag outside the current
`HEAD` ancestry, missing or skipped gate, pending remote result, or changed
artifact hash fails.
The manifest also binds the security-scan and remote-Elgato receipt digests to
the exact source revision and DMG, and binds the Apple notary-log digest and
submission to that same DMG.

Publication validation reuses all unsigned package checks and additionally
requires:

- The exact Waves Developer ID Application identity and Team ID `AJ9VWBRNZN`.
- The exact designated requirement pinned in canonical metadata.
- Hardened runtime and a valid sealed app bundle.
- Gatekeeper acceptance of the app.
- A valid stapled notarization ticket and Gatekeeper acceptance of the DMG.

The manual hosted workflow is verification-only. Its single job uses the same
quality and release-preflight scripts, pinned actions, bounded execution,
serialized noncanceling concurrency, and 14-day log retention. It accepts an
exact revision rather than a tag and cannot access signing credentials, sign,
notarize, upload a candidate, or create a release. The maintainer Mac remains
the only Waves release-signing authority.

## Publish the Appcast

After the GitHub release is public, sign **the published disk image**, not a
local rebuild, and copy the appcast to the site repository.

This matters: DMGs are not reproducible. `codesign` embeds a fresh RFC3161
timestamp on every run, so a locally rebuilt `Waves.dmg` is never byte-identical
to the one CI attached to the release. Signing the local copy produces an
appcast whose EdDSA signature does not match the bytes users download, and
Sparkle rejects the update. `make_appcast.sh` treats `EXPECTED_SHA256` only as a
transport check. Before it can access the Sparkle key, it also requires the
exact annotated publication tag, embedded sealed evidence, recomputed app, DMG,
and dSYM hashes, the pinned Waves signer and designated requirement, hardened
runtime, notarized Gatekeeper acceptance, and a valid stapled ticket.

Download the DMG and checksum from the GitHub release. Retain the exact dSYM
binary sealed in publication evidence, then run:

```bash
gh release download "vX.Y.Z" --pattern "Waves.dmg" --pattern "Waves.dmg.sha256" --dir /tmp/waves-release
```

```bash
WAVES_RELEASE_TAG="vX.Y.Z" \
EXPECTED_SHA256="$(cut -d ' ' -f 1 /tmp/waves-release/Waves.dmg.sha256)" \
  ./script/make_appcast.sh X.Y.Z /tmp/waves-release/Waves.dmg
```

The script ignores every persistent `.build` cache and rejects `SIGN_UPDATE`
and artifact-path overrides. It privately stages the downloaded DMG, canonical
dSYM, and existing appcast before validation, creates a fresh exact-revision
source archive and SwiftPM scratch root, uses the exact checked-in
`Package.resolved`, and executes only the isolated Sparkle `generate_keys` and
`sign_update` tools. It names account `com.jonathanreed.Waves` explicitly,
requires the account public key to equal both canonical metadata and the
packaged `SUPublicEDKey`, verifies the signature over the staged DMG, and
atomically publishes only the finalized appcast.

The Sparkle account is intentionally not created or migrated by these scripts.
Candidate building, Developer ID signing, notarization, and candidate gates do
not require it. Appcast publication fails closed until a separately authorized
Keychain setup provisions that exact account with the matching private key.
The finished `dist/appcast.xml` goes to the site in the next section.

The script also refuses a build number that is not strictly greater than every
build already in the appcast, since Sparkle compares `sparkle:version`
numerically and would silently never offer the update.

## Update the Site Itself

The appcast alone is not enough, and skipping the rest is not hypothetical — it
already happened. The 1.4.0 publish touched only `public/appcast.xml` and
`src/config/site.ts`, leaving the site's changelog page topped out at 1.3.0 for
the whole release. Sparkle offered 1.4.0 to existing users while the site still
described 1.3.0.

Bring the site checkout up to date first. 1.7.4's first deploy came from a
checkout that was behind the site repository and briefly put an old page design
live:

```bash
git -C ../Waves-site fetch origin && git -C ../Waves-site rebase origin/main
```

Then four files, every time (`src/lib/content-dates.json` carries the dates for
`/` and `/changelog/`):

```bash
cp dist/appcast.xml ../Waves-site/public/appcast.xml
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

Run the site's own gate, push, and deploy. The site's `Deploy` workflow deploys
after its CI passes on `main`; if that CI is failing, deploy by hand from the
rebased checkout. Then verify what is actually live, not what you uploaded:

```bash
bun install --frozen-lockfile && bun run check && bun test && bun run release:check && bun run build
npx wrangler deploy
curl -s https://waves.jonathanrreed.com/appcast.xml | grep -m1 shortVersionString
curl -s https://waves.jonathanrreed.com/ | grep -o "releases/download/v[0-9.]*/Waves.dmg" | sort -u
```

## Update the Homebrew Tap

`brew install --cask jonathanrreed/tap/waves` installs from
[JonathanRReed/homebrew-tap](https://github.com/JonathanRReed/homebrew-tap),
which is a separate repository from the `Casks/waves.rb` template in this one.
Updating only the template updates nobody: the tap sat on 1.3.0 for the whole
1.4.0 release, so every `brew install` served a two-releases-old build.

After GitHub publishes the DMG and you download it back, fetch and rebase the
tap checkout, then update its `Casks/waves.rb` with the published version and
checksum. Keep its other stanzas the same as this repository's template:

```bash
git -C ../homebrew-tap fetch origin && git -C ../homebrew-tap rebase origin/main
published_sha="$(shasum -a 256 /tmp/waves-release/Waves.dmg | cut -d ' ' -f 1)"
/usr/bin/ruby -e 'path = ARGV.fetch(0); version = ARGV.fetch(1); sha = ARGV.fetch(2); text = File.read(path); text.sub!(/^  version ".*"$/, "  version \"#{version}\"") or abort "version line missing"; text.sub!(/^  sha256 ".*"$/, "  sha256 \"#{sha}\"") or abort "sha256 line missing"; File.write(path, text)' ../homebrew-tap/Casks/waves.rb X.Y.Z "$published_sha"
```

Push it, then audit the published cask. `brew audit` does not accept a path and
reads Homebrew's own clone of the tap, so update that clone first:

```bash
ruby -c ../homebrew-tap/Casks/waves.rb
git -C "$(brew --repo jonathanrreed/tap)" pull --ff-only
brew audit --cask --online --strict jonathanrreed/tap/waves
```

## Release Channels Checklist

Four places carry a version, and a release is not finished until all four agree.
Each has been missed at least once:

- [ ] GitHub release (tag, DMG, checksum, dSYM)
- [ ] `appcast.xml` on the site — Sparkle
- [ ] `site.ts` and `src/data/CHANGELOG.md` on the site — the download button
- [ ] `Casks/waves.rb` in the tap repo — Homebrew
- [ ] `./script/verify-publication.rb` passes

## Verify Every Channel

The last step of every release. After the GitHub release, site deploy and tap
push, run from any checkout:

```bash
./script/verify-publication.rb
```

It reads only public URLs, needs no credentials, and checks the version and
build in `release/metadata.json` (or `./script/verify-publication.rb X.Y.Z BUILD`):
the GitHub release exists, is not a draft or prerelease, and is the latest; the
DMG downloaded without authentication matches `Waves.dmg.sha256`; the live
appcast's newest item has that version and build, points at that DMG, has its
exact length, and carries an EdDSA signature that verifies over that DMG with
the Sparkle public key pinned in `release/metadata.json`; every download link
on the site points at the release and the newest changelog entry is the
version; the tap cask has the version, a download URL that resolves to that
DMG, and the downloaded DMG's SHA-256. It prints one line per
check and exits non-zero on any mismatch. The release is not finished until it
passes.

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
