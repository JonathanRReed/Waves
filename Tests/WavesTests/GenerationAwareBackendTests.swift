import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func previewIntentPrefersLogicalIdentityAndRejectsOlderGenerations() async {
  let collision = AudioApp(
    id: "shared-key",
    logicalID: "other-logical-id",
    displayName: "Collision",
    category: .unknown,
    desiredVolume: 0.9,
    compatibility: .supported
  )
  let intended = AudioApp(
    id: "runtime-id",
    logicalID: "shared-key",
    displayName: "Intended",
    category: .media,
    desiredVolume: 0.3,
    compatibility: .supported
  )
  let backend = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [collision, intended]))

  let accepted = await backend.applyAppIntent(
    testIntent(
      appID: "shared-key",
      volume: 0.4,
      generation: 20
    ))
  let acceptedSnapshot = await backend.currentSnapshot()
  let rejected = await backend.applyAppIntent(
    testIntent(
      appID: "shared-key",
      volume: 0.1,
      generation: 19,
      isExcluded: true
    ))
  let rejectedSnapshot = await backend.currentSnapshot()

  #expect(accepted.outcome == .applied)
  #expect(accepted.resultingApp?.logicalID == "shared-key")
  #expect(acceptedSnapshot.apps[0].desiredVolume == 0.9)
  #expect(acceptedSnapshot.apps[1].desiredVolume == 0.4)
  #expect(rejected.outcome == .superseded)
  #expect(rejectedSnapshot == acceptedSnapshot)
}

@Test func previewExclusionReleasesRouteWithoutApplyingControlValues() async {
  let app = AudioApp(
    id: "runtime.app",
    logicalID: "logical.app",
    displayName: "App",
    category: .media,
    isActive: true,
    peakLevel: 0.7,
    rmsLevel: 0.5,
    desiredVolume: 0.6,
    appliedVolume: 0.6,
    isMuted: false,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: 2,
    targetDeviceUID: "device.old"
  )
  let backend = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [app]))
  let exclusion = AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.1,
    isMuted: true,
    volumeBoost: 4,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: "device.new",
    generation: 1,
    reason: .userEdit,
    isExcluded: true
  )

  let result = await backend.applyAppIntent(exclusion)
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .excluded)
  #expect(resultingApp.desiredVolume == 0.6)
  #expect(resultingApp.isMuted == false)
  #expect(resultingApp.volumeBoost == 2)
  #expect(resultingApp.targetDeviceUID == "device.old")
  #expect(resultingApp.routingState == .monitorOnly)
  #expect(resultingApp.appliedVolume == nil)
  #expect(resultingApp.peakLevel == 0)
  #expect(resultingApp.rmsLevel == 0)
}

@Test func workspaceExclusionSkipsRouteApplicationAndPreservesControls() async {
  let app = managedTestApp(
    desiredVolume: 0.6,
    volumeBoost: 2,
    targetDeviceUID: "device.old"
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.1,
      isMuted: true,
      volumeBoost: 4,
      equalizerSettings: EqualizerSettings(isEnabled: true),
      targetDeviceUID: "device.new",
      generation: 1,
      reason: .userEdit,
      isExcluded: true
    ))
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .excluded)
  #expect(await recorder.count() == 0)
  #expect(resultingApp.desiredVolume == 0.6)
  #expect(resultingApp.isMuted == false)
  #expect(resultingApp.volumeBoost == 2)
  #expect(resultingApp.targetDeviceUID == "device.old")
  #expect(resultingApp.routingState == .monitorOnly)
  #expect(resultingApp.appliedVolume == nil)
}

@Test func activeWaveLinkPreventsASecondManagedRenderer() async {
  let zoom = AudioApp(
    id: "runtime.zoom",
    logicalID: "us.zoom.xos",
    pid: 101,
    bundleID: "us.zoom.xos",
    displayName: "zoom.us",
    category: .conferencing,
    isActive: true,
    desiredVolume: 1,
    appliedVolume: 1,
    routingState: .managed,
    compatibility: .supported
  )
  let waveLink = AudioApp(
    id: "runtime.wave-link",
    logicalID: "com.elgato.WaveLink3",
    pid: 202,
    bundleID: "com.elgato.WaveLink3",
    displayName: "WaveLink",
    category: .unknown,
    isActive: true,
    desiredVolume: 1,
    appliedVolume: nil,
    routingState: .live,
    compatibility: .supported
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [zoom, waveLink]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    },
    verifiedRouterConflictProvider: { app in
      app.logicalID == zoom.logicalID
        ? VerifiedRouterConflict(
          routerName: "Elgato Wave Link",
          kind: .publicTapMembership,
          detail:
            "Elgato Wave Link is already routing this app's audio. "
            + "Waves left it untouched to prevent two copies. "
            + "Quit Elgato Wave Link before controlling this app in Waves."
        )
        : nil
    },
    perAppAudioController: .waveLink
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: zoom.logicalID,
      desiredVolume: 0.5,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 1,
      reason: .userEdit
    ))
  let resultingZoom = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .unsupported)
  #expect(result.detail?.contains("Wave Link") == true)
  #expect(result.detail?.contains("two copies") == true)
  #expect(resultingZoom.routingState == .monitorOnly)
  #expect(resultingZoom.desiredVolume == 1)
  #expect(resultingZoom.appliedVolume == nil)
  #expect(await recorder.count() == 0)
}

