# Waves maintenance checkpoint

Date: 2026-09-04. Reviewed implementation head: bcf0413 on codex/waves-1.7.1.

## Completed scope

- Launch telemetry and collector work is reviewed through df1dbf5. The collector binds signposts to the launched process, retains failed attempts and raw evidence, and records reviewable clock synchronization. No real launch set or Half Bounce result has been collected.
- Sparkle now requires and resolves 2.9.6. The dependency review is recorded separately; the change and receipt corrections are reviewed through a30850f. The upstream patched release addresses two high-severity advisories. Exact Waves exploitability was not reproduced.
- Canonical source metadata is 1.7.1 build 19. The cask template matches. README and release notes distinguish that development target from the published 1.7.0 release. The reviewed metadata and documentation commits are 64ce1cd and bcf0413.
- Two strict Swift-format errors were reproduced on the untouched base and corrected without changing tokens or behavior. Production-style release tests now use a consistent set of metadata, changelog, and cask fixture files.

## Direct verification

| Command or observation | Result | Scope |
|---|---|---|
| /usr/bin/ruby script/tests/launch_measurement_test.rb | 13 tests, 92 assertions, no failures, errors or skips; exit 0 | Controller recheck after dependency update |
| swift test --filter updater | Four named updater tests passed; exit 0 | Controller recheck after dependency update |
| swift build -c release | Exit 0, 90.27 seconds | Controller build at 64ce1cd; bcf0413 changes docs only |
| Focused metadata/version/build/cask tests | Red 20 tests/169 assertions with old version mismatch; green 20/171 | Metadata implementation evidence |
| ./script/quality-gate.sh infra | Release tests 106/992, deadline tests 2/5, both contract validators passed; exit 0 | Metadata implementation evidence |
| ./script/quality-gate.sh format | Exit 0 after the two formatting corrections | Metadata implementation evidence and controller recheck |
| /usr/bin/ruby script/release_tool.rb validate-repository | Valid; exit 0 | Controller recheck of canonical metadata and local template |
| Canonical metadata assertion | 1.7.1 and integer build 19; exit 0 | Controller recheck |
| git diff --check | Exit 0 | Implementation and controller checks |

The full candidate quality gate, full current Swift suite, Thread Sanitizer, package smoke, and signed-app tests have not been completed for this candidate. Targeted tests do not replace them.

## Preserved baseline and external state

The installed /Applications/Waves.app remains 1.7.0 build 16. A fresh executable SHA-256 check returned 80d21dd3e0ecccdac92d662bad39fb826398441ec7ce2bfd5c104c1199b8855a, matching the saved baseline. No app installation, capture, preference change, or Dock change occurred in this tranche.

A fresh GitHub query still identified v1.7.0 as latest. The ten open PRs remain #29 and #34 through #42. They have not been closed or merged by this tranche. Sparkle PR #29 is now superseded by the reviewed 2.9.6 update, subject to the planned integration and public disposition steps.

Read-only GitHub advisory queries for swiftlang/swift-testing and swiftlang/swift-syntax each returned an empty list. That means no published repository advisories were returned, not that the dependencies are vulnerability-free.

## Blockers and next action

Codex Security previously refused to create a read-only scan worker because the parent task lacks a managed filesystem permission profile. No scan ID or successful scan receipt exists. The profile has not been changed or bypassed.

Both Macs select CommandLineTools and lack xctrace. The Mac mini's existing prerequisite results were delivered directly after normal task-history retrieval returned empty items. Its task reports managed workspace-write permissions, but its source checkouts remain unsuitable as release source. Neither host can currently provide Instruments measurements with its installed toolchain.

The user has been asked about managed permissions and full Xcode setup. After those prerequisites are resolved, resume the deep scan and real performance baseline. Preserve the installed baseline. Startup optimization must follow measured delay. Candidate signing, hardware checks, publication, and Half Bounce qualification remain open.

No push, merge, tag, release upload, appcast change, external Homebrew mutation, or social post occurred. Existing release authority remains unchanged. Permission changes and Xcode setup await the user's direction.
