import AppKit
import Foundation

enum SystemSettingsDestination: String, CaseIterable, Sendable {
  case audioCapture
  case soundOutput

  var url: URL? {
    switch self {
    case .audioCapture:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    case .soundOutput:
      URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output")
    }
  }
}

@MainActor
struct SystemSettingsService {
  /// Allowed URL schemes for system settings deep links.
  private static let allowedSchemes: Set<String> = ["x-apple.systempreferences"]

  static func isAllowedSettingsURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return allowedSchemes.contains(scheme)
  }

  @discardableResult
  func open(_ destination: SystemSettingsDestination) -> Bool {
    guard let url = destination.url, Self.isAllowedSettingsURL(url) else { return false }
    return NSWorkspace.shared.open(url)
  }
}
