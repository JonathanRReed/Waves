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
