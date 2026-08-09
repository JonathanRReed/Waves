import Foundation

enum AutomationCommand: Equatable, Sendable {
  case setVolume(appID: String, volume: Float)
  case setMuted(appID: String, isMuted: Bool)
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
  typealias Clock = @MainActor @Sendable () -> Date

  private let now: Clock
  private let maximumRequests: Int
  private let requestWindow: TimeInterval
  private let throttleNotificationInterval: TimeInterval
  private var acceptedRequestTimes: [Date] = []
  private var lastThrottleNotification: Date?
  private(set) var invocationCount = 0

  init(
    maximumRequests: Int = 10,
    requestWindow: TimeInterval = 60,
    throttleNotificationInterval: TimeInterval = 5,
    now: @escaping Clock = Date.init
  ) {
    self.maximumRequests = maximumRequests
    self.requestWindow = requestWindow
    self.throttleNotificationInterval = throttleNotificationInterval
    self.now = now
  }

  func parse(_ url: URL) -> AutomationCommandParseResult {
    invocationCount += 1

    guard url.absoluteString.utf8.count <= WavesURLPolicy.maxPayloadBytes else {
      return .rejected(
        AutomationCommandRejection(
          message: "The URL command exceeded the payload limit.",
          shouldPresent: false
        ))
    }
    guard url.scheme == "waves",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let host = components.host,
      !host.isEmpty
    else {
      return .rejected(
        AutomationCommandRejection(
          message: "The URL command was malformed.",
          shouldPresent: false
        ))
    }
    guard acceptRequest() else {
      let currentTime = now()
      let shouldNotify =
        lastThrottleNotification.map {
          currentTime.timeIntervalSince($0) >= throttleNotificationInterval
        } ?? true
      if shouldNotify { lastThrottleNotification = currentTime }
      return .throttled(shouldNotify: shouldNotify)
    }

    switch host {
    case "set-volume":
      guard let appID = queryValue(named: "app", in: components),
        let volumeValue = queryValue(named: "volume", in: components),
        appID.count <= 256,
        volumeValue.count <= 32,
        let volume = Float(volumeValue),
        volume.isFinite,
        volume >= 0,
        volume <= 1
      else {
        return presentedRejection("Set-volume command was invalid.")
      }
      return .accepted(.setVolume(appID: appID, volume: volume))

    case "mute":
      guard let appID = queryValue(named: "app", in: components),
        let muteValue = queryValue(named: "muted", in: components),
        appID.count <= 256,
        muteValue.count <= 16,
        let shouldMute = Bool(muteValue)
      else {
        return presentedRejection("Mute command was invalid.")
      }
      return .accepted(.setMuted(appID: appID, isMuted: shouldMute))

    case "apply-profile", "apply-preset":
      guard let profileName = queryValue(named: "name", in: components),
        profileName.count <= 256
      else {
        return presentedRejection("Profile command was invalid.")
      }
      return .accepted(.applyProfile(name: profileName))

    case "refresh":
      return .accepted(.refresh)

    default:
      return presentedRejection("Unknown command: \(String(host.prefix(64)))")
    }
  }

  func reset() {
    acceptedRequestTimes.removeAll()
    lastThrottleNotification = nil
  }

  func shutdown() {
    reset()
  }

  private func acceptRequest() -> Bool {
    let currentTime = now()
    let cutoff = currentTime.addingTimeInterval(-requestWindow)
    acceptedRequestTimes.removeAll { $0 < cutoff }
    guard acceptedRequestTimes.count < maximumRequests else { return false }
    acceptedRequestTimes.append(currentTime)
    return true
  }

  private func queryValue(named name: String, in components: URLComponents) -> String? {
    components.queryItems?.first(where: { $0.name == name })?.value
  }

  private func presentedRejection(_ message: String) -> AutomationCommandParseResult {
    .rejected(AutomationCommandRejection(message: message, shouldPresent: true))
  }
}
