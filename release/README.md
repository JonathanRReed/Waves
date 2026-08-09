# Waves Release Contracts

`metadata.json` is the sole version, build, deployment-floor, bundle identifier,
Developer ID identity, team, designated-requirement, signed-tag authority,
external-receipt issuer, and Sparkle public-key policy for the current Waves
candidate. `script/release_tool.rb` validates and exposes it to every build,
appcast, package, workflow, cask, changelog, and evidence check. The tracked SSH
and Sparkle public keys are verification material only. Private credentials and
Git signing configuration remain outside the repository.

The Finder disk-image presentation is source-controlled beside the release
scripts. `script/render-dmg-background.swift` draws the 660 by 430 background,
and `script/configure-dmg.applescript` applies the fixed 660 by 430 Finder window,
128-point icons, and drag-to-Applications layout. Package verification mounts the
finished image and rejects different background bytes or unexpected content.

The evidence generator consumes a Task 12 input object with these required
sections:

- exact clean source revision, absence of untracked build inputs, source-archive
  SHA-256, build-recipe SHA-256, and toolchain;
- Swift, rendered UI, and Thread Sanitizer counts;
- launch, idle CPU, memory, and active-mixing comparisons;
- native, Rosetta, Tahoe, Sequoia, and honest Sonoma-host results;
- bundle identity, universal architectures, deployment floor, app/DMG/dSYM
  hashes, exact Developer ID identity, team, designated requirement, hardened
  runtime, notarization UUID, exact DMG binding, notary-log digest, stapling,
  and Gatekeeper;
- local QA, security, sanitizer, stress, updater, soak, plugin, live socket, and
  remote Elgato results;
- immutable security-scan and remote-Elgato receipt digests bound to the exact
  source revision and DMG;
- skipped-gate and source-changing skip-CI equivalence records.

Candidate sealing requires every local field to pass and permits only
`remoteElgato` to remain pending. Publication sealing additionally requires the
remote result to pass. `publicationEligible` is derived by the validator and is
never trusted from input.

Generated evidence is canonical key-ordered JSON with a SHA-256 sidecar. The
publication tag annotation embeds the canonical JSON and its digest, avoiding a
self-referential tracked manifest while binding evidence to the exact tagged
revision and artifact hashes. Publication additionally requires an SSH tag
signature from the pinned `waves-commit-signing` principal and public key. The
scripts validate only. They never create tags, push, upload, deploy, or publish.

Distribution builds reject ambient compiler, SDK, and metadata authority,
tracked changes, and both ordinary and ignored
untracked build inputs. They archive the exact Git revision into a private
temporary source tree, build both architectures in new private SwiftPM scratch
directories, and stamp the full revision, source-archive digest, and build-recipe
digest into `Info.plist`. Assembly, signing, notarization, stapling, validation,
and appcast signing operate on mode-0700 private snapshots with stable identity
and hash checks. Only finalized outputs are copied to `dist` atomically. The
release gate derives source values and every trust fact from the packaged
artifact before comparing them with sealed evidence.

The protected release-sensitive entry points must be executed directly so
their `/bin/bash -p` shebangs suppress shell startup injection. Before any
child interpreter runs, a shared shell-builtin boundary deletes all inherited
exports and restores only the validated inputs documented in
`docs/RELEASE.md`. It then uses a fixed system path, `C.UTF-8`, noninteractive
Git with ambient global and system configuration disabled,
`/usr/bin/ruby --disable-gems`, and new mode-0700 `HOME` and `TMPDIR` roots.
Inherited Ruby, Gem, Bundler, Git redirection, prompt, shell-function, loader,
metadata, SDK, and staging authority cannot reach release operations.

`script/prepare-elgato-handoff.sh` is the only supported remote-hardware kit
assembler. It requires a passing candidate evidence manifest, revalidates the
privately staged signed app, DMG, and dSYM, and creates an exact file set bound
to the Waves source revision, DMG SHA-256, Stream Deck plugin revision and
SHA-256, and candidate evidence. The kit includes an ordered Wave Link and
Stream Deck checklist, bounded diagnostic collector, 1.4.4 rollback procedure,
mutable result record, and a finalizer that emits a canonical remote receipt
only after every result passes. Preparing a kit does not close `ELG-001`; the
final signed candidate must still be delivered and its returned physical
hardware evidence reviewed before publication.

Sparkle publication uses the explicit account `com.jonathanreed.Waves`, derives
its public key through the exact isolated Sparkle tool, requires equality with
the packaged `SUPublicEDKey`, and verifies the produced signature. The release
scripts never provision or migrate that Keychain account, so appcast publication
fails closed until the matching account is separately authorized. Candidate
package creation and notarization remain independent of Sparkle publication.

The focused Thread Sanitizer phase uses an isolated macro-free package graph.
It copies the exact production sources plus the tracked `Package.resolved`,
disables automatic dependency resolution, and exercises real AppStore,
persistence, Unix-socket control, and route-actor coordination. The isolated
graph omits only the SwiftUI `@main` file and supplies its three value-only
compile declarations. This avoids instrumenting the pinned Swift Testing macro
plugin while keeping sanitizer failure strict.
