# Waves Release Contracts

`metadata.json` is the sole version, build, deployment-floor, bundle identifier,
Developer ID identity, team, and designated-requirement authority for the
current Waves candidate. `script/release_tool.rb` validates and exposes it to
every build, appcast, package, workflow, cask, changelog, and evidence check.

The evidence generator consumes a Task 12 input object with these required
sections:

- exact clean source revision, absence of untracked build inputs, source-archive
  SHA-256, build-recipe SHA-256, and toolchain;
- Swift, rendered UI, and Thread Sanitizer counts;
- launch, idle CPU, memory, and active-mixing comparisons;
- native, Rosetta, Tahoe, Sequoia, and honest Sonoma-host results;
- bundle identity, universal architectures, deployment floor, app/DMG/dSYM
  hashes, exact Developer ID identity, team, designated requirement, hardened
  runtime, notarization UUID, stapling, and Gatekeeper;
- local QA, security, sanitizer, stress, updater, soak, plugin, live socket, and
  remote Elgato results;
- skipped-gate and source-changing skip-CI equivalence records.

Candidate sealing requires every local field to pass and permits only
`remoteElgato` to remain pending. Publication sealing additionally requires the
remote result to pass. `publicationEligible` is derived by the validator and is
never trusted from input.

Generated evidence is canonical key-ordered JSON with a SHA-256 sidecar. The
publication tag annotation embeds the canonical JSON and its digest, avoiding a
self-referential tracked manifest while binding evidence to the exact tagged
revision and artifact hashes. The scripts validate only. They never sign,
notarize, create tags, push, upload, deploy, or publish.

Distribution builds reject tracked changes and both ordinary and ignored
untracked build inputs. They archive the exact Git revision into a private
temporary source tree, build both architectures in new private SwiftPM scratch
directories, and stamp the full revision, source-archive digest, and build-recipe
digest into `Info.plist`. The release gate derives those values and every trust
fact from the packaged artifact before comparing them with sealed evidence.

The focused Thread Sanitizer phase uses an isolated macro-free package graph.
It copies the exact production sources plus the tracked `Package.resolved`,
disables automatic dependency resolution, and exercises real AppStore,
persistence, Unix-socket control, and route-actor coordination. The isolated
graph omits only the SwiftUI `@main` file and supplies its three value-only
compile declarations. This avoids instrumenting the pinned Swift Testing macro
plugin while keeping sanitizer failure strict.
