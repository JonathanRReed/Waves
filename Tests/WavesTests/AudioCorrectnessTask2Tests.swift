import AudioToolbox
import Testing
import WavesAudioCore

@testable import Waves

@Test func verifiedRouterConflictKeepsDeviceReattachmentMonitorOnly() {
  let verifiedConflict = CompetingRouterConflictDecision.make(
    routerName: "Elgato Wave Link",
    isVerified: true
  )
  let unverifiedConflict = CompetingRouterConflictDecision.make(
    routerName: "Elgato Wave Link",
    isVerified: false
  )

  #expect(verifiedConflict.routeDisposition == .monitorOnly)
  #expect(verifiedConflict.detail.contains("Elgato Wave Link"))
  #expect(unverifiedConflict.routeDisposition == .none)
}

@Test func unmuteThenRendererStopFailureRestoresTapMuteAndKeepsRendererAlive() {
  var events: [String] = []

  let result = MutingTapTeardownPreparation.perform(
    makeOriginalAudioAudible: {
      events.append("unmute-tap")
      return noErr
    },
    stopIOProc: {
      events.append("stop-io")
      return -1
    },
    restoreTapMuting: {
      events.append("restore-tap-mute")
      return noErr
    },
    deactivateRenderer: {
      events.append("deactivate-renderer")
    }
  )

  #expect(events == ["unmute-tap", "stop-io", "restore-tap-mute"])
  #expect(result.tapMuteRestoreStatus == noErr)
  #expect(!result.canDestroyNativeResources)
  #expect(result.keepsRendererAndCallbackResourcesAlive)
  #expect(result.audiblePath == .wavesRenderer)
}

@Test func failedMuteRollbackRetainsResourcesAndReportsCriticalDiagnostic() {
  let result = MutingTapTeardownPreparation.perform(
    makeOriginalAudioAudible: { noErr },
    stopIOProc: { -1 },
    restoreTapMuting: { -2 },
    deactivateRenderer: {}
  )

  #expect(result.tapMuteRestoreStatus == -2)
  #expect(result.keepsRendererAndCallbackResourcesAlive)
  #expect(result.criticalDiagnostic?.contains("mute rollback failed") == true)
  #expect(result.cleanupDegradation(appID: "app.test")?.stage == .controllerDisposal)
  #expect(result.cleanupDegradation(appID: "app.test")?.detail?.contains("mute rollback failed") == true)
}

@Test func muteRollbackFailureDegradationReachesTheBackendCleanupReport() async throws {
  let preparation = MutingTapTeardownPreparation.perform(
    makeOriginalAudioAudible: { noErr },
    stopIOProc: { -1 },
    restoreTapMuting: { -2 },
    deactivateRenderer: {}
  )
  let degradation = try #require(preparation.cleanupDegradation(appID: "app.test"))
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: AudioSessionSnapshot.empty,
    intentRouteApplyOverride: { _, _ in },
    shutdownCleanupOverride: { [degradation] }
  )

  let cleanupReport = await backend.shutdownWithResult()

  #expect(cleanupReport.completion == .degraded)
  #expect(cleanupReport.degradations == [degradation])
  #expect(cleanupReport.degradations.map(\.stage) == [.controllerDisposal])
}

@Test func geometryMismatchCoalescesIntoOneAsynchronousRecovery() {
  var recovery = GeometryRecoveryCoordinator(maximumAttempts: 3, baseBackoff: .milliseconds(100))

  #expect(recovery.signalMismatch(at: .zero) == .scheduleRecovery(at: .zero))
  #expect(recovery.signalMismatch(at: .zero) == .none)
  #expect(recovery.beginRecovery(at: .zero) == .attempt(number: 1))
  #expect(recovery.finishRecovery(succeeded: true, at: .zero) == .recovered)
  #expect(recovery.health == .healthy)
}

