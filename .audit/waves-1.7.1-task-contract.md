# Waves 1.7.1 task contract

## Objective and completion boundary

- Terminal objective: Finish Waves 1.7.1 build 19 as a secure, measured,
  Half-Bounce-qualified, signed, hardware-verified, publication-ready release,
  then complete the authorized public release pipeline.
- Current completion claim: Reviewed PR security repairs, launch measurement
  tooling, a Sparkle 2.9.6 dependency update, and source metadata for 1.7.1
  build 19. The release itself is incomplete.
- Observable result for the latest tranche: Verify the installed toolchain and
  a reviewed runtime collector while preserving the installed baseline and
  keeping missing performance evidence explicit.

## Current state

- Active product and working directory: Waves at
  `/Users/jonathanreed/Downloads/Waves`.
- Repository, branch, remote, revision: `JonathanRReed/Waves`,
  `codex/waves-1.7.1`, `origin`, based on
  `d2ac715a14e290a7e8b301820b3fcdb1e149e77c`.
- Dirty-work ownership: The branch starts clean. All new changes belong to this
  1.7.1 effort.
- Running process or application: Installed local Waves 1.7.0 build 16. Mac mini
  has Waves 1.7.0 build 18, Wave Link 3.2.2, Stream Deck 7.5.0, and a physical
  Stream Deck Plus.
- Desired endpoint: One exact 1.7.1 build 19 artifact published consistently
  after every code, security, performance, trust, and hardware gate passes.
- Last verified checkpoint: Hosted full gate passed at 4c9176d, including the
  reviewed checksum repair. With full Xcode 27 installed, a fresh local run of
  the built TSan executable passed three scenarios. The runtime collector
  passed independent review, 19 tests with 124 assertions, and a real
  synchronized Instruments smoke on an owned process. The collector commit
  requires its own hosted run. This is not a completed runtime audit.
  Direct receipts are in
  `.audit/evidence/2026-09-04-waves-1.7.1-premerge-gates.md`.

## Priority scope

1. Adjudicate every open PR and complete the deep security repair.
2. Measure and improve the whole app, including honest Half Bounce qualification.
3. Build, sign, verify on Mac mini, and complete every public release surface.

## Deferred, external, and out of scope

- Deferred: Public X posting waits for Jonathan's approval of final media and
  copy.
- External blockers: The local security invocation remains blocked under the
  unmanaged permission profile. The existing Mac mini audit task reports an
  account usage limit until September 11 and did not start a scan. No scan ID
  exists. Full Xcode, xctrace and Icon Composer are now verified locally.
  Actual performance qualification and fresh Mac mini hardware evidence remain
  open. Earlier remote hardware inventory is historical, not candidate proof.
- Out of scope: New features, redesign, protocol changes, new minimum macOS,
  credential rotation, repository visibility changes, and paid services.

## Evidence available

- Direct receipts: `.audit/evidence/2026-09-04-planning-baseline.md` records the
  exact branch base, passing 626-test run, public release state, and companion
  repository check. `.audit/evidence/2026-09-04-mac-mini-inventory.md` records
  the remote Elgato environment and source-state boundary.
- Prior claims or stale evidence: Existing PR descriptions and earlier release
  receipts remain proposals or historical evidence until revalidated.
- Inferences: Build 19 is the first safe public build after known unpublished
  build 18.
- Unknowns: Current 1.7.0 launch and runtime measurements, final security
  findings, and the combined behavior of repaired PRs.

## Acceptance gates

