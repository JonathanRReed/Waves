import Foundation
import ServiceManagement

struct LoginItemStatus: Sendable {
  var isEnabled: Bool
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
    let currentStatus = service.status
    switch currentStatus {
    case .enabled:
      return LoginItemStatus(isEnabled: true, statusDescription: "Enabled")
    case .requiresApproval:
      return LoginItemStatus(isEnabled: false, statusDescription: "Requires approval", requiresApproval: true)
    case .notRegistered:
      return LoginItemStatus(isEnabled: false, statusDescription: "Disabled")
    case .notFound:
      return LoginItemStatus(isEnabled: false, statusDescription: "Not found")
    @unknown default:
      return LoginItemStatus(isEnabled: false, statusDescription: "Unknown")
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try service.register()
    } else {
      try service.unregister()
    }
  }
}
