import Foundation

public enum BackendError: LocalizedError, Sendable {
  case appNotFound(String)
  case managedRouteUnavailable(String)
  case unsupportedOperation(String)
  /// A route could not be created because the app has never engaged the audio
  /// subsystem and so has no Core Audio process object — a permanent property
  /// of that process (a menu-bar utility, CLI tool, background helper), not a
  /// transient failure. Kept distinct from `.managedRouteUnavailable` so route
  /// health/diagnostics can tell "this will never route" apart from "routing
  /// broke and retrying might fix it."
  case noAudioCapability(String)

  public var errorDescription: String? {
    switch self {
    case .appNotFound(let appID):
      "App not found: \(appID)"
    case .managedRouteUnavailable(let message):
      message
    case .unsupportedOperation(let message):
      message
    case .noAudioCapability(let message):
      message
    }
  }
}
