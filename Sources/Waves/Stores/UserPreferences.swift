import Foundation

struct UserPreferences: Codable, Sendable {
  var launchAtLoginEnabled = false
  var showRecentApps = true
  var showSystemProcesses = false
  var sortMode: SortMode = .activity
}

enum SortMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case activity
  case name
  case category

  var id: Self { self }

  var displayName: String {
    switch self {
    case .activity:
      "Activity"
    case .name:
      "Name"
    case .category:
      "Category"
    }
  }
}