@Test func controllerPreferenceCannotBypassVerifiedWaveLinkCompatibility() async {
  let app = AudioApp(
    id: "runtime.browser",
    logicalID: "com.example.browser",
    pid: 101,
    bundleID: "com.example.browser",
    displayName: "Browser",
    category: .media,
    isActive: true,
    desiredVolume: 1,
    appliedVolume: 1,
    routingState: .managed,
    compatibility: .supported
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    },
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link is active, but its targets are not publicly attributable."
      )
    }
  )

  let wavesResult = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.7,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 1,
      reason: .userEdit
    )
  )
  await backend.setPerAppAudioController(.waveLink)
  let waveLinkResult = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.5,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 2,
      reason: .userEdit
    )
  )

  #expect(wavesResult.outcome == .unsupported)
  #expect(waveLinkResult.outcome == .unsupported)
  #expect(await recorder.count() == 0)
}

@Test func wavesControllerUsesWaveLinkBridgeWithoutCreatingASecondRenderer() async {
  let app = AudioApp(
    id: "runtime.browser",
    logicalID: "com.example.browser",
    pid: 101,
    bundleID: "com.example.browser",
    displayName: "Browser",
    category: .media,
    isActive: false,
    desiredVolume: 1,
    appliedVolume: 1,
    routingState: .managed,
    compatibility: .supported
  )
  let bridge = WaveLinkControllerSpy()
  let renderer = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await renderer.record(app: stagedApp, equalizer: equalizer)
    },
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: bridge
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 1,
      reason: .userEdit
    )
  )
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .applied)
  #expect(resultingApp.routingState == .monitorOnly)
  #expect(resultingApp.routeHealthContext == .waveLinkBridge)
  #expect(resultingApp.desiredVolume == 0)
  #expect(resultingApp.appliedVolume == 0)
  #expect(await bridge.requests == [.init(bundleIdentifier: "com.example.browser", volume: 0, isMuted: false)])
  #expect(await renderer.count() == 0)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)

  await backend.setPerAppAudioController(.waveLink)
  let handedOffApp = await backend.currentSnapshot().apps[0]
  #expect(handedOffApp.routeHealthContext == .unattributableRouterFallback)
  #expect(MixerRouteControlPolicy(app: handedOffApp).allowsAudioControl == false)
}

@Test func waveLinkBridgeFailureNeverFallsBackToAWavesRenderer() async {
  let app = AudioApp(
    id: "runtime.browser",
    logicalID: "com.example.browser",
    pid: 101,
    bundleID: "com.example.browser",
    displayName: "Browser",
    category: .media,
    desiredVolume: 1,
    appliedVolume: 1,
    routingState: .managed,
    compatibility: .supported
  )
  let bridge = WaveLinkControllerSpy(
    error: .dedicatedChannelRequired("com.example.browser")
  )
  let renderer = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await renderer.record(app: stagedApp, equalizer: equalizer)
    },
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: bridge
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.4,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 1,
      reason: .userEdit
    )
  )
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .failed)
  #expect(resultingApp.routingState == .monitorOnly)
  #expect(resultingApp.routeHealthContext == .waveLinkBridge)
  #expect(resultingApp.appliedVolume == nil)
  #expect(result.detail?.contains("empty software channel") == true)
  #expect(await renderer.count() == 0)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
}

