import Foundation

enum GeometryRecoveryAction: Equatable, Sendable {
  case none
  case scheduleRecovery(at: Duration)
  case attempt(number: Int)
  /// The route was rebuilt; it now has to render clean cycles for the whole
  /// verification window before the attempt counts as a success.
  case verifying
  case recovered
  case exhausted
}

enum GeometryRecoveryHealth: Equatable, Sendable {
  case healthy
  case recovering
  case exhausted(String)
}

/// Paces the rebuild of a route whose IO callback reported buffers that do not
/// match the tap's format plan.
///
/// A rebuild only proves anything once the new route has rendered without a
/// mismatch for `verificationWindow`: tap and aggregate creation succeed even
/// when the device geometry is the problem, and the mismatch then shows up
/// again on the very next IO cycle. Treating creation itself as success reset
/// the attempt counter every time, so a persistent mismatch rebuilt the tap
/// and aggregate device four times a second for as long as the app ran, with
/// the app silenced the whole time and every other audio client on the
/// machine watching the device list change twice per cycle.
struct GeometryRecoveryCoordinator: Sendable {
  private let maximumAttempts: Int
  private let baseBackoff: Duration
  private let verificationWindow: Duration
  private var attempts = 0
  private var scheduledRecoveryAt: Duration?
  private var recoveryInProgress = false
  private var verifyingSince: Duration?
  private(set) var health: GeometryRecoveryHealth = .healthy

  /// A rebuild is scheduled or running. Passive verification of a finished
  /// rebuild is not pending work: nothing will be created or destroyed unless
  /// the callback reports another mismatch.
  var hasPendingRecoveryWork: Bool {
    scheduledRecoveryAt != nil || recoveryInProgress
  }

  var isVerifying: Bool { verifyingSince != nil }

  init(
    maximumAttempts: Int = 3,
    baseBackoff: Duration = .milliseconds(250),
    verificationWindow: Duration = .seconds(1)
  ) {
    self.maximumAttempts = max(1, maximumAttempts)
    self.baseBackoff = baseBackoff
    self.verificationWindow = verificationWindow
  }

  mutating func signalMismatch(at now: Duration) -> GeometryRecoveryAction {
    guard scheduledRecoveryAt == nil, !recoveryInProgress, !isExhausted else { return .none }
    if verifyingSince != nil {
      // The rebuilt route mismatched again inside its verification window, so
      // that attempt failed; back off or give up instead of rebuilding at once.
      verifyingSince = nil
      return scheduleNextAttemptOrExhaust(at: now)
    }
    scheduledRecoveryAt = now
    health = .recovering
    return .scheduleRecovery(at: now)
  }

  mutating func beginRecovery(at now: Duration) -> GeometryRecoveryAction {
    guard let scheduledRecoveryAt, now >= scheduledRecoveryAt, !recoveryInProgress else { return .none }
    self.scheduledRecoveryAt = nil
    recoveryInProgress = true
    attempts += 1
    return .attempt(number: attempts)
  }

  mutating func finishRecovery(succeeded: Bool, at now: Duration) -> GeometryRecoveryAction {
    guard recoveryInProgress else { return .none }
    recoveryInProgress = false
    if succeeded {
      verifyingSince = now
      health = .recovering
      return .verifying
    }
    return scheduleNextAttemptOrExhaust(at: now)
  }

  /// Advances the verification window. Returns `.recovered` once the rebuilt
  /// route has rendered mismatch-free for the whole window.
  mutating func advance(to now: Duration) -> GeometryRecoveryAction {
    guard let verifyingSince, now - verifyingSince >= verificationWindow else { return .none }
    self.verifyingSince = nil
    attempts = 0
    health = .healthy
    return .recovered
  }

  private mutating func scheduleNextAttemptOrExhaust(at now: Duration) -> GeometryRecoveryAction {
    guard attempts < maximumAttempts else {
      health = .exhausted(exhaustedDetail)
      return .exhausted
    }
    let next = now + backoff(for: attempts)
    scheduledRecoveryAt = next
    health = .recovering
    return .scheduleRecovery(at: next)
  }

  private var isExhausted: Bool {
    if case .exhausted = health { return true }
    return false
  }

  var exhaustedDetail: String {
    "Audio route recovery failed after \(maximumAttempts) attempts. Refresh the route or restart Waves."
  }

  private func backoff(for attempt: Int) -> Duration {
    var delay = Duration.zero
    for _ in 0..<attempt { delay += baseBackoff }
    return delay
  }
}
