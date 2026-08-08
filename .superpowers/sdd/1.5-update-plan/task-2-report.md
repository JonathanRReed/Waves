DONE_WITH_CONCERNS

# Waves 1.5 Task 2 report

## Scope and result

Implemented Task 2 audio correctness: an explicit verified-conflict monitor-only decision seam, transactional muting-tap teardown, retained late-callback ownership on failed cleanup, callback-safe geometry-mismatch signaling, bounded geometry recovery, and event-driven process/tap-list observation feeding a deterministic 250 ms competing-router debounce.

## Changed files

- `Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift`
- `Tests/WavesTests/AudioCorrectnessTask2Tests.swift`
- `Tests/WavesTests/AudioHardeningTests.swift`
- `Tests/WavesTests/P1CharacterizationTests.swift`
- `1.5-update-plan.md`

## Test-first evidence

Before production changes, the focused Task 2 command failed during compilation because the required behavior seams did not exist: `CompetingRouterConflictDecision`, the mute-rollback closure and result state, `GeometryRecoveryCoordinator`, and `RouterConflictObservationDebouncer` were all missing.

```text
swift test --filter 'verifiedRouterConflictKeepsDeviceReattachmentMonitorOnly|unmuteThenRendererStopFailureRestoresTapMuteAndKeepsRendererAlive|failedMuteRollbackRetainsResourcesAndReportsCriticalDiagnostic|geometryMismatchCoalescesIntoOneAsynchronousRecovery|geometryRecoveryUsesBoundedBackoffAndPublishesExhaustedHealth|routerObservationDebouncesConflictAndRecoversWithinOneSecond'
```

After implementation, the focused command including P1.1 through P1.4 and existing muting-tap hardening tests passed 12 tests. The source-text P1.3 and P1.4 probes were replaced with deterministic behavior tests. No `withKnownIssue` or red-mode helper remains in the P1 characterization file.

## Final verification

- `swift format lint --recursive --parallel --strict Sources Tests`: passed.
- `swift build`: passed.
- `swift build -c release`: passed.
- `swift test`: passed, 339 tests after listener integration.
- `git diff --check`: passed.

The final suite has zero P1.1 through P1.4 known issues.

## Mutation evidence

Each mutation was applied only long enough to run the named focused test, then reverted before final verification.

- Inverting verified-conflict gating made `verifiedRouterConflictKeepsDeviceReattachmentMonitorOnly` fail: verified conflict became `.none`, and unverified conflict became `.monitorOnly`.
- Inverting the renderer-stop success branch made `unmuteThenRendererStopFailureRestoresTapMuteAndKeepsRendererAlive` fail: it deactivated the renderer instead of restoring tap muting.
- Allowing one extra recovery attempt made `geometryRecoveryUsesBoundedBackoffAndPublishesExhaustedHealth` fail: the third failure scheduled 0.6 seconds instead of reaching exhausted health.
- Reversing debounce actions made `routerObservationDebouncesConflictAndRecoversWithinOneSecond` fail: activation and release were exchanged.

## Realtime and cleanup safety

- The Core Audio callback now records a geometry mismatch through a preallocated `UnsafeMutablePointer<Int32>` using `OSAtomicCompareAndSwap32Barrier`. The callback signal path has no lock or try-lock, allocation, logging, actor hop, policy scan, or recovery work.
- The backend actor consumes the coalesced signal, schedules and performs route rebuilds outside the callback, uses 250 ms linear bounded backoff, and publishes the actionable exhausted error after three failed attempts.
- Teardown only stops the renderer after the original path is successfully released. A renderer-stop failure re-mutes the tap. If re-muting also fails, the renderer and callback resources remain retained and the result exposes a critical diagnostic. Native destruction stops at the first failed dependency.

## Deferred boundaries and remaining risks

- `AUD-006` registers Core Audio property listeners for `kAudioHardwarePropertyProcessObjectList` and `kAudioHardwarePropertyTapList` on `routerObservationQueue`. Their callback performs only selector filtering and schedules an actor-owned dirty-generation increment. The 250 ms backend pass consumes that generation and feeds the deterministic debounce, keeping router interpretation outside realtime work. Listener blocks and selectors are retained and removed through the checked cleanup path.
- Task 3 owns proof that a competing router identity is trustworthy, its signed-artifact descriptor, and tap-membership derivation. The backend now consumes `VerifiedRouterConflictProvider` only. A bundle ID alone can no longer create a stable conflict in the backend.
- `OSAtomicCompareAndSwap32Barrier` is available with the macOS 14.2 deployment floor and avoids a dependency, but Apple marks the OSAtomic family deprecated. Replacing it with a non-deprecated lock-free primitive would require an approved dependency or a small C atomic shim, neither added in this task.
- No physical Wave Link device, mutable user routing state, or TCC prompt was used. The coverage is deterministic failure injection and state-machine verification, not a hardware coexistence release gate.

## Commits

- `38bc2df fix: harden audio route recovery`