@Test func switchingBackToWavesDoesNotBypassVerifiedWaveLinkCompatibility() async {
  let app = waveLinkYieldedTestApp()
  #expect(
    WorkspaceAudioControlBackend.isRouteRecoveryCandidate(
      app,
      hasActiveController: false,
      reclaimMixedOutput: false
    )
  )
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns this route."
      )
    },
    perAppAudioController: .waveLink,
    controllerFactory: waveLinkRecoveryControllerFactory,
    processObjectIDResolver: { _ in [1] }
  )

  await backend.setPerAppAudioController(.waves)
  await backend.reattachRoutesForTesting([app.logicalID])
  let recovered = await backend.currentSnapshot()

  #expect(recovered.apps[0].routingState == .monitorOnly)
  #expect(recovered.apps[0].routeHealthContext == .unattributableRouterFallback)
  #expect(recovered.apps[0].notes?.contains("Wave Link") == true)
}

@Test func disablingCompatibilityImmediatelyReclaimsAWaveLinkYieldedRoute() async {
  let app = waveLinkYieldedTestApp(context: .routerMixedOutput)
  #expect(
    WorkspaceAudioControlBackend.isRouteRecoveryCandidate(
      app,
      hasActiveController: false,
      reclaimMixedOutput: true
    )
  )
  #expect(
    !WorkspaceAudioControlBackend.isRouteRecoveryCandidate(
      app,
      hasActiveController: false,
      reclaimMixedOutput: false
    )
  )
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns this route."
      )
    },
    perAppAudioController: .waveLink,
    controllerFactory: waveLinkRecoveryControllerFactory,
    processObjectIDResolver: { _ in [1] }
  )

  await backend.setWaveLinkCompatibilityEnabled(false)
  await backend.reattachRoutesForTesting([app.logicalID])
  let recovered = await backend.currentSnapshot()

  #expect(recovered.apps[0].routingState == .managed)
  #expect(recovered.apps[0].routeHealthContext == nil)
}

@Test func controllerRoundTripCannotClaimUntouchedRows() async throws {
  let untouched = AudioApp(
    id: "runtime.untouched",
    logicalID: "com.example.untouched",
    pid: 404,
    bundleID: "com.example.untouched",
    displayName: "Untouched",
    category: .media,
    isActive: false,
    desiredVolume: 1,
    appliedVolume: nil,
    routingState: .monitorOnly,
    compatibility: .supported
  )
  let managed = AudioApp(
    id: "runtime.managed",
    logicalID: "com.example.managed",
    pid: 505,
    bundleID: "com.example.managed",
    displayName: "Managed",
    category: .media,
    isActive: true,
    desiredVolume: 0.7,
    appliedVolume: 0.7,
    routingState: .managed,
    compatibility: .supported
  )
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [untouched, managed]),
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: WaveLinkControllerSpy()
  )

  await backend.setPerAppAudioController(.waveLink)
  await backend.setPerAppAudioController(.waves)
  let snapshot = await backend.currentSnapshot()
  let untouchedRow = try #require(snapshot.apps.first { $0.logicalID == untouched.logicalID })
  let managedRow = try #require(snapshot.apps.first { $0.logicalID == managed.logicalID })

  // A row the user never managed or excluded from Waves must stay invisible to
  // conflict release and route recovery, or Wave Link quitting would promote
  // every app on the machine to a managed tap.
  #expect(untouchedRow.routingState == .monitorOnly)
  #expect(untouchedRow.routeHealthContext == nil)
  #expect(
    !WorkspaceAudioControlBackend.isRouteRecoveryCandidate(
      untouchedRow,
      hasActiveController: false,
      reclaimMixedOutput: true
    )
  )
  // The managed row yields to the router and stays reclaimable.
  #expect(managedRow.routingState == .monitorOnly)
  #expect(managedRow.routeHealthContext != nil)
  #expect(
    WorkspaceAudioControlBackend.isRouteRecoveryCandidate(
      managedRow,
      hasActiveController: false,
      reclaimMixedOutput: true
    )
  )
}

