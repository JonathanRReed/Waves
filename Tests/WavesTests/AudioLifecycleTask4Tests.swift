import AudioToolbox
import Testing
import WavesAudioCore

@testable import Waves

@Test func targetProcessFamilyRetiresDeadHelpersWithoutRebuildingCoveredRoute() {
  let controllerTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11, 12]
  )
  let liveTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11]
  )

  #expect(!controllerTarget.matches(liveTarget))
  #expect(controllerTarget.covers(liveTarget))
}

@Test func targetProcessFamilyRequiresRebuildForReturningHelperOrDifferentLogicalFamily() {
  let controllerTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11]
  )
  let returningHelper = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11, 12]
  )
  let reusedObjectIDFromAnotherFamily = TargetProcessFamily(
    logicalID: "com.example.other-browser",
    processObjectIDs: [11]
  )

  #expect(!controllerTarget.covers(returningHelper))
  #expect(!controllerTarget.matches(reusedObjectIDFromAnotherFamily))
  #expect(!controllerTarget.covers(reusedObjectIDFromAnotherFamily))
}

@Test func callbackRenderStateUsesPreallocatedAtomicValuesAndCoalescesGeometryRecovery() {
  let state = TapRenderStateBox(
    initialState: TapRenderState(
      volume: 0.5,
      volumeBoost: 2,
      isMuted: 0,
      isActive: 1,
      peakLevel: 0,
      rmsLevel: 0,
      analysisRMS: 0,
      voiceBandEnergy: 0,
      renderTick: 0
    )
  )

  state.markRenderTick()
  state.writeLevels(peakLevel: 0.8, rmsLevel: 0.4, analysisRMS: 0.3, voiceBandEnergy: 0.2)
  state.flagGeometryMismatch()
  state.flagGeometryMismatch()
  state.setInactive()

  #expect(state.read().renderTick == 1)
  #expect(state.read().peakLevel == 0.8)
  #expect(state.read().isActive == 0)
  #expect(state.consumeGeometryMismatch())
  #expect(!state.consumeGeometryMismatch())
}

@Test func competingRouterPolicyKeepsMixedOutputExclusionSeparateFromVerifiedOwnership() {
  let waveLink = AudioApp(
    id: "wave-link",
    logicalID: "com.elgato.WaveLink3",
    bundleID: "com.elgato.WaveLink3",
    displayName: "Wave Link",
    category: .media,
    compatibility: .supported
  )
  let ordinary = AudioApp(
    id: "ordinary",
    logicalID: "com.example.ordinary",
    bundleID: "com.example.ordinary",
    displayName: "Ordinary",
    category: .media,
    compatibility: .supported
  )

  #expect(CompetingRouterPolicy.mixedOutputExclusion(for: waveLink) != nil)
  #expect(CompetingRouterPolicy.upstreamOwnershipDetail(for: ordinary, conflict: nil) == nil)
}

@Test func backendOwnedLifecycleDrainsInjectedControllersAfterOneHundredCycles() async throws {
  let fixture = try BackendOwnedLifecycleFixture.make()
  let backend = fixture.backend

  await backend.beginTestingLifecycle()
  for cycle in 0..<100 {
    try await fixture.runCycle(number: cycle)
  }

  let beforeShutdown = await backend.lifecycleDebugSnapshot()
  #expect(beforeShutdown.liveControllers == 1)
  #expect(beforeShutdown.orphanedControllers == 0)
  #expect(beforeShutdown.retainedCallbackOwners == 1)
  #expect(beforeShutdown.routerListenerRegistrations == 2)
  #expect(beforeShutdown.pendingGeometryRecoveries == 0)
  #expect(beforeShutdown.retainedGeometryRecoveryStates == 1)

  _ = await backend.shutdownWithResult()
  let afterShutdown = await backend.lifecycleDebugSnapshot()
  #expect(afterShutdown.liveControllers == 0)
  #expect(afterShutdown.orphanedControllers == 0)
  #expect(afterShutdown.retainedCallbackOwners == 0)
  #expect(afterShutdown.routerListenerRegistrations == 0)
  #expect(afterShutdown.pendingGeometryRecoveries == 0)
  #expect(afterShutdown.retainedGeometryRecoveryStates == 0)
}

private enum LifecycleHarnessError: Error {
  case reuseWasNotCovered
  case helperExpansionDidNotRebuild
  case geometryRecoveryDidNotComplete
  case disposeFailureWasNotRetained
}

