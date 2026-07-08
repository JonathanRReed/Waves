import Foundation
import ServiceManagement

struct LoginItemStatus: Sendable {
  var isEnabled: Bool
  /// True when the item is registered or enabled, including the intermediate
  /// state where macOS is waiting for approval in System Settings.
  var isUserIntentEnabled: Bool
  var statusDescription: String
  /// True only when the OS reports the login item is registered but awaiting
  /// the user's approval in System Settings. Lets callers branch on the
  /// approval path without matching a localized status string.
  var requiresApproval: Bool = false
}

@MainActor
struct LoginItemService {
  private var service: SMAppService { .mainApp }

  var status: LoginItemStatus {
    Self.loginItemStatus(from: service.status)
  }

  nonisolated static func loginItemStatus(from status: SMAppService.Status) -> LoginItemStatus {
    switch status {
    case .enabled:
      return LoginItemStatus(isEnabled: true, isUserIntentEnabled: true, statusDescription: "Enabled")
    case .requiresApproval:
      return LoginItemStatus(
        isEnabled: false,
        isUserIntentEnabled: true,
        statusDescription: "Requires approval",
        requiresApproval: true
      )
    case .notRegistered:
      return LoginItemStatus(isEnabled: false, isUserIntentEnabled: false, statusDescription: "Disabled")
    case .notFound:
      return LoginItemStatus(isEnabled: false, isUserIntentEnabled: false, statusDescription: "Not found")
    @unknown default:
      return LoginItemStatus(isEnabled: false, isUserIntentEnabled: false, statusDescription: "Unknown")
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try service.register()
    } else {
      try service.unregister()
    }
  }

  func openSystemSettingsLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
