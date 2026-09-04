# Waves 1.7.1 task contract

## Objective and completion boundary

- Terminal objective: Finish Waves 1.7.1 build 19 as a secure, measured,
  Half-Bounce-qualified, signed, hardware-verified, publication-ready release,
  then complete the authorized public release pipeline.
- Current completion claim: Planning and baseline tranche only.
- Observable result for the active tranche: Approved design, task contract, and
  decision trail committed on `codex/waves-1.7.1` after a passing baseline test.

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
- Last verified checkpoint: `swift test` passed 626 tests on the branch base.

## Priority scope

1. Adjudicate every open PR and complete the deep security repair.
2. Measure and improve the whole app, including honest Half Bounce qualification.
3. Build, sign, verify on Mac mini, and complete every public release surface.

## Deferred, external, and out of scope

- Deferred: Public X posting waits for Jonathan's approval of final media and
  copy.
- External blocker: None at present. Mac mini is connected and hardware-suitable.
- Out of scope: New features, redesign, protocol changes, new minimum macOS,
  credential rotation, repository visibility changes, and paid services.

## Evidence available

- Direct receipts: Clean `origin/main` at `d2ac715`; 626 passing baseline tests;
  GitHub, appcast, and Homebrew publish 1.7.0 build 16; Mac mini inventory proves
  the Elgato environment; private `waves-streamdeck` repository exists.
- Prior claims or stale evidence: Existing PR descriptions and earlier release
  receipts remain proposals or historical evidence until revalidated.
- Inferences: Build 19 is the first safe public build after known unpublished
  build 18.
- Unknowns: Current 1.7.0 launch and runtime measurements, final security
  findings, and the combined behavior of repaired PRs.

## Acceptance gates

| Gate | Required now | Required evidence | Status | Direct receipt |
|---|---|---|---|---|
| Functionality | Yes | Focused tests, 626-test suite or higher, full quality gate | Baseline passed | `swift test`, 626 passed |
| UX and accessibility | Yes | Hosted/rendered tests and real installed-app interaction | Not run | |
| Runtime and performance | Yes | Baseline/candidate matrix, callback stress, soak, 30 launch recordings | Not run | |
| Data and provenance | Yes | Exact revisions, hashes, canonical metadata, evidence receipts | Partial | Branch base and public release inspected |
| Security and privacy | Yes | Deep scan, finding dispositions, final receipt, secret/dependency checks | Not run | |
| Packaging and trust | Yes | Signed/notarized/stapled candidate, Gatekeeper, universal app and dSYM | Not run | |
| Deployment and release | Yes | Mac mini receipt, exact tag, GitHub, appcast, site, Homebrew, public hashes | Not run | |

## Authority

- Edits: Approved.
- Dependency additions: Approved when justified and verified.
- Deletion or destructive action: Only scoped replacement or cleanup required by
  the design. No history rewrite or broad deletion.
- Commit, push, pull request, merge, and tag: Approved for this release after
  their stated gates pass.
- Deployment and production changes: Approved for GitHub release, appcast,
  Waves website, and Homebrew after the publication gate passes.
- Spending or billing: Not approved or required.
- Credential or permission changes: Not approved. Existing signing and
  notarization credentials may be used through documented commands.

## Active bounded vertical tranche

- Scope: Record the approved design and establish the verified branch baseline.
- Observable state change: Planning artifacts committed on the release branch.
- Checks and receipts required before closure: Complete design self-review,
  `git diff --check`, baseline test receipt, and clean commit.
- One next tranche: Write the implementation plan and begin baseline security
  and performance measurement.

## Instruction changes

| New instruction | Classification | Contract effect |
|---|---|---|
| Cover every PR | Add | Every open PR requires a disposition, not an automatic merge. |
| Enter Half Bounce Club | Add | Honest completed audio control before Dock settlement is a release goal. |
| Finish the entire pipeline | Add | Public distribution is in scope after all gates pass. |
| Use latest release plus 0.1 | Replace | Target remains 1.7.1, but known build 18 changes the build number to 19. |

## Stop rule

Do not begin another tranche until this tranche's design, baseline, diff check,
and commit receipts are recorded. Later artifact changes invalidate downstream
candidate and publication receipts.
