# Task 1 report

Commit `2c2e419e2bd8da92b4ee6935c7b586898ff2db87` recorded the inventory receipt. This follow-up records the missing report and the reproduction diagnosis.

The first Ruby loop used `set -o pipefail` with a pipeline ending in `tail`; the shell exited after the first non-zero pipeline, so later PRs were never attempted. The second loop used `timeout`, which is not installed on this macOS host (`zsh: command not found: timeout`, status 127). Swift attempts with `perl -e 'alarm 120; exec @ARGV'` and unique `--scratch-path` produced no captured output before the host runner terminated the command. The stable base check did complete: `swift test --filter ShutdownTests`, 11 tests passed in 0.287 seconds after a 40.77 second build.

Exact isolated commands attempted:

```text
swift test --scratch-path <unique-worktree>/.build --filter terminationTimeoutDecisionWaitsForSlowCleanupBeforeReturning
swift test --scratch-path <unique-worktree>/.build --filter URLVolumeAutomationPreservesItsUntrustedOrigin
swift test --scratch-path <unique-worktree>/.build --filter URLAutomationCannotInvokeTheWaveLinkBridge
```

Each was wrapped with a 120-second Perl alarm, redirected to a temporary output file, and run in a detached worktree. The wrapper returned no output or status line before the execution host terminated the shell. The captured stderr was empty. Worktrees were removed after each attempt. No source files were changed.

The inventory remains ten open PRs, #29 and #34 through #42. The prior receipt contains each head SHA, security property, GitHub checks, and disposition. PR #29 directly resolves Sparkle 2.9.5 in `Package.resolved`. GitHub shared quality gate failures remain #34, #37, #39, #40, and #41.

Self-review: the receipt now distinguishes direct GitHub evidence, the passing base run, and the diagnosed local runner blocker. The remaining concern is that isolated PR Swift and Ruby tests cannot execute reliably on this host. A future run needs a stable SwiftPM runner and a Ruby process timeout utility or an equivalent shell-level watchdog.

## Recovery run

The detached worktree commands completed without watchdog wrappers:

```text
#34 /usr/bin/ruby script/tests/release_infra_test.rb --name '/^test_publication_tag_requires_annotated_exact_matching_tag_and_origin_main$/'
PR: exit 0, 1 run, 9 assertions. origin/main: exit 0, 0 runs.

#35 /usr/bin/ruby script/tests/release_infra_test.rb --name '/^(test_elgato_handoff_prepares_an_exact_candidate_bound_test_kit|test_elgato_handoff_finalizer_requires_every_result_and_binds_returned_diagnostics)$/'
PR: exit 0, 2 runs, 82 assertions. origin/main: exit 0, 2 runs, 77 assertions.

#36 swift test --scratch-path /tmp/waves-pr-36-scratch --filter terminationTimeoutDecisionWaitsForSlowCleanupBeforeReturning
PR: exit 0, 1 test passed. origin/main with /tmp/waves-main-36-scratch: exit 0, 0 tests.

#37 swift test --scratch-path /tmp/waves-pr-37-scratch --filter 'URLVolumeAutomationPreservesItsUntrustedOrigin|URLAutomationCannotInvokeTheWaveLinkBridge'
PR: exit 0, 2 tests passed. origin/main with /tmp/waves-main-36-scratch: exit 0, 0 tests.

#38 /usr/bin/ruby script/tests/release_infra_test.rb --name '/^test_dmg_builder_configures_and_verifies_premium_finder_layout$/'
PR: exit 0, 1 run, 44 assertions. origin/main: exit 0, 1 run, 40 assertions.

#39 /usr/bin/ruby script/tests/release_infra_test.rb --name '/^test_dmg_builder_configures_and_verifies_premium_finder_layout$/'
PR: exit 0, 1 run, 43 assertions. origin/main: exit 0, 1 run, 40 assertions.

#40 swift test --scratch-path /tmp/waves-pr-40-scratch --filter controlServerRequiresPublicListenerSelfProof
PR: exit 0, 1 test passed. origin/main with /tmp/waves-main-36-scratch: exit 0, 1 test passed.

#41 /usr/bin/ruby script/tests/release_infra_test.rb --name '/^test_private_stage_uses_the_root_that_was_validated_through_symlink_and_parent_components$/'
PR: exit 1, 1 run, 1 assertion, 1 failure. Expected /var/folders/.../real/private/Waves.dmg; actual /private/var/folders/.../real/private/Waves.dmg. origin/main exact filter: exit 0, 0 runs.

#42 /usr/bin/ruby script/tests/release_infra_test.rb --name '/^test_publication_tag_rejects_a_self_asserted_release_authority$/'
PR: exit 0, 1 run, 6 assertions. origin/main exact filter: exit 0, 0 runs.
```

Each PR used `git worktree add --detach /tmp/waves-pr-N origin/pr/N`. The base used a separate detached `/tmp/waves-main` worktree at `d2ac715`. Only one detached worktree existed at a time, and all were removed after use.

Self-review: the updated receipt replaces each inconclusive PR 34 through 42 result with direct command output. PR 40 remains a coverage gap because it changes only production code and the existing self-proof test passes before and after the change. PR 41 is a direct focused-test failure, not a runner failure. Swift compilation emitted intermittent `DecodingError.dataCorrupted` diagnostics but finished with exit 0 and the recorded test results. No production or test source changed.

## Review fix round 1

Fresh inventory command:

```text
gh pr list --state open --limit 100 --json number,title,headRefOid,mergeStateStatus,statusCheckRollup,url
```

Exit 0. It returned ten open PRs. The receipt now records each exact title and adds a separate mergeability column. Mergeability is CLEAN for PRs 29, 35, 36, 38, and 42. It is UNSTABLE for PRs 34, 37, 39, 40, and 41.

Full current-branch checks:

```text
swift test
/usr/bin/ruby script/tests/release_infra_test.rb
```

`swift test` exited 0. The incremental build completed in 19.17 seconds, then 626 tests passed in 27.690 seconds. The final output contained no warnings or failures. The Ruby suite exited 0 after 398.408857 seconds with 73 runs, 735 assertions, 0 failures, 0 errors, and 0 skips.

Final receipt check:

```text
git diff --check && test "$(rg -c '^\| #[0-9]+' .audit/evidence/2026-09-04-pr-adjudication-baseline.md)" -eq "$(gh pr list --state open --limit 100 --json number --jq length)"
```

Exit 0. The receipt has ten PR rows, matching ten open PRs. Self-review found all six required inventory fields for every row: number, title, head SHA, checks, mergeability, and security property. The remaining PR-specific concerns are unchanged. PR 40 lacks direct non-blocking-connect coverage, and PR 41's focused test fails on the `/var` versus `/private/var` path assertion.
