import Foundation

/// Counts admissions inside a trailing window of monotonic time.
///
/// Time only moves forward here: a reading earlier than one already seen is
/// treated as the latest one. With the production monotonic clock that never
/// happens; with an injected clock it means stepping backwards can neither
/// reopen a spent quota nor make old admissions look like future ones.
struct SlidingWindowQuota {
  private let limit: Int
  private let window: TimeInterval
  private var admissions: [TimeInterval] = []
  private var latest: TimeInterval?

  init(limit: Int, window: TimeInterval) {
    self.limit = max(0, limit)
    self.window = window
  }

  /// The time this quota treats as now, or nil for a non-finite reading,
  /// which callers must treat as a refusal.
  mutating func observe(_ reading: TimeInterval) -> TimeInterval? {
    guard reading.isFinite else { return nil }
    let now = max(latest ?? reading, reading)
    latest = now
    return now
  }

  mutating func admit(at reading: TimeInterval) -> Bool {
    guard let now = observe(reading) else { return false }
    let cutoff = now - window
    admissions.removeAll { $0 < cutoff }
    guard admissions.count < limit else { return false }
    admissions.append(now)
    return true
  }

  mutating func reset() {
    admissions.removeAll()
  }
}

/// A separate invocation-level bound for the URL entry point. It runs before
/// parsing or setup UI, while `AutomationCommandParser` retains its existing
/// accepted-mutation quota behind those gates.
@MainActor
final class URLInvocationLimiter {
  /// Seconds on a monotonic clock. Tests inject their own.
  typealias Clock = @MainActor @Sendable () -> TimeInterval

  static let maximumInvocations = 30
  static let window: TimeInterval = 60
  static let defaultClock: Clock = { MonotonicClock.seconds() }

  private let now: Clock
  private var quota: SlidingWindowQuota

  init(
    maximumInvocations: Int = URLInvocationLimiter.maximumInvocations,
    window: TimeInterval = URLInvocationLimiter.window,
    now: @escaping Clock = URLInvocationLimiter.defaultClock
  ) {
    quota = SlidingWindowQuota(
      limit: maximumInvocations,
      window: window.isFinite ? max(0, window) : URLInvocationLimiter.window
    )
    self.now = now
  }

  func allow() -> Bool {
    quota.admit(at: now())
  }

  func reset() {
    quota.reset()
  }
}

/// Orders URL automation checks so disabled automation cannot cause parsing,
/// setup presentation, activation, or a store mutation.
@MainActor
struct URLAutomationRouter {
  let isEnabled: () -> Bool
  let admitInvocation: () -> Bool
  let isAudioRunning: () -> Bool
  let parse: (String) -> URL?
  let promptForSetup: () -> Void
  let presentSetup: () -> Void
  let perform: (URL) -> Void

  init(
    isEnabled: @escaping () -> Bool,
    admitInvocation: @escaping () -> Bool = { true },
    isAudioRunning: @escaping () -> Bool,
    parse: @escaping (String) -> URL?,
    promptForSetup: @escaping () -> Void,
    presentSetup: @escaping () -> Void,
    perform: @escaping (URL) -> Void
  ) {
    self.isEnabled = isEnabled
    self.admitInvocation = admitInvocation
    self.isAudioRunning = isAudioRunning
    self.parse = parse
    self.promptForSetup = promptForSetup
    self.presentSetup = presentSetup
    self.perform = perform
  }

  func handle(rawURLString: String) {
    guard isEnabled() else { return }
    guard admitInvocation() else { return }
    // RFC 3986 specifies URL schemes are case-insensitive.
    guard let url = parse(rawURLString), url.scheme?.lowercased() == "waves" else { return }
    guard isAudioRunning() else {
      promptForSetup()
      presentSetup()
      return
    }
    perform(url)
  }
}
