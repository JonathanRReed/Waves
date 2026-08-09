import Foundation

/// A separate invocation-level bound for the URL entry point. It runs before
/// parsing or setup UI, while `AutomationCommandParser` retains its existing
/// accepted-mutation quota behind those gates.
@MainActor
final class URLInvocationLimiter {
  typealias Clock = @MainActor @Sendable () -> Date

  static let maximumInvocations = 30
  static let window: TimeInterval = 60

  private let maximumInvocations: Int
  private let window: TimeInterval
  private let now: Clock
  private var invocationTimes: [Date] = []

  init(
    maximumInvocations: Int = URLInvocationLimiter.maximumInvocations,
    window: TimeInterval = URLInvocationLimiter.window,
    now: @escaping Clock = Date.init
  ) {
    self.maximumInvocations = max(0, maximumInvocations)
    self.window = max(0, window)
    self.now = now
  }

  func allow() -> Bool {
    let currentTime = now()
    let cutoff = currentTime.addingTimeInterval(-window)
    invocationTimes.removeAll { $0 < cutoff }
    guard invocationTimes.count < maximumInvocations else { return false }
    invocationTimes.append(currentTime)
    return true
  }

  func reset() {
    invocationTimes.removeAll()
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
    guard let url = parse(rawURLString), url.scheme == "waves" else { return }
    guard isAudioRunning() else {
      promptForSetup()
      presentSetup()
      return
    }
    perform(url)
  }
}
