# Waves 1.7.1 PR adjudication baseline

Date: 2026-09-04. Base: `e7d85d9490db9c53410fb9d02977ba243a2bc560`.

Inventory was fetched with:

```text
git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'
gh pr list --state open --limit 100 --json number,title,headRefOid,mergeStateStatus,statusCheckRollup,url
```

The authoritative open inventory is PR 29 and PRs 34 through 42. PR heads were fetched without checkout. Each focused reproduction ran in a detached temporary worktree created from `origin/pr/N`, then removed. Base comparisons used a separate detached `origin/main` worktree at `d2ac715`. PR 41's focused test failed. The other focused PR tests passed. PR 40 adds no focused test for its non-blocking-connect change, so its passing existing self-proof test does not establish the new property.

| PR | Head SHA | Security property | Main reproduces? | PR checks | Integrated disposition |
|---|---|---|---|---|---|
| #29 | e12204a4899a2a8557b23a881789f2bf2fbd7cdf | Pin Sparkle dependency at 2.9.5 | Inconclusive, dependency-only | Shared quality gate SUCCESS | Review Package.resolved; verified Sparkle 2.9.5. |
| #34 | 465b10f3c36bdd24e5602793258e3ab8ef514221 | Preserve publication branch provenance | No; exact base filter ran 0 tests. PR: 1 run, 9 assertions, pass. | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Focused test passes, but do not integrate while the shared gate fails. |
| #35 | 10846d21d6600a02fb869852a293f42cb59f6d14 | Authenticate Elgato handoff checksums out of band | No; base ran the same 2 tests with 77 assertions. PR added the authentication checks and passed 2 runs, 82 assertions. | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope NEUTRAL; CLEAN | Focused tests pass; retain as an integration candidate. |
| #36 | 58dfc050caffe0ccebe13588ab8345238b4e6136 | Await shutdown completion before termination reply | No; exact base filter ran 0 tests. PR test passed 1/1. | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope SUCCESS; CLEAN | Focused test passes; retain as an integration candidate. |
| #37 | 54f3be85df2fccf67297cedbe2f256fef829c289 | Reject URL-originated Wave Link automation | No; exact base filter ran 0 tests. PR tests passed 2/2. | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Focused tests pass, but do not integrate while the shared gate fails. |
| #38 | 4c468e96f881726b3c2107ee9cf1534d29bd3304 | Use atomically created private DMG temporary directory | No; base passed the same named test with 40 assertions. PR added the private-directory checks and passed 1 run, 44 assertions. | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope SUCCESS; CLEAN | Focused test passes; retain as an integration candidate. |
| #39 | 5397d3647ae1438c9d756843e115e6e46bd24b02 | Preserve unique DMG layout volume token | No; base passed the same named test with 40 assertions. PR added token-order checks and passed 1 run, 43 assertions. | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Focused test passes, but do not integrate while the shared gate fails. |
| #40 | 872b33cc7fb6290e7c73d4f16586f8d6d561ddfa | Make listener self-proof connect non-blocking | Not established; existing `controlServerRequiresPublicListenerSelfProof` passed 1/1 on both base and PR, but PR adds no test for non-blocking connect. | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate without focused coverage and a passing shared gate. |
| #41 | 24ccc5ef1eb02d61220bb7f021f14f9465f2a18a | Bind private staging to validated canonical root | No; exact base filter ran 0 tests. PR test failed 1/1 because expected `/var/...` differed from actual `/private/var/...`. | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate until the focused path assertion and shared gate pass. |
| #42 | b7b15b84600f6944e3b07078f15d8c3d8f7fc144 | Pin publication tag release authority | No; exact base filter ran 0 tests. PR test passed 1 run, 6 assertions. | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope SUCCESS; CLEAN | Focused test passes; retain as an integration candidate. |

## Commands and direct observations

The recovery run used `/usr/bin/ruby script/tests/release_infra_test.rb --name '/exact_name_or_regex/'` for PRs 34, 35, 38, 39, 41, and 42. PR 36 used `swift test --scratch-path /tmp/waves-pr-36-scratch --filter terminationTimeoutDecisionWaitsForSlowCleanupBeforeReturning`. PR 37 filtered `URLVolumeAutomationPreservesItsUntrustedOrigin|URLAutomationCannotInvokeTheWaveLinkBridge`. PR 40 filtered `controlServerRequiresPublicListenerSelfProof`. Base Swift comparisons reused `/tmp/waves-main-36-scratch`; exact new-test filters ran zero tests. All commands exited 0 except PR 41, which exited 1 with one assertion failure. Temporary worktrees were removed after each run. For #29, direct inspection of `Package.resolved` showed Sparkle revision `79bc9e872948e47877e76f194cb0c8e0412b0b90`, version `2.9.5`.

## Self-review and concerns

This receipt changes no production or test source and does not modify any PR. Detached Swift builds completed in 3 to 7 minutes. Swift printed intermittent `DecodingError.dataCorrupted` diagnostics during compilation but completed with exit 0 and the stated test counts. PR 40 still lacks a test that forces listener backlog pressure or otherwise proves its non-blocking-connect behavior. PR 41's own focused test is red on this host.
