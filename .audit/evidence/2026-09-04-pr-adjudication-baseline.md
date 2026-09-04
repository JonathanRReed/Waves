# Waves 1.7.1 PR adjudication baseline

Date: 2026-09-04. Base: `e7d85d9490db9c53410fb9d02977ba243a2bc560`.

Inventory was fetched with:

```text
git fetch origin '+refs/pull/*/head:refs/remotes/origin/pr/*'
gh pr list --state open --limit 100 --json number,title,headRefOid,mergeStateStatus,statusCheckRollup,url
```

The authoritative open inventory is PR 29 and PRs 34 through 42. PR heads were fetched without checkout. Each focused reproduction was attempted in a detached temporary worktree created from `origin/pr/N`, then removed. The local Swift runner built the base `ShutdownTests` successfully (11 passed). Separate PR worktree builds did not return usable output before the runner terminated; those reproductions are recorded as inconclusive, not passes.

| PR | Head SHA | Security property | Main reproduces? | PR checks | Integrated disposition |
|---|---|---|---|---|---|
| #29 | e12204a4899a2a8557b23a881789f2bf2fbd7cdf | Pin Sparkle dependency at 2.9.5 | Inconclusive, dependency-only | Shared quality gate SUCCESS | Review Package.resolved; verified Sparkle 2.9.5. |
| #34 | 465b10f3c36bdd24e5602793258e3ab8ef514221 | Preserve publication branch provenance | Inconclusive; `ruby script/tests/release_infra_test.rb` did not yield runner output | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate until focused test and gate failure are explained. |
| #35 | 10846d21d6600a02fb869852a293f42cb59f6d14 | Authenticate Elgato handoff checksums out of band | Inconclusive; `ruby script/tests/release_infra_test.rb` did not yield runner output | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope NEUTRAL; CLEAN | Candidate needs focused local evidence before integration. |
| #36 | 58dfc050caffe0ccebe13588ab8345238b4e6136 | Await shutdown completion before termination reply | Inconclusive; `swift test --filter ShutdownTests` in PR worktree did not yield runner output | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope SUCCESS; CLEAN | Candidate security behavior is relevant; rerun on a stable isolated Swift runner. |
| #37 | 54f3be85df2fccf67297cedbe2f256fef829c289 | Reject URL-originated Wave Link automation | Inconclusive; `swift test --filter AppStoreTransactionTests` did not yield runner output | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate until gate and focused tests are repaired. |
| #38 | 4c468e96f881726b3c2107ee9cf1534d29bd3304 | Use atomically created private DMG temporary directory | Inconclusive; `ruby script/tests/release_infra_test.rb` did not yield runner output | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope SUCCESS; CLEAN | Candidate is security-relevant; rerun focused test. |
| #39 | 5397d3647ae1438c9d756843e115e6e46bd24b02 | Preserve unique DMG layout volume token | Inconclusive; `ruby script/tests/release_infra_test.rb` did not yield runner output | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate until gate failure is explained. |
| #40 | 872b33cc7fb6290e7c73d4f16586f8d6d561ddfa | Make listener self-proof connect non-blocking | Inconclusive; `swift test --filter ControlServerIntegrationTests` did not yield runner output | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate until gate and focused tests are repaired. |
| #41 | 24ccc5ef1eb02d61220bb7f021f14f9465f2a18a | Bind private staging to validated canonical root | Inconclusive; `ruby script/tests/release_infra_test.rb` did not yield runner output | Shared quality gate FAILURE; Greptile SUCCESS; Macroscope SUCCESS; UNSTABLE | Do not integrate until gate failure is explained. |
| #42 | b7b15b84600f6944e3b07078f15d8c3d8f7fc144 | Pin publication tag release authority | Inconclusive; `ruby script/tests/release_infra_test.rb` did not yield runner output | Shared quality gate SUCCESS; Greptile SUCCESS; Macroscope SUCCESS; CLEAN | Candidate needs focused local evidence before integration. |

## Commands and direct observations

The base command `swift test --filter ShutdownTests` completed with 11 tests passed. PR worktrees used `git worktree add --detach /tmp/waves-pr-N origin/pr/N`; Ruby candidates used `ruby script/tests/release_infra_test.rb`, #36 used `swift test --filter ShutdownTests`, #37 used `swift test --filter AppStoreTransactionTests`, and #40 used `swift test --filter ControlServerIntegrationTests`. Temporary worktrees were removed after each attempt. For #29, direct inspection of `Package.resolved` showed Sparkle revision `79bc9e872948e47877e76f194cb0c8e0412b0b90`, version `2.9.5`.

## Self-review and concerns

This receipt changes no production or test source and does not modify any PR. The main concern is local runner instability for detached worktree builds. GitHub check conclusions are direct inventory output, while the local focused-test rows are deliberately marked inconclusive. A stable Swift/Ruby runner should rerun all ten commands before final release adjudication.