@Test func bridgeAppliesAreSerializedAndStaleWritesAreSkipped() async throws {
  let app = AudioApp(
    id: "runtime.browser",
    logicalID: "com.example.browser",
    pid: 101,
    bundleID: "com.example.browser",
    displayName: "Browser",
    category: .media,
    isActive: true,
    desiredVolume: 1,
    appliedVolume: 1,
    routingState: .managed,
    compatibility: .supported
  )
  let bridge = GatedWaveLinkControllerSpy()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: bridge
  )

  func intent(volume: Float, generation: UInt64) -> AppRouteIntent {
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: volume,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: generation,
      reason: .userEdit
    )
  }

  let first = Task { await backend.applyAppIntent(intent(volume: 0.3, generation: 1)) }
  #expect(await pollCondition { await bridge.requestCount() == 1 })

  let second = Task { await backend.applyAppIntent(intent(volume: 0.8, generation: 2)) }
  // With serialized applies the second intent cannot enter the bridge while
  // the first is still inside it; this can only observe 2 if that breaks.
  #expect(
    await pollCondition(timeout: .milliseconds(300)) { await bridge.requestCount() == 2 } == false
  )

  await bridge.openGate()
  let firstResult = await first.value
  let secondResult = await second.value

  #expect(firstResult.outcome == .superseded)
  #expect(secondResult.outcome == .applied)
  #expect(await bridge.maxConcurrentApplies == 1)
  #expect(
    await bridge.requests == [
      .init(bundleIdentifier: "com.example.browser", volume: 0.3, isMuted: false),
      .init(bundleIdentifier: "com.example.browser", volume: 0.8, isMuted: false),
    ]
  )
  let resulting = await backend.currentSnapshot().apps[0]
  #expect(resulting.desiredVolume == 0.8)
  #expect(resulting.routeHealthContext == .waveLinkBridge)
}

@Test func routerExitDuringBridgeApplyKeepsTheReclaimedTapAuthoritative() async throws {
  let app = AudioApp(
    id: "runtime.browser",
    logicalID: "com.example.browser",
    pid: 101,
    bundleID: "com.example.browser",
    displayName: "Browser",
    category: .media,
    isActive: true,
    desiredVolume: 1,
    appliedVolume: 1,
    routingState: .managed,
    compatibility: .supported
  )
  let conflictSwitch = RouterConflictSwitch(
    conflict: VerifiedRouterConflict(
      routerName: "Elgato Wave Link",
      kind: .unattributableTapFallback,
      detail: "Wave Link owns active Core Audio output.",
      supportsBridgeControl: true
    )
  )
  let bridge = GatedWaveLinkControllerSpy()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    verifiedRouterConflictProvider: { _ in conflictSwitch.conflict },
    waveLinkController: bridge,
    controllerFactory: waveLinkRecoveryControllerFactory,
    processObjectIDResolver: { _ in [1] }
  )

  // Let the conflict debouncer latch the active conflict first.
  await backend.markRouterObservationDirty()
  await backend.updateAudioLevels(at: .zero)
  await backend.updateAudioLevels(at: .milliseconds(300))

  let apply = Task {
    await backend.applyAppIntent(
      AppRouteIntent(
        appID: app.logicalID,
        desiredVolume: 0.3,
        isMuted: false,
        volumeBoost: 1,
        equalizerSettings: EqualizerSettings(),
        targetDeviceUID: nil,
        generation: 1,
        reason: .userEdit
      )
    )
  }
  #expect(await pollCondition { await bridge.requestCount() == 1 })

  // Wave Link quits while the bridge apply is suspended; conflict release
  // promotes the row back to managed and recreates the Waves tap.
  conflictSwitch.conflict = nil
  await backend.markRouterObservationDirty()
  await backend.updateAudioLevels(at: .milliseconds(600))
  await backend.updateAudioLevels(at: .milliseconds(900))
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)

  await bridge.openGate()
  let result = await apply.value
  let resultingApp = await backend.currentSnapshot().apps[0]
  let lifecycle = await backend.lifecycleDebugSnapshot()

  // The reclaimed Waves tap is authoritative. The stale bridge result must
  // never relabel the row as Wave Link-managed while a live tap renders it.
  #expect(result.outcome == .superseded)
  #expect(lifecycle.liveControllers == 1)
  #expect(resultingApp.routingState == .managed)
  #expect(resultingApp.routeHealthContext != .waveLinkBridge)
}

@Test func bridgeRefusesAPureDSPChangeInsteadOfClaimingItApplied() async {
  let app = AudioApp(
    id: "runtime.browser",
    logicalID: "com.example.browser",
    pid: 101,
    bundleID: "com.example.browser",
    displayName: "Browser",
    category: .media,
    isActive: true,
    desiredVolume: 0.5,
    appliedVolume: 0.5,
    routingState: .managed,
    compatibility: .supported
  )
  let bridge = WaveLinkControllerSpy()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: bridge
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.5,
      isMuted: false,
      volumeBoost: 2,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 1,
      reason: .userEdit
    )
  )

  #expect(result.outcome == .unavailable)
  #expect(result.detail?.contains("Boost, equalizer, and output routing are unavailable") == true)
  #expect(await bridge.requests.isEmpty)
}

