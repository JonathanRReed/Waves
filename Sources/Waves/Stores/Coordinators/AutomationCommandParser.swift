import Foundation
import WavesAudioCore

enum AutomationCommand: Equatable, Sendable {
  case setVolume(appID: String, volume: Float)
  case setMuted(appID: String, isMuted: Bool)
  case toggleMute(appID: String)
  case setBoost(appID: String, boost: Float)
  case applyProfile(name: String)
  case refresh
}

struct AutomationCommandRejection: Equatable, Sendable {
  let message: String
  let shouldPresent: Bool
}

enum AutomationCommandParseResult: Equatable, Sendable {
  case accepted(AutomationCommand)
  case rejected(AutomationCommandRejection)
  case throttled(shouldNotify: Bool)
}

/// Stateful parser for the bounded `waves://` automation surface.
///
/// AppStore performs the disabled-feature and startup gates before invoking this
/// parser. The parser owns only validation and throttle state, and never mutates
/// application or audio state.
@MainActor
final class AutomationCommandParser {
  /// Seconds on a monotonic clock. Tests inject their own.
  typealias Clock = @MainActor @Sendable () -> TimeInterval

  static let maximumRequests = 10
  static let requestWindow: TimeInterval = 60
  static let throttleNotificationInterval: TimeInterval = 5
  static let defaultClock: Clock = { MonotonicClock.seconds() }

  private let now: Clock
  private let throttleNotificationInterval: TimeInterval
  private var acceptedRequests: SlidingWindowQuota
  private var lastThrottleNotification: TimeInterval?
  private(set) var invocationCount = 0

  init(
    maximumRequests: Int = AutomationCommandParser.maximumRequests,
    requestWindow: TimeInterval = AutomationCommandParser.requestWindow,
    throttleNotificationInterval: TimeInterval = AutomationCommandParser.throttleNotificationInterval,
    now: @escaping Clock = AutomationCommandParser.defaultClock
  ) {
    acceptedRequests = SlidingWindowQuota(
      limit: maximumRequests,
      window: requestWindow.isFinite ? max(0, requestWindow) : Self.requestWindow
    )
    self.throttleNotificationInterval =
      throttleNotificationInterval.isFinite
      ? max(0, throttleNotificationInterval) : Self.throttleNotificationInterval
    self.now = now
  }

  func parse(_ url: URL) -> AutomationCommandParseResult {
    invocationCount += 1

    let validated: AutomationCommand
    guard url.absoluteString.utf8.count <= WavesURLPolicy.maxPayloadBytes else {
      return .rejected(
        AutomationCommandRejection(
          message: "The URL command exceeded the payload limit.",
          shouldPresent: false
        ))
    }
    // RFC 3986 specifies URL schemes and hosts are case-insensitive.
    guard url.scheme?.lowercased() == "waves",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      !Self.containsControlCharacters(host)
    else {
      return .rejected(
        AutomationCommandRejection(
          message: "The URL command was malformed.",
          shouldPresent: false
        ))
    }
    switch host {
    case "set-volume":
      guard let appID = validAppID(in: components),
        let volume = LevelRange.volume.validated(text: queryValue(named: "volume", in: components))
      else {
        return presentedRejection("Set-volume command was invalid.")
      }
      validated = .setVolume(appID: appID, volume: volume)

    case "mute":
      guard let appID = validAppID(in: components),
        let muteValue = queryValue(named: "muted", in: components),
        muteValue.count <= 16,
        let shouldMute = Bool(muteValue)
      else {
        return presentedRejection("Mute command was invalid.")
      }
      validated = .setMuted(appID: appID, isMuted: shouldMute)

    case "toggle-mute":
      guard let appID = validAppID(in: components) else {
        return presentedRejection("Toggle-mute command was invalid.")
      }
      validated = .toggleMute(appID: appID)

    case "set-boost":
      // Refused outside 1...4, never clamped: a URL must not be able to ask
      // for more boost than the mixer offers.
      guard let appID = validAppID(in: components),
        let boost = LevelRange.boost.validated(text: queryValue(named: "boost", in: components))
      else {
        return presentedRejection("Set-boost command was invalid.")
      }
      validated = .setBoost(appID: appID, boost: boost)

    case "apply-profile", "apply-preset":
      guard let profileName = queryValue(named: "name", in: components),
        Self.isAcceptableProfileName(profileName)
      else {
        return presentedRejection("Profile command was invalid.")
      }
      validated = .applyProfile(name: profileName)

    case "refresh":
      validated = .refresh

    default:
      return presentedRejection("Unknown command: \(String(host.prefix(64)))")
    }

    let reading = now()
    guard acceptedRequests.admit(at: reading) else {
      // A non-finite reading is refused and never starts a notification
      // cooldown; time otherwise only moves forward (see SlidingWindowQuota).
      guard let currentTime = acceptedRequests.observe(reading) else {
        return .throttled(shouldNotify: false)
      }
      let shouldNotify =
        lastThrottleNotification.map { currentTime - $0 >= throttleNotificationInterval } ?? true
      if shouldNotify { lastThrottleNotification = currentTime }
      return .throttled(shouldNotify: shouldNotify)
    }
    return .accepted(validated)
  }

  func reset() {
    acceptedRequests.reset()
    lastThrottleNotification = nil
  }

  func shutdown() {
    reset()
  }

  /// Shared with the control socket so both surfaces accept the same names.
  static func isAcceptableProfileName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= Profile.maxNameLength && !Self.containsControlCharacters(name)
  }

  private func validAppID(in components: URLComponents) -> String? {
    guard let appID = queryValue(named: "app", in: components),
      !appID.isEmpty,
      appID.count <= 256,
      !Self.containsControlCharacters(appID)
    else { return nil }
    return appID
  }

  private func queryValue(named name: String, in components: URLComponents) -> String? {
    components.queryItems?.first(where: { $0.name == name })?.value
  }

  private func presentedRejection(_ message: String) -> AutomationCommandParseResult {
    .rejected(AutomationCommandRejection(message: message, shouldPresent: true))
  }

  private static func containsControlCharacters(_ string: String) -> Bool {
    string.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069:
        return true
      default:
        return false
      }
    }
  }
}
