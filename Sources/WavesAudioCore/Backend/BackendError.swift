import Foundation

public enum BackendError: LocalizedError, Sendable {
  case appNotFound(String)
  case managedRouteUnavailable(String)
  case unsupportedOperation(String)
  /// A route could not be created because a normal user-facing app has no Core
  /// Audio process object right now. Browser and Electron apps often only get
  /// one while an audio helper is actively playing, so this is retryable.
  case noActiveAudioStream(String)
  /// A route could not be created because the process appears to be a true
  /// non-audio/system utility with no Core Audio process object. Kept distinct
  /// from `.noActiveAudioStream` so UI can suggest exclusion only when that is
  /// a reasonable, low-risk recommendation.
  case noAudioCapability(String)

  public var errorDescription: String? {
    switch self {
    case .appNotFound(let appID):
      "App not found: \(appID)"
    case .managedRouteUnavailable(let message):
      message
    case .unsupportedOperation(let message):
      message
    case .noActiveAudioStream(let message):
      message
    case .noAudioCapability(let message):
      message
    }
  }
}
