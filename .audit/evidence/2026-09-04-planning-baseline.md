# Waves 1.7.1 planning baseline receipt

Recorded: 2026-09-04

## Source identity

- Repository: `https://github.com/JonathanRReed/Waves.git`
- Base branch: `origin/main`
- Base revision: `d2ac715a14e290a7e8b301820b3fcdb1e149e77c`
- Work branch: `codex/waves-1.7.1`
- Branch creation command: `git switch -c codex/waves-1.7.1 origin/main`
- Starting worktree: clean

`git fetch --prune origin`, `git status --short --branch`, `git rev-parse HEAD`,
and `git rev-parse origin/main` confirmed that local `main` and `origin/main`
both named the base revision before branch creation.

## Functional baseline

- Command: `swift test`
- Exit status: 0
- Result: 626 tests passed
- Observed duration after build: 17.393 seconds

The run included the control-server timeout test that had failed on several
proposal branches:
`controlConnectionTimesOutWithoutHandshakeButRetainsSubscriber` passed after
14.808 seconds.

## Public release truth

- GitHub latest release: `v1.7.0`, published 2026-09-01, version 1.7.0 build 16.
- Live appcast first item: version 1.7.0, Sparkle build 16.
- Live Homebrew cask: version 1.7.0.
- Current `origin/main` metadata: version 1.7.0, build 16.
- Wave Link test branch metadata: version 1.7.0, build 18.
- Chosen target: version 1.7.1, build 19.

Checks used `gh release view`, the GitHub releases API, an uncached fetch of
`https://waves.jonathanrreed.com/appcast.xml`, the public Homebrew cask, and
`git show` against the relevant refs.

## Companion repository

`gh repo list JonathanRReed --limit 1000` confirmed the private, unarchived
`JonathanRReed/waves-streamdeck` repository exists. It was not cloned or
changed during planning.
