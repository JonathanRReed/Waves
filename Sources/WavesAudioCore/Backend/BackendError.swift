import Foundation

public enum BackendError: LocalizedError, Sendable {
  case appNotFound(String)
  case managedRouteUnavailable(String)
  case unsupportedOperation(String)

  public var errorDescription: String? {
    switch self {
    case .appNotFound(let appID):
      "App not found: \(appID)"
    case .managedRouteUnavailable(let message):
      message
    case .unsupportedOperation(let message):
      message
    }
  }
}
