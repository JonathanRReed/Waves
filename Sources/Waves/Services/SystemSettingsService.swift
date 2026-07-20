import AppKit
import Foundation

enum SystemSettingsDestination: String, CaseIterable, Sendable {
  case accessibility
  case audioCapture
  case loginItems
  case soundOutput

  var url: URL? {
    switch self {
    case .accessibility:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    case .audioCapture:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    case .loginItems:
      URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    case .soundOutput:
      URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?output")
    }
  }
}

@MainActor
struct SystemSettingsService {
  @discardableResult
  func open(_ destination: SystemSettingsDestination) -> Bool {
    guard let url = destination.url else { return false }
    return NSWorkspace.shared.open(url)
  }
}
