import AudioToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func p11UnverifiedWaveLinkIdentityDoesNotBlockReattachment() {
  let unverifiedConflict = CompetingRouterConflictDecision.make(
    routerName: "Elgato Wave Link",
    isVerified: false
  )
  #expect(unverifiedConflict.routeDisposition == .none)
}

@Test func p12RendererStopFailureRestoresTapMutingBeforeItReturns() {
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
  #expect(result.audiblePath == .wavesRenderer)
  #expect(events == ["unmute-tap", "stop-io", "restore-tap-mute"])
}

@Test func p13GeometryMismatchSchedulesARecoveryInsteadOfOnlyLogging() {
  var recovery = GeometryRecoveryCoordinator(maximumAttempts: 1, baseBackoff: .milliseconds(1))
  #expect(recovery.signalMismatch(at: .zero) == .scheduleRecovery(at: .zero))
  #expect(recovery.beginRecovery(at: .zero) == .attempt(number: 1))
}

@Test func p14RouterReleaseIsNotBoundToTheFiveSecondMaintenancePoll() {
  var observation = RouterConflictObservationDebouncer(debounce: .milliseconds(250))
  _ = observation.observe(conflictIsActive: true, at: .zero)
  #expect(observation.advance(to: .milliseconds(250)) == .conflictActivated)
  _ = observation.observe(conflictIsActive: false, at: .milliseconds(300))
  #expect(observation.advance(to: .milliseconds(550)) == .conflictReleased)
}