| Gate | Required now | Required evidence | Status | Direct receipt |
|---|---|---|---|---|
| Functionality | Yes | Focused tests, full Swift suite, full quality gate | Hosted full gate passed at 4c9176d; newer collector tooling requires fresh CI | `.audit/evidence/2026-09-04-waves-1.7.1-premerge-gates.md` |
| UX and accessibility | Yes | Hosted/rendered tests and real installed-app interaction | Hosted and five rendered tests passed; installed-app interaction pending | `.audit/evidence/2026-09-04-waves-1.7.1-premerge-gates.md` |
| Runtime and performance | Yes | Baseline/candidate matrix, callback stress, soak, 30 launch recordings | Collector reviewed and native recording verified; actual app qualification pending | `.audit/evidence/2026-09-04-waves-1.7.1-runtime-audit.md` |
| Data and provenance | Yes | Exact revisions, hashes, canonical metadata, evidence receipts | Partial | `.audit/evidence/2026-09-04-planning-baseline.md` |
| Security and privacy | Yes | Deep scan, finding dispositions, final receipt, secret/dependency checks | Targeted repairs reviewed; dependency updated; deep scan blocked | `.audit/evidence/2026-09-04-sparkle-dependency-review.md` |
| Packaging and trust | Yes | Signed/notarized/stapled candidate, Gatekeeper, universal app and dSYM | Universal ad hoc app, matching dSYM, DMG and package smoke passed; public trust checks pending | `.audit/evidence/2026-09-04-waves-1.7.1-premerge-gates.md` |
| Deployment and release | Yes | Mac mini receipt, exact tag, GitHub, appcast, site, Homebrew, public hashes | Not run | |

## Authority

- Edits: Approved.
- Dependency additions: Approved when justified and verified.
- Deletion or destructive action: Only scoped replacement or cleanup required by
  the design. No history rewrite or broad deletion.
- Commit, push, pull request, merge, and tag: Approved by Jonathan's latest
  instruction, "Proceed doing anything you need to do. fully approved
  /yolomode", in response to the named setup and integration blockers.
  Preserve history, use reviewed branches and normal PR integration, and keep
  release tags and publication behind the existing evidence gates.
- Deployment and production changes: Approved for GitHub release, appcast,
  Waves website, and Homebrew after the publication gate passes.
- Spending or billing: Not approved or required.
- Toolchain and permission setup: Approved for the scoped Waves workflow.
  Use supported settings and existing secure credentials. Apple sign-in,
  administrator authentication, MFA and OS consent still require the user
  when the platform demands user presence. No credential export or bypass.

## Authorized resumption

- Jonathan approved the previously requested setup and repository integration.
  The earlier blocked audit is historical; this resumed run starts a fresh
  audit. Approval does not waive any security, trust, performance or hardware
  requirement.
- Official Apple requirements list Xcode 27 beta 6 for these macOS 27 hosts.
  The local Mac has 43 GiB free; Mac mini reports 13 GiB. Both require Apple
  Developer sign-in and administrator authentication. No Xcode installation
  or global developer selection change has occurred.
- The Apple sign-in page is open for user handoff. Computer Use refuses to
  operate Codex itself, so its task permissions were not changed through UI
  automation. The current profile remains unmanaged; the deep scan was not
  retried under that unchanged profile.
- Proceed with the reviewed private companion PR and a draft Waves PR for
  hosted full-gate evidence. The Waves draft must not merge before its open
  security and performance prerequisites pass. No publication is authorized
  ahead of the candidate and physical verification gates.
- Companion integration complete: private PR 1 merged as
  4e16fe567daffa3ae6405023b0322daa03f9b399. Clean origin/main rebuild passes
  11 tests and package validation. See the companion evidence receipt.
- Waves draft PR 43 opened at 64daff18863623cba84809f8357e3a2ed2eddafa.
  Hosted CI run 33937199553 passed the full gate in 15 minutes 51 seconds,
  including TSan. Of three review findings, the checksum snapshot race was
  repaired and independently approved in 61853b9. Listener waits remain
  unproven for the Darwin path; exact 0700 would break read-only publication.
  Both rejected suggestions have evidence-backed inline replies. The newer
  checksum commit and receipt updates need their own hosted result.
- Remote scan alternative: The existing Mac mini task was authorized to create
  an isolated audit-only checkout of that pushed revision and invoke the
  official deep scan under its existing managed profile. Its latest result is
  an account usage failure. No scan-start success or scan ID has been observed.
  Neither old remote checkout nor this audit clone can supply release bytes.

## Active bounded vertical tranche

- Scope: Verify source gates and an isolated unsigned package at the current
  revision, then preserve a reproducible sanitizer failure diagnosis.
- Observable state change: Passing source checks and failed or blocked checks
  are distinguished in the premerge receipt. The installed baseline and the
  original dist artifacts remain untouched.
- Checks and receipts required before closure: Tests, infra, format, builds,
  callback audit, TSan diagnosis, package check, and direct receipts.
