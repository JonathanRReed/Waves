import AudioToolbox
import Testing

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