@Test func waveLinkMixedOutputCannotBeWrappedInAWavesRenderer() async {
  let waveLink = AudioApp(
    id: "runtime.wave-link",
    logicalID: "com.elgato.WaveLink3",
    pid: 202,
    bundleID: "com.elgato.WaveLink3",
    displayName: "WaveLink",
    category: .unknown,
    isActive: false,
    desiredVolume: 1,
    appliedVolume: nil,
    routingState: .monitorOnly,
    compatibility: .supported
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [waveLink]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: waveLink.logicalID,
      desiredVolume: 0.5,
      isMuted: false,
      volumeBoost: 1,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: nil,
      generation: 1,
      reason: .userEdit
    )
  )

  #expect(result.outcome == .unsupported)
  #expect(result.detail?.contains("Wave Link") == true)
  #expect(result.detail?.contains("mixed output") == true)
  #expect(result.detail?.contains("silence the whole mix") == true)
  #expect(await recorder.count() == 0)
  #expect(await backend.currentSnapshot().apps[0].routingState == .monitorOnly)
}

@Test func workspaceIntentDoesNotCommitStaleWorkAfterSuspension() async {
  let gate = IntentRouteSuspensionGate()
  let app = managedTestApp(desiredVolume: 0.5)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, _ in
      if stagedApp.desiredVolume == 0.2 {
        await gate.suspend()
      }
    }
  )

  let olderTask = Task {
    await backend.applyAppIntent(
      testIntent(
        appID: app.logicalID,
        volume: 0.2,
        generation: 1
      ))
  }
  await gate.waitUntilSuspended()

  let newer = await backend.applyAppIntent(
    testIntent(
      appID: app.logicalID,
      volume: 0.8,
      generation: 2
    ))
  let snapshotAfterNewer = await backend.currentSnapshot()
  await gate.resume()
  let older = await olderTask.value
  let finalSnapshot = await backend.currentSnapshot()

  #expect(newer.outcome == .applied)
  #expect(older.outcome == .superseded)
  #expect(snapshotAfterNewer.apps[0].desiredVolume == 0.8)
  #expect(finalSnapshot == snapshotAfterNewer)
}

@Test func workspaceIntentFailurePreservesConfirmedControlsAndSurfacesDetail() async {
  let app = managedTestApp(
    desiredVolume: 0.55,
    isMuted: true,
    volumeBoost: 2.5,
    targetDeviceUID: "device.confirmed"
  )
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { _, _ in
      throw BackendError.managedRouteUnavailable("Deterministic route failure")
    }
  )

  let result = await backend.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.1,
      isMuted: false,
      volumeBoost: 4,
      equalizerSettings: EqualizerSettings(isEnabled: true),
      targetDeviceUID: "device.unconfirmed",
      generation: 3,
      reason: .automation
    ))
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .failed)
  #expect(result.detail == "Deterministic route failure")
  #expect(resultingApp.desiredVolume == 0.55)
  #expect(resultingApp.isMuted == true)
  #expect(resultingApp.volumeBoost == 2.5)
  #expect(resultingApp.targetDeviceUID == "device.confirmed")
  #expect(resultingApp.appliedVolume == 0)
  #expect(resultingApp.routingState == .error)
  #expect(resultingApp.notes == "Deterministic route failure")
}

@Test func protocolExistentialsDispatchToWorkspaceAndPreviewIntentOverrides() async {
  let collision = AudioApp(
    id: "dispatch-key",
    logicalID: "other-logical-id",
    displayName: "Collision",
    category: .unknown,
    desiredVolume: 0.9,
    compatibility: .supported
  )
  let intended = AudioApp(
    id: "runtime.dispatch",
    logicalID: "dispatch-key",
    displayName: "Intended",
    category: .media,
    desiredVolume: 0.3,
    compatibility: .supported
  )
  let recorder = AppliedIntentRecorder()
  let workspaceConcrete = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [collision, intended]),
    intentRouteApplyOverride: { app, equalizer in
      await recorder.record(app: app, equalizer: equalizer)
    }
  )
  let workspace: any AudioControlBackend = workspaceConcrete
  let previewConcrete = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [intended]))
  let preview: any AudioControlBackend = previewConcrete
  let intent = testIntent(appID: "dispatch-key", volume: 0.45, generation: 8)

  let workspaceResult = await workspace.applyAppIntent(intent)
  let previewResult = await preview.applyAppIntent(intent)
  let recordedApp = await recorder.lastApp()
  let workspaceSnapshot = await workspaceConcrete.currentSnapshot()

  #expect(workspaceResult.outcome == .applied)
  #expect(previewResult.outcome == .applied)
  #expect(recordedApp?.logicalID == "dispatch-key")
  #expect(workspaceSnapshot.apps[0].desiredVolume == 0.9)
  #expect(workspaceSnapshot.apps[1].desiredVolume == 0.45)
}

