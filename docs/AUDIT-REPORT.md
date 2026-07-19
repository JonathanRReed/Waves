# Waves 1.1.0 Release-Hardening Audit

_Date: 2026-07-18_

## Scope and evidence

This report covers the 1.1.0 release-hardening state visible in the current
working tree and the final locally generated unsigned/ad-hoc universal candidate.
It does not certify hardware behavior, Apple signing, notarization, or a
publishable Developer ID distribution package.

Evidence used for this report:

- The complete Swift test suite: **197 tests passing**.
- Focused runtime-independent probes for privacy-gated startup, structured capture
  authorization, generation-safe app transactions, profile reconciliation,
  coalesced persistence, persistence failure propagation, native-format planning,
  output-device readiness, DSP headroom, and checked termination/cleanup.
- Static inspection and syntax validation of the local packaging script, Homebrew
  cask template, GitHub CI/release workflows, issue-template front matter, plist
  metadata, and privacy manifest.
- A completely fresh `--release-check` after deleting repository-local `.build`
  and `dist`: universal `Waves.app`, universal matching dSYM, and `Waves.dmg` all
  passed the non-rebuilding `--verify` and mounted-DMG `--package-smoke` gates.
- Independent package inspection confirmed version 1.1.0, build 2, macOS 14.2 in
  both arm64 and x86_64 slices, the audio-input entitlement, ad-hoc signature
  integrity, resource/privacy inputs, matching dSYM UUIDs, DMG layout and mounted
  app identity, and `hdiutil verify`. The unsigned DMG evidence SHA-256 is
  `751f922e381ed3f8172fbfc3b4a401365ff2754ca5ad331ab3dd54761f4b8375` and is not
  a public cask checksum.
- Isolated-home runtime observation of the exact packaged executable: the privacy
  setup surface remained visible and alive with consent false, no session cache or
  capture/tap startup before Continue, and a normal bounded clean quit with no
  orphaned process. Continue was intentionally not clicked on the production backend.
- Current release metadata and documentation in `CHANGELOG.md`, `README.md`,
  `PRIVACY.md`, `SECURITY.md`, `docs/RELEASE.md`, and `Casks/waves.rb`.
- Local source validation with Apple Swift 6.2.3. The package continues to declare
  Swift tools 6.0 and macOS 14.2 as its minimum deployment target.

## Gate status

| Gate | Status | Evidence / remaining work |
| --- | --- | --- |
| Swift compile and full test suite | **PASS** | `swift test`: 197/197 tests pass. |
| Privacy-before-capture lifecycle | **PASS** | Fresh installs remain privacy-gated; the backend does not start until the user records local consent. |
| Complete generation-safe app intents | **PASS** | Backend and AppStore tests cover supersession, ordered profile rows, offline state, and truthful failure reconciliation. |
| Persistence durability | **PASS** | Schema-1 envelopes, corrupt-file recovery, bounded coalescing writers, surfaced async failures, and shutdown flushes are covered by focused tests. |
| Format, device, and route truth | **PASS** | Unsupported callback layouts and missing current-device queries fail closed; route/backend errors remain visible. |
| Checked shutdown | **PASS** | AppStore drains/cancels owned work, flushes persistence, requests checked backend cleanup, and reports clean/degraded/timed-out outcomes through the AppKit termination handshake. |
| Copied diagnostics | **PASS** | Version/build fallbacks, macOS metadata, structured authorization, device/readiness, backend/route errors, persistence failures, and cleanup state are bounded and privacy-labelled; no audio samples are exported. |
| Logging and telemetry filter | **PASS** | Product `Logger` instances use subsystem `com.jonathanreed.Waves` with useful categories; `--telemetry` selects that subsystem. |
| Release script/cask/workflow static gates | **PASS** | Static validation covers shell syntax, Ruby syntax/template invariants, YAML parsing where available, strict tags, main-commit checks, universal-slice checks, dSYM/package metadata, and credential ordering. |
| Final unsigned universal app/dSYM/DMG candidate | **PASS** | A fresh 1.1.0/build-2 release candidate passed `--release-check`, non-rebuilding `--verify`, mounted-DMG `--package-smoke`, independent metadata/slice/dSYM/signature/layout inspection, and `hdiutil verify`. |
| Packaged first-run privacy and clean-exit smoke | **PASS** | The exact packaged executable ran under isolated `HOME`/`CFFIXED_USER_HOME`, stayed on the pre-consent privacy surface without capture startup, and exited normally in under one second with no orphan. |
| Real Core Audio and TCC matrix | **MANUALLY PENDING** | Requires real apps, output devices, permission transitions, device changes, route recovery, and cleanup observation on supported Macs. |
| Intel and minimum-OS runtime | **MANUALLY PENDING** | Requires launching the final x86_64 slice on Intel and exercising the final build on macOS 14.2. |
| Developer ID signing, notarization, Gatekeeper, and publication | **APPLE-CREDENTIAL-DEPENDENT** | Requires the maintainer's Developer ID certificate, Apple notarization credentials, final strict publication checks, and an explicit publication decision. |