private final class BackendOwnedLifecycleFixture: @unchecked Sendable {
  let backend: WorkspaceAudioControlBackend
  private let processIDs: TestingProcessObjectIDs
  private let teardown: TestingTeardownSwitch

  private init(
    backend: WorkspaceAudioControlBackend,
    processIDs: TestingProcessObjectIDs,
    teardown: TestingTeardownSwitch
  ) {
    self.backend = backend
    self.processIDs = processIDs
    self.teardown = teardown
  }

  static func make() throws -> BackendOwnedLifecycleFixture {
    let processIDs = TestingProcessObjectIDs()
    let teardown = TestingTeardownSwitch()
    let app = AudioApp(
      id: "lifecycle.app",
      logicalID: "lifecycle.app",
      pid: 700,
      bundleID: "com.example.lifecycle",
      displayName: "Lifecycle",
      category: .media,
      isActive: true,
      desiredVolume: 0.5,
      appliedVolume: 0.5,
      routingState: .managed,
      compatibility: .supported
    )
    let backend = WorkspaceAudioControlBackend(
      testingSnapshot: AudioSessionSnapshot(
        apps: [app],
        currentDevice: nil,
        recentDeviceIDs: [],
        supportMatrix: SupportMatrix(entries: []),
        backendStatus: BackendStatus(
          isAudioComponentInstalled: true,
          hasRequiredPermissions: true,
          isRouteRecoveryHealthy: true
        )
      ),
      routerObservationNativeCalls: RouterObservationListenerNativeCalls(
        add: { _, _ in noErr },
        remove: { _, _ in noErr }
      ),
      controllerFactory: { app, processObjectIDs, _, _, _ in
        try PerAppTapController.testingController(
          appID: app.id,
          logicalID: app.logicalID,
          targetProcessObjectIDs: processObjectIDs,
          teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
            makeOriginalAudioAudible: { noErr },
            stopIOProc: { teardown.shouldFailStop ? -1 : noErr },
            restoreTapMuting: { noErr }
          )
        )
      },
      processObjectIDResolver: { _ in processIDs.value },
      processObjectLivenessProvider: { _ in true }
    )
    return BackendOwnedLifecycleFixture(
      backend: backend,
      processIDs: processIDs,
      teardown: teardown
    )
  }

  func runCycle(number: Int) async throws {
    let baseID = AudioObjectID(number + 1)
    processIDs.value = [baseID]
    let reuse = await backend.applyAppIntent(testingIntent(volume: 0.2, generation: UInt64(number * 2 + 1)))
    guard reuse.outcome == .applied || reuse.outcome == .noChange else {
      throw LifecycleHarnessError.reuseWasNotCovered
    }

    teardown.shouldFailStop = true
    processIDs.value = [baseID, AudioObjectID(number + 10_000)]
    let expanded = await backend.applyAppIntent(testingIntent(volume: 0.8, generation: UInt64(number * 2 + 2)))
    teardown.shouldFailStop = false
    guard expanded.outcome == .applied else {
      throw LifecycleHarnessError.helperExpansionDidNotRebuild
    }

    let retained = await backend.lifecycleDebugSnapshot()
    guard retained.liveControllers == 1,
      retained.orphanedControllers == 1,
      retained.retainedCallbackOwners == 2
    else {
      throw LifecycleHarnessError.disposeFailureWasNotRetained
    }

    await backend.flagGeometryMismatchForTesting(runtimeID: "lifecycle.app")
    await backend.updateAudioLevels(at: .milliseconds(number))
    let recovered = await backend.lifecycleDebugSnapshot()
    guard recovered.liveControllers == 1,
      recovered.orphanedControllers == 0,
      recovered.retainedCallbackOwners == 1,
      recovered.pendingGeometryRecoveries == 0
    else {
      throw LifecycleHarnessError.geometryRecoveryDidNotComplete
    }
  }

  private func testingIntent(volume: Float, generation: UInt64) -> AppRouteIntent {
    AppRouteIntent(
      appID: "lifecycle.app",
      desiredVolume: volume,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: generation,
      reason: .automation
    )
  }
}

private final class TestingProcessObjectIDs: @unchecked Sendable {
  var value: [AudioObjectID] = [1]
}

private final class TestingTeardownSwitch: @unchecked Sendable {
  var shouldFailStop = false
}
