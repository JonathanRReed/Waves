# Waves 1.7.1 implementation-plan review

Date: 2026-09-04
Branch: `codex/waves-1.7.1`
Base revision: `d2ac715a14e290a7e8b301820b3fcdb1e149e77c`

## Plans reviewed

- `docs/superpowers/plans/2026-09-04-waves-1.7.1-security-and-prs.md`
- `docs/superpowers/plans/2026-09-04-waves-1.7.1-performance-half-bounce.md`
- `docs/superpowers/plans/2026-09-04-waves-1.7.1-release-publication.md`

## Self-review result

- Coverage: The plans map every design success criterion and every open PR in
  the approved inventory to a named task and direct receipt.
- Executability: Each code task names files, a failing test, the expected
  failure, the smallest implementation boundary, a passing command, and a
  commit boundary.
- Release order: The exact clean `origin/main` build precedes the candidate,
  Mac mini testing precedes publication evidence, and the signed local tag
  precedes the publication gate and tag push.
- Artifact identity: Any candidate-byte change invalidates downstream trust,
  hardware, and publication evidence. Public surfaces are checked against the
  sealed candidate hash.
- Safety: Realtime callbacks remain outside instrumentation, the 250 ms quit
  bound stays fixed, private staging is canonical and mode 0700, and public
  social posting remains approval-gated.
- Placeholder check: No implementation step delegates an unresolved product or
  security choice to a later task. Homebrew's hash is intentionally generated
  from the published DMG in the publication task.
- Formatting: `git diff --check` passed after all three plans were written.

## Linked execution order

1. Security and pull-request Tasks 1 through 9.
2. Performance Tasks 1 through 5, interleaved only where a security fix shares
   the same focused tests.
3. Release metadata and premerge gates.
4. Pull-request closure after the integrated branch is pushed and verified.
5. Candidate build, Half Bounce and runtime candidate measurements, Mac mini
   gate, signed tag, publication, and public verification.

The plans are ready for in-session execution with
`superpowers:executing-plans`.