@Test func profileResultsStayOrderedAndMapEveryOutcome() async {
  let supported = AudioApp(
    id: "supported.runtime",
    logicalID: "supported.app",
    displayName: "Supported",
    category: .media,
    desiredVolume: 0.4,
    compatibility: .supported
  )
  let unsupported = AudioApp(
    id: "unsupported.runtime",
    logicalID: "unsupported.app",
    displayName: "Unsupported",
    category: .system,
    compatibility: .unsupported
  )
  let backend = PreviewAudioControlBackend(
    snapshot: testSnapshot(apps: [supported, unsupported])
  )
  let profile = Profile(
    name: "Ordered",
    entries: [
      ProfileEntry(appID: supported.logicalID),
      ProfileEntry(appID: "missing.app", desiredVolume: 0.2),
      ProfileEntry(appID: supported.logicalID, desiredVolume: 0.5),
      ProfileEntry(appID: supported.logicalID, desiredVolume: 0.5),
      ProfileEntry(appID: unsupported.logicalID, isMuted: true),
    ]
  )

  let result = await backend.applyProfileWithResults(profile, generation: 7)

  #expect(result.rows.map(\.entryIndex) == [0, 1, 2, 3, 4])
  #expect(
    result.rows.map(\.appID) == [
      supported.logicalID,
      "missing.app",
      supported.logicalID,
      supported.logicalID,
      unsupported.logicalID,
    ])
  #expect(
    result.rows.map(\.outcome) == [
      .membershipOnly,
      .unavailable,
      .applied,
      .noChange,
      .unsupported,
    ])
  #expect(result.rows.allSatisfy { $0.generation == 7 })

  _ = await backend.applyAppIntent(
    testIntent(
      appID: supported.logicalID,
      volume: 0.6,
      generation: 10
    ))
  let superseded = await backend.applyProfileWithResults(
    Profile(
      name: "Old",
      entries: [ProfileEntry(appID: supported.logicalID, desiredVolume: 0.1)]
    ),
    generation: 9
  )
  #expect(superseded.rows.map(\.outcome) == [.superseded])

  await backend.stop()
  let failed = await backend.applyProfileWithResults(
    Profile(
      name: "Stopped",
      entries: [ProfileEntry(appID: supported.logicalID, isMuted: true)]
    ),
    generation: 11
  )
  #expect(failed.rows.map(\.outcome) == [.failed])

  let mapped = [
    AppIntentApplyOutcome.applied,
    .noChange,
    .superseded,
    .excluded,
    .unavailable,
    .unsupported,
    .failed,
  ].map(ProfileRowApplyOutcome.init(appIntentOutcome:))
  #expect(
    mapped == [
      .applied,
      .noChange,
      .superseded,
      .excluded,
      .unavailable,
      .unsupported,
      .failed,
    ])
}

@Test func workspaceProfileResultsAreOrderedAndLegacyProfileSurfacesFailures() async {
  let supported = managedTestApp(desiredVolume: 0.4)
  let unsupported = AudioApp(
    id: "unsupported.runtime",
    logicalID: "unsupported.app",
    displayName: "Unsupported",
    category: .system,
    compatibility: .unsupported
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [supported, unsupported]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )
  let profile = Profile(
    name: "Workspace Ordered",
    entries: [
      ProfileEntry(appID: supported.logicalID),
      ProfileEntry(appID: "missing.app", desiredVolume: 0.2),
      ProfileEntry(appID: supported.logicalID, isMuted: true),
      ProfileEntry(appID: unsupported.logicalID, volumeBoost: 2),
    ]
  )

  let result = await backend.applyProfileWithResults(profile, generation: 42)

  #expect(result.rows.map(\.entryIndex) == [0, 1, 2, 3])
  #expect(
    result.rows.map(\.outcome) == [
      .membershipOnly,
      .unavailable,
      .applied,
      .unsupported,
    ])
  #expect(result.rows.allSatisfy { $0.generation == 42 })
  #expect(await recorder.count() == 1)

  var legacyThrew = false
  do {
    _ = try await backend.applyProfile(
      Profile(
        name: "Unavailable",
        entries: [ProfileEntry(appID: "missing.app", desiredVolume: 0.3)]
      ))
  } catch {
    legacyThrew = true
  }
  #expect(legacyThrew)
}

