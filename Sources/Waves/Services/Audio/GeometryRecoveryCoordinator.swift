import Foundation

enum GeometryRecoveryAction: Equatable, Sendable {
  case none
  case scheduleRecovery(at: Duration)
  case attempt(number: Int)
  case recovered
  case exhausted
}

enum GeometryRecoveryHealth: Equatable, Sendable {
  case healthy
  case recovering
  case exhausted(String)
}

struct GeometryRecoveryCoordinator: Sendable {
  private let maximumAttempts: Int
  private let baseBackoff: Duration
  private var attempts = 0
  private var scheduledRecoveryAt: Duration?
  private var recoveryInProgress = false
  private(set) var health: GeometryRecoveryHealth = .healthy

  var hasPendingRecoveryWork: Bool {
    scheduledRecoveryAt != nil || recoveryInProgress
  }

  init(maximumAttempts: Int = 3, baseBackoff: Duration = .milliseconds(250)) {
    self.maximumAttempts = max(1, maximumAttempts)
    self.baseBackoff = baseBackoff
  }

  mutating func signalMismatch(at now: Duration) -> GeometryRecoveryAction {
    guard scheduledRecoveryAt == nil, !recoveryInProgress, !isExhausted else { return .none }
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
      attempts = 0
      health = .healthy
      return .recovered
    }
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

  private var exhaustedDetail: String {
    "Audio route recovery failed after \(maximumAttempts) attempts. Refresh the route or restart Waves."
  }

  private func backoff(for attempt: Int) -> Duration {
    var delay = Duration.zero
    for _ in 0..<attempt { delay += baseBackoff }
    return delay
  }
}
