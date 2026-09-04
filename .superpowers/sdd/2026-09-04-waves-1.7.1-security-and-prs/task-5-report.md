# Task 5 report

Implemented the writable DMG workspace isolation in `script/build_and_run.sh` and added behavioral coverage in `script/tests/release_infra_test.rb`.

- Focused: `1 runs, 3 assertions, 0 failures, 0 errors, 0 skips`
- Full suite: `74 runs, 740 assertions, 0 failures, 0 errors, 0 skips`
- `git diff --check`: passed
- Commit: `958cfd8 fix: isolate writable DMG construction`

## Round 1 follow-up

Production cleanup is now executed directly by the behavioral test through a controlled `hdiutil` hook. A failed detach keeps mount tracking and the writable workspace for recovery. Workspace deletion requires the exact six-character mktemp suffix and mode/path checks.

- Focused: `1 runs, 3 assertions, 0 failures, 0 errors, 0 skips`
- `git diff --check`: passed
- Commit: `1009bb9 fix: retain writable DMG on detach failure`
- Self-review: no production command paths were weakened; final `dist/Waves.dmg` flow is unchanged.

## Mandatory full-suite verification

- Command exit code: `0`
- Duration: `229.75s` wall clock (`229.391816s` reported test duration)
- Result: `74 runs, 740 assertions, 0 failures, 0 errors, 0 skips`
- Fresh `git diff --check`: exit `0`

## Recovery follow-up

Replaced the defective duplicate tests with a reusable Ruby probe that extracts
and invokes the production `cleanup` function while replacing only the absolute
`/usr/bin/hdiutil` command. The hook lives outside the workspace under test and
requires `layout.dmg` to exist when detach is invoked. The production cleanup now
retains the mount, workspace, and image variables as well as the image bytes when
detach fails.

- Focused discovery command: `rg -o '^\s*def (test_.*(writable_dmg|layout_volume|cleanup).*)' -r '$1' script/tests/release_infra_test.rb`
- Focused test command: `/usr/bin/time -p /usr/bin/ruby script/tests/release_infra_test.rb --name '/writable_dmg|layout_volume|cleanup/'`
- Focused result: 5 discovered methods; `5 runs, 47 assertions, 0 failures, 0 errors, 0 skips`; final verification `real 3.21s`
- Full command: `/usr/bin/time -p /usr/bin/ruby script/tests/release_infra_test.rb`
- Full result: `78 runs, 784 assertions, 0 failures, 0 errors, 0 skips`; `real 239.64s` (`239.246287s` reported test duration)
- Diff command: `git diff --check`
- Diff result after report append: exit `0`
- Self-review: creation uses the actual production setup block; every cleanup scenario creates its own collision-safe exact target; successful detach proves the image existed before deletion; failed detach asserts all recovery variables and image bytes from the same shell probe; empty, broad, symlink, wrong-mode, malformed-suffix, and mismatched-image targets remain untouched; helper cleanup removes only paths created by each test; final `dist/Waves.dmg` behavior is unchanged.
