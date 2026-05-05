import Foundation

struct UserPreferences: Codable, Sendable {
  var launchAtLoginEnabled = false
  var showRecentApps = true
  var showSystemProcesses = false
  var sortMode: SortMode = .activity
  var customAppOrder: [String] = []
  var autoRestoreDevice = true
  var autoPauseMusicForConferencing = true
  var enableKeyboardShortcuts = true
  var enablePerDeviceVolumePresets = true
  var enableURLScheme = true
}

struct AppVolumeSettings: Codable, Hashable, Sendable {
  var desiredVolume: Float
  var isMuted: Bool
  var volumeBoost: Float

  init(desiredVolume: Float = 1.0, isMuted: Bool = false, volumeBoost: Float = 1.0) {
    self.desiredVolume = desiredVolume
    self.isMuted = isMuted
    self.volumeBoost = volumeBoost
  }
}

struct DeviceVolumePresets: Codable, Sendable {
  var deviceVolumes: [String: [String: AppVolumeSettings]] = [:]

  mutating func saveVolumeSettings(for appID: String, deviceID: String, settings: AppVolumeSettings) {
    if deviceVolumes[deviceID] == nil {
      deviceVolumes[deviceID] = [:]
    }
    deviceVolumes[deviceID]?[appID] = settings
  }

  func getVolumeSettings(for appID: String, deviceID: String) -> AppVolumeSettings? {
    deviceVolumes[deviceID]?[appID]
  }

  mutating func removeDevice(_ deviceID: String) {
    deviceVolumes.removeValue(forKey: deviceID)
  }
}

enum SortMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case activity
  case name
  case category
  case manual

  var id: Self { self }

  var displayName: String {
    switch self {
    case .activity:
      "Activity"
    case .name:
      "Name"
    case .category:
      "Category"
    case .manual:
      "Manual"
    }
  }
}