@Test func geometryRecoveryUsesBoundedBackoffAndPublishesExhaustedHealth() {
  var recovery = GeometryRecoveryCoordinator(maximumAttempts: 3, baseBackoff: .milliseconds(100))
  _ = recovery.signalMismatch(at: .zero)

  #expect(recovery.beginRecovery(at: .zero) == .attempt(number: 1))
  #expect(recovery.finishRecovery(succeeded: false, at: .zero) == .scheduleRecovery(at: .milliseconds(100)))
  #expect(recovery.beginRecovery(at: .milliseconds(100)) == .attempt(number: 2))
  #expect(recovery.finishRecovery(succeeded: false, at: .milliseconds(100)) == .scheduleRecovery(at: .milliseconds(300)))
  #expect(recovery.beginRecovery(at: .milliseconds(300)) == .attempt(number: 3))
  #expect(recovery.finishRecovery(succeeded: false, at: .milliseconds(300)) == .exhausted)
  #expect(recovery.health == .exhausted("Audio route recovery failed after 3 attempts. Refresh the route or restart Waves."))
}

@Test func routerObservationDebouncesConflictAndRecoversWithinOneSecond() {
  var observation = RouterConflictObservationDebouncer(debounce: .milliseconds(250))

  #expect(observation.observe(conflictIsActive: true, at: .zero) == .none)
  #expect(observation.advance(to: .milliseconds(249)) == .none)
  #expect(observation.advance(to: .milliseconds(250)) == .conflictActivated)
  #expect(observation.observe(conflictIsActive: false, at: .milliseconds(300)) == .none)
  #expect(observation.advance(to: .milliseconds(550)) == .conflictReleased)
}

@Test func routerListenerLifecycleReportsFailureRetriesAndRemovesOnlyInstalledSelectors() async {
  let recorder = RouterListenerCallRecorder()
  let lifecycle = RouterObservationListenerLifecycle(
    nativeCalls: RouterObservationListenerNativeCalls(
      add: { selector, listener in
        recorder.recordAdd(selector: selector, listener: listener)
        return selector == kAudioHardwarePropertyTapList && recorder.addCount(for: selector) == 1 ? -50 : noErr
      },
      remove: { selector, listener in
        recorder.recordRemove(selector: selector, listener: listener)
        return noErr
      }
    ),
    fallbackInterval: 2
  )
  let deliveries = ListenerDeliveryRecorder()

  let first = lifecycle.install { Task { await deliveries.record() } }

  #expect(first.count == 1)
  #expect(first[0].stage == CleanupStage.listenerInstallation)
  #expect(lifecycle.requiresFallbackReobservation)
  #expect(recorder.addedSelectors == [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyTapList])

  recorder.deliver(selector: kAudioHardwarePropertyProcessObjectList)
  let deliveryCount = await deliveries.waitForDelivery()
  #expect(deliveryCount == 1)

  #expect(!lifecycle.consumeFallbackReobservationTick())
  #expect(lifecycle.consumeFallbackReobservationTick())

  let second = lifecycle.install { Task { await deliveries.record() } }

  #expect(second.isEmpty)
  #expect(!lifecycle.requiresFallbackReobservation)
  #expect(
    recorder.addedSelectors == [
      kAudioHardwarePropertyProcessObjectList,
      kAudioHardwarePropertyTapList,
      kAudioHardwarePropertyTapList,
    ])

  let removal = lifecycle.remove()

  #expect(removal.isEmpty)
  #expect(
    recorder.removedSelectors == [
      kAudioHardwarePropertyProcessObjectList,
      kAudioHardwarePropertyTapList,
    ])
  #expect(recorder.removeBlocksMatchInstalledBlocks)
}

