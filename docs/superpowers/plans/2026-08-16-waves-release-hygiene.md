# Waves Release Hygiene Implementation Plan

> **For agentic workers:** Use test-driven development and execute each task in order.

**Goal:** Remove stale release documentation, make canonical release metadata govern public repository copy, archive the shipped 1.5 program, and upgrade Sparkle to the patched 2.9.5 release.

**Architecture:** Extend the existing `WavesRelease::RepositoryContract` rather than adding a second validator. `release/metadata.json` remains the sole version/build authority. The contract validates the README, product specification, Homebrew template, package deployment floor, Sparkle security floor, and archived release-plan location.

**Tech stack:** Ruby release tooling and Minitest, SwiftPM `Package.resolved`, Markdown release documentation.

### Task 1: Characterize release-document drift

- Add fixture-backed contract tests for README version/build drift.
- Add fixture-backed contract tests for `docs/PRODUCT.md` drift.
- Add fixture-backed contract tests for the missing 1.5 archive.
- Add fixture-backed contract tests for Sparkle below 2.9.5.
- Run the focused Minitest and confirm it fails before production changes.

### Task 2: Enforce canonical release state

- Extend `RepositoryContract.validate!` to read the README and product specification.
- Require the exact canonical version and build from `release/metadata.json`.
- Require the 1.5 plan under `docs/archive/` and reject the stale root location.
- Parse `Package.resolved` and require Sparkle 2.9.5 or newer.
- Keep future patch/minor Sparkle upgrades valid.

### Task 3: Repair repository state

- Update `docs/PRODUCT.md` to identify 1.5.0 build 13 as published.
- Move `1.5-update-plan.md` to `docs/archive/1.5-update-plan.md`.
- Add a short archive index and fix historical-plan links.
- Update `Package.resolved` to Sparkle 2.9.5.
- Record the maintenance changes under the Unreleased changelog.

### Task 4: Verify

- Run the focused repository-contract Minitest.
- Run `release_tool.rb validate-repository` under a UTF-8 locale.
- Run Ruby syntax validation and `git diff --check`.
- Run the repository full quality gate on GitHub macOS CI before marking the pull request ready.