@Test func legacyAdaptersAllocateNewGenerationsAndPreserveCompleteIntentFields() async throws {
  let app = managedTestApp(
    desiredVolume: 0.4,
    isMuted: true,
    volumeBoost: 2,
    targetDeviceUID: "device.old"
  )
  let preview = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [app]))
  _ = await preview.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.5,
      isMuted: true,
      volumeBoost: 2,
      equalizerSettings: EqualizerSettings(),
      targetDeviceUID: "device.old",
      generation: 100,
      reason: .automation
    ))

  try await preview.setDesiredVolume(0.7, forAppID: app.logicalID)
  try await preview.setOutputDevice(uid: "device.new", forAppID: app.logicalID)
  let afterLegacyCalls = await preview.currentSnapshot().apps[0]
  let stale = await preview.applyAppIntent(
    AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: 0.1,
      isMuted: false,
      volumeBoost: 4,
      equalizerSettings: EqualizerSettings(isEnabled: true),
      targetDeviceUID: nil,
      generation: 100,
      reason: .automation
    ))

  #expect(afterLegacyCalls.desiredVolume == 0.7)
  #expect(afterLegacyCalls.isMuted == true)
  #expect(afterLegacyCalls.volumeBoost == 2)
  #expect(afterLegacyCalls.targetDeviceUID == "device.new")
  #expect(stale.outcome == .superseded)
  #expect(await preview.currentSnapshot().apps[0] == afterLegacyCalls)

  let recorder = AppliedIntentRecorder()
  let workspace = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )
  try await workspace.setDesiredVolume(0.65, forAppID: app.logicalID)
  let stagedApp = await recorder.lastApp()

  #expect(stagedApp?.desiredVolume == 0.65)
  #expect(stagedApp?.isMuted == true)
  #expect(stagedApp?.volumeBoost == 2)
  #expect(stagedApp?.targetDeviceUID == "device.old")

  let profileFailed = await legacyProfileThrows(
    on: preview,
    profile: Profile(
      name: "Unavailable",
      entries: [ProfileEntry(appID: "missing.app", desiredVolume: 0.3)]
    )
  )
  #expect(profileFailed)
}

@Test func concurrentWorkspaceLegacyAdaptersComposeFromLatestAcceptedIntent() async throws {
  let gate = IntentRouteSuspensionGate()
  let recorder = AppliedIntentRecorder()
  let app = managedTestApp(desiredVolume: 0.5)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
      if stagedApp.desiredVolume == 0.2, !stagedApp.isMuted {
        await gate.suspend()
      }
    }
  )

  let olderTask = Task {
    do {
      try await backend.setDesiredVolume(0.2, forAppID: app.logicalID)
      return false
    } catch {
      return true
    }
  }
  await gate.waitUntilSuspended()

  try await backend.setMuted(true, forAppID: app.logicalID)
  let afterNewer = await backend.currentSnapshot().apps[0]
  await gate.resume()
  let olderWasSuperseded = await olderTask.value
  let finalApp = await backend.currentSnapshot().apps[0]
  let lastStagedApp = await recorder.lastApp()

  #expect(olderWasSuperseded)
  #expect(lastStagedApp?.desiredVolume == 0.2)
  #expect(lastStagedApp?.isMuted == true)
  #expect(afterNewer.desiredVolume == 0.2)
  #expect(afterNewer.isMuted == true)
  #expect(finalApp == afterNewer)
}

@Test func stoppedPreviewBackendCanRestart() async throws {
  let app = managedTestApp(desiredVolume: 0.5)
  let backend = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [app]))
  await backend.stop()

  let stoppedResult = await backend.applyAppIntent(
    testIntent(
      appID: app.logicalID,
      volume: 0.2,
      generation: 1
    ))
  try await backend.start()
  let restartedResult = await backend.applyAppIntent(
    testIntent(
      appID: app.logicalID,
      volume: 0.8,
      generation: 1
    ))

  #expect(stoppedResult.outcome == .failed)
  #expect(restartedResult.outcome == .applied)
  #expect(await backend.currentSnapshot().apps[0].desiredVolume == 0.8)
}