## Hardening completed for 1.1.0

- **Consent before capture:** first-run setup persists an explicit local privacy
  acknowledgement before starting the production audio backend.
- **Generation-safe complete intents:** volume, mute, boost, EQ, target device, and
  exclusion state are applied as one generation-checked transaction.
- **Durable and offline truth:** saved per-app intent survives app absence, while
  profile application preserves one ordered outcome for every source row instead
  of reducing mixed results to a misleading boolean.
- **Coalesced persistence:** preferences, profiles, sessions, and device presets
  keep at most one writer per store, replace pending snapshots, surface failures,
  and expose explicit flush boundaries for shutdown.
- **Fail-closed format and device handling:** unsupported native PCM layouts,
  inconsistent callback geometry, and unknown current-output devices do not
  produce an optimistic managed-route state.
- **Checked shutdown:** store-owned work settles before persistence finalization and
  native cleanup; failures are retained as structured degradation results.
- **Universal package and CI gates:** release logic checks arm64 and x86_64 slices,
  deployment targets, dSYM UUIDs, bundle metadata, privacy assets, installer
  layout, code identity, and smoke behavior. The final unsigned 1.1.0 candidate
  exercised these gates; Developer ID/notarized publication remains separate.
- **Truthful diagnostics:** copied output is deterministic and bounded, labels
  potentially identifying app/device/error fields, and reports structured capture
  authorization including native status for probe failures.

## Known limitations and final manual matrix

The following cannot be proven by hardware-independent unit tests or static
workflow inspection:

1. **Real Core Audio device/TCC matrix.** Validate authorized, not-granted,
   undetermined, and changed-during-run capture states; built-in, Bluetooth,
   display, aggregate, and unavailable outputs; browser/Electron helper
   attribution; rapid device changes; per-app route recovery; and checked cleanup
   on actual audio hardware. Core Audio may return device- and OS-specific status
   codes that synthetic tests cannot enumerate.
2. **Intel/minimum-OS runtime.** The package declares macOS 14.2 and the release
   pipeline requires an x86_64 slice, but the final candidate still needs direct
   launch and functional smoke coverage on Intel and on the minimum supported OS.
3. **Developer ID/notarization/publication.** No Apple signing identity or
   notarization credential was used here. Developer ID signing, notary acceptance,
   stapling, Gatekeeper assessment, checksum publication, GitHub Release
   publication, and any public Homebrew channel update remain maintainer actions.

## Release conclusion

The source-level 1.1.0 hardening, automated/static gates, final unsigned
universal-package verification, and isolated packaged-app privacy smoke are
**PASS**. The release is not yet fully cleared for publication because the real
hardware/TCC matrix, Intel/minimum-OS runtime, and Apple-credential-dependent
Developer ID signing/notarization gates remain pending. No tag, release, package
publication, repository-visibility change, or public cask update is claimed by
this report.