@Test func callbackGeometryMismatchFlowsThroughControllerIntoOneCoalescedMaintenanceRecovery() async throws {
  let app = AudioApp(
    id: "geometry.app",
    logicalID: "geometry.app",
    displayName: "Geometry App",
    category: .media,
    routingState: .managed,
    compatibility: .supported
  )
  let controller = try PerAppTapController.testingController(appID: app.id)
  let recorder = RouteMaintenanceRecorder()
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
    intentRouteApplyOverride: { _, _ in },
    testingControllers: [controller],
    routeMaintenanceOverride: { forceRebuildIDs, geometryRecoveryIDs in
      await recorder.record(forceRebuildIDs: forceRebuildIDs, geometryRecoveryIDs: geometryRecoveryIDs)
    }
  )

  controller.flagGeometryMismatchForTesting()
  controller.flagGeometryMismatchForTesting()
  await backend.updateAudioLevels(at: Duration.zero)

  #expect(
    await recorder.calls() == [
      RouteMaintenanceCall(forceRebuildIDs: [app.logicalID], geometryRecoveryIDs: [app.logicalID])
    ])
}

@Test func failedRouterListenerRegistrationAppearsInBackendHealthUntilFallbackAttaches() async {
  let recorder = RouterListenerCallRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: AudioSessionSnapshot.empty,
    intentRouteApplyOverride: { _, _ in },
    routerObservationNativeCalls: RouterObservationListenerNativeCalls(
      add: { selector, listener in
        recorder.recordAdd(selector: selector, listener: listener)
        return -50
      },
      remove: { selector, listener in
        recorder.recordRemove(selector: selector, listener: listener)
        return noErr
      }
    )
  )

  for tick in 0..<4 {
    await backend.updateAudioLevels(at: .milliseconds(tick * 250))
  }

  let snapshot = await backend.currentSnapshot()
  #expect(snapshot.backendStatus.lastError?.contains("could not attach a router observation listener") == true)
  #expect(
    recorder.addedSelectors == [
      kAudioHardwarePropertyProcessObjectList,
      kAudioHardwarePropertyTapList,
    ])
}

private final class RouterListenerCallRecorder: @unchecked Sendable {
  private var addCalls: [(AudioObjectPropertySelector, RouterObservationListenerBlockReference)] = []
  private var removeCalls: [(AudioObjectPropertySelector, RouterObservationListenerBlockReference)] = []

  var addedSelectors: [AudioObjectPropertySelector] { addCalls.map(\.0) }
  var removedSelectors: [AudioObjectPropertySelector] { removeCalls.map(\.0) }

  var removeBlocksMatchInstalledBlocks: Bool {
    removeCalls.allSatisfy { removeCall in
      addCalls.contains { addCall in addCall.0 == removeCall.0 && addCall.1 === removeCall.1 }
    }
  }

  func addCount(for selector: AudioObjectPropertySelector) -> Int {
    addCalls.count { $0.0 == selector }
  }

  func recordAdd(selector: AudioObjectPropertySelector, listener: RouterObservationListenerBlockReference) {
    addCalls.append((selector, listener))
  }

  func recordRemove(selector: AudioObjectPropertySelector, listener: RouterObservationListenerBlockReference) {
    removeCalls.append((selector, listener))
  }

  func deliver(selector: AudioObjectPropertySelector) {
    guard let listener = addCalls.first(where: { $0.0 == selector })?.1 else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    withUnsafePointer(to: &address) { pointer in
      listener.block(1, pointer)
    }
  }
}

private actor ListenerDeliveryRecorder {
  private var deliveries = 0

  func record() { deliveries += 1 }

  func waitForDelivery() async -> Int {
    for _ in 0..<100 {
      if deliveries > 0 { return deliveries }
      await Task.yield()
    }
    return deliveries
  }
}

private actor RouteMaintenanceRecorder {
  private var recordedCalls: [RouteMaintenanceCall] = []

  func record(forceRebuildIDs: Set<String>, geometryRecoveryIDs: Set<String>) {
    recordedCalls.append(
      RouteMaintenanceCall(forceRebuildIDs: forceRebuildIDs, geometryRecoveryIDs: geometryRecoveryIDs)
    )
  }

  func calls() -> [RouteMaintenanceCall] { recordedCalls }
}

private struct RouteMaintenanceCall: Equatable, Sendable {
  let forceRebuildIDs: Set<String>
  let geometryRecoveryIDs: Set<String>
}