private func testSnapshot(apps: [AudioApp]) -> AudioSessionSnapshot {
  AudioSessionSnapshot(
    apps: apps,
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

private func managedTestApp(
  desiredVolume: Float,
  isMuted: Bool = false,
  volumeBoost: Float = 1,
  targetDeviceUID: String? = nil
) -> AudioApp {
  AudioApp(
    id: "runtime.app",
    logicalID: "logical.app",
    displayName: "Managed App",
    category: .media,
    desiredVolume: desiredVolume,
    appliedVolume: isMuted ? 0 : desiredVolume,
    isMuted: isMuted,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: volumeBoost,
    targetDeviceUID: targetDeviceUID
  )
}

private func testIntent(
  appID: String,
  volume: Float,
  generation: UInt64,
  isExcluded: Bool = false
) -> AppRouteIntent {
  AppRouteIntent(
    appID: appID,
    desiredVolume: volume,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: generation,
    reason: .automation,
    isExcluded: isExcluded
  )
}

private func legacyProfileThrows(
  on backend: PreviewAudioControlBackend,
  profile: Profile
) async -> Bool {
  do {
    _ = try await backend.applyProfile(profile)
    return false
  } catch {
    return true
  }
}

private actor IntentRouteSuspensionGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isSuspended = false

  func suspend() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      self.isSuspended = true
    }
  }

  func waitUntilSuspended() async {
    while !isSuspended {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
    isSuspended = false
  }
}

private actor AppliedIntentRecorder {
  private var apps: [AudioApp] = []
  private var equalizers: [EqualizerSettings] = []

  func record(app: AudioApp, equalizer: EqualizerSettings) {
    apps.append(app)
    equalizers.append(equalizer)
  }

  func lastApp() -> AudioApp? {
    apps.last
  }

  func count() -> Int {
    apps.count
  }
}

private actor WaveLinkControllerSpy: WaveLinkControlling {
  struct Request: Equatable, Sendable {
    let bundleIdentifier: String
    let volume: Float
    let isMuted: Bool
  }

  private(set) var requests: [Request] = []
  private let error: WaveLinkControlBridgeError?

  init(error: WaveLinkControlBridgeError? = nil) {
    self.error = error
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) throws -> WaveLinkControlConfirmation {
    requests.append(
      Request(bundleIdentifier: bundleIdentifier, volume: volume, isMuted: isMuted)
    )
    if let error { throw error }
    return WaveLinkControlConfirmation(
      channelID: "dedicated",
      channelName: "Dedicated",
      appliedVolume: volume,
      isMuted: isMuted
    )
  }
}

private actor GatedWaveLinkControllerSpy: WaveLinkControlling {
  struct Request: Equatable, Sendable {
    let bundleIdentifier: String
    let volume: Float
    let isMuted: Bool
  }

  private(set) var requests: [Request] = []
  private(set) var maxConcurrentApplies = 0
  private var activeApplies = 0
  private var isGateOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func openGate() {
    isGateOpen = true
    let resumed = waiters
    waiters = []
    for waiter in resumed { waiter.resume() }
  }

  func requestCount() -> Int {
    requests.count
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) async throws -> WaveLinkControlConfirmation {
    activeApplies += 1
    maxConcurrentApplies = max(maxConcurrentApplies, activeApplies)
    requests.append(Request(bundleIdentifier: bundleIdentifier, volume: volume, isMuted: isMuted))
    if !isGateOpen {
      await withCheckedContinuation { waiters.append($0) }
    }
    activeApplies -= 1
    return WaveLinkControlConfirmation(
      channelID: "dedicated",
      channelName: "Dedicated",
      appliedVolume: volume,
      isMuted: isMuted
    )
  }
}

private final class RouterConflictSwitch: @unchecked Sendable {
  var conflict: VerifiedRouterConflict?

  init(conflict: VerifiedRouterConflict?) {
    self.conflict = conflict
  }
}

private func pollCondition(
  timeout: Duration = .seconds(5),
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

private func waveLinkYieldedTestApp(
  context: RouteHealthContext = .unattributableRouterFallback
) -> AudioApp {
  AudioApp(
    id: "runtime.yielded",
    logicalID: "com.example.yielded",
    pid: 303,
    bundleID: "com.example.yielded",
    displayName: "Yielded App",
    category: .media,
    isActive: true,
    desiredVolume: 0.6,
    appliedVolume: 0.6,
    routingState: .monitorOnly,
    compatibility: .supported,
    routeHealthContext: context
  )
}

private let waveLinkRecoveryControllerFactory: WorkspaceAudioControlBackend.ControllerFactory = {
  app,
  processObjectIDs,
  _,
  _,
  _ in
  try PerAppTapController.testingController(
    appID: app.id,
    logicalID: app.logicalID,
    targetProcessObjectIDs: processObjectIDs,
    teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
      makeOriginalAudioAudible: { 0 },
      stopIOProc: { 0 },
      restoreTapMuting: { 0 }
    )
  )
}