- Tranche result: Closed with observed passes and a diagnosed TSan startup
  failure. The release gate is not complete. No processes remain from these
  checks, and no application source was changed.
- One next tranche: Resolve the managed scan and toolchain prerequisites, then
  rerun TSan and collect real baseline measurements before startup optimization.

## Historical continuation, companion verification

- The prior code/package tranche made progress and is closed with its explicit
  TSan failure. Setup questions remain unanswered and are not treated as consent.
- Active scope: Verify the independent Stream Deck companion from private
  repository main at 8b876e2230105a3c8fb40de0ed9141febeb0865f. Its temporary
  clone is /tmp/waves-companion-verification.ctU3vJ/checkout, on a separate
  codex/waves-1.7.1-companion-maintenance branch.
- Saved checkout: /Users/jonathanreed/Downloads/waves-streamdeck. The reviewed
  diff, base revision, lockfile and package match the temporary checkout.
- Result: Two development dependency resolutions updated, three reproduced
  transport/readiness bugs repaired, and misleading stub-test claims corrected.
  Independent dependency and recovery reviews passed. Node 24 tests pass 11/11,
  external recovery probes pass 3/3, full npm audit reports zero known
  vulnerabilities, and package validation and ZIP integrity pass. Evidence:
  `.audit/evidence/2026-09-04-waves-streamdeck-companion.md`.
- Version check: GitHub still reports v1.7.0 as the latest published release,
  published September 1, 2026. Canonical source remains 1.7.1 build 19, above
  known build 18. No release metadata change was needed in this continuation.
- Required receipts: Original and repaired audit output, exact dependency diff,
  Node 24 tests/build/validation/package, independent review, and package hash.
- Authority: Local maintenance and generated test packages only. No commit,
  push, PR, merge, plugin install, source publication, or Mac mini mutation.
- Tranche status: Local companion repair and review are complete. Task 5 still
  requires authorized source integration and final packaging before handoff.
- Next gate: Resolve the managed security-scan profile and full Xcode setup.
  The local Xcode.app and xctrace are still absent. Then rerun TSan and collect
  actual baseline performance measurements. Do not redo unchanged Swift source
  tests or the companion repair merely to fill the blocked interval.

## Historical blocked continuation audit, superseded by approval above

- Last progress: Completed companion review, verified the repaired client, and
  saved the source and evidence outside temporary storage. The immediately
  preceding goal turn made no progress because setup approval was absent.
- Current continuation: No new implementation or qualifying measurement. The
  full performance plan still needs Instruments, real scenario fixtures, and
  observed controls. Runtime collector source is not yet implemented; it cannot
  be validated against the required Instruments tools on this host today.
- Current prerequisite evidence: Local xcode-select still points to Command
  Line Tools and xctrace is absent. The remote task's retrieved completed result
  confirms the same missing toolchain on Mac mini, with no remote changes.
  This task's filesystem profile remains unmanaged. No approval to install
  Xcode or change permissions has arrived.
- Security boundary: The deep-security-scan skill treats the earlier invocation
  failure as a blocker and forbids starting a replacement scan. No retry,
  alternate scan, permission change, or fabricated security receipt occurred.
- Consecutive no-progress blocked observations since the last completed local
  tranche: 3. A fresh xcode-select/xctrace check returned the same missing
  Instruments result. No setup approval or permission-profile change arrived.
  The blocked-status threshold is met. Mark the goal blocked, not complete,
  until user input or an external setup change permits meaningful progress.
- Required next input: Approval for full Xcode installation, plus a supported
  managed-profile scan continuation. These do not authorize commits or release.

## Instruction changes

| New instruction | Classification | Contract effect |
|---|---|---|
| Cover every PR | Add | Every open PR requires a disposition, not an automatic merge. |
| Enter Half Bounce Club | Add | Honest completed audio control before Dock settlement is a release goal. |
| Finish the entire pipeline | Add | Public distribution is in scope after all gates pass. |
| Use latest release plus 0.1 | Replace | Target remains 1.7.1, but known build 18 changes the build number to 19. |

## Stop rule

Do not begin another tranche until its required checks are observed, explicitly
failed, or named as blocked, and direct receipts are recorded. Later artifact
changes invalidate downstream candidate and publication receipts.
