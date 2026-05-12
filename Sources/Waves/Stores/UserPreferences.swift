import Foundation

struct UserPreferences: Codable, Sendable {
  var launchAtLoginEnabled = false
  var showRecentApps = true
  var showSystemProcesses = false
  var sortMode: SortMode = .name
  var customAppOrder: [String] = []
  var autoRestoreDevice = true
  var autoPauseMusicForConferencing = true
  var enableKeyboardShortcuts = true
  var enablePerDeviceVolumePresets = true
  var enableURLScheme = false
  var urlSchemeAutomationAcknowledged = false
}

struct AppVolumeSettings: Codable, Hashable, Sendable {
  var desiredVolume: Float
  var isMuted: Bool
  var volumeBoost: Float

  init(desiredVolume: Float = 1.0, isMuted: Bool = false, volumeBoost: Float = 1.0) {
    self.desiredVolume = desiredVolume
    self.isMuted = isMuted
    self.volumeBoost = max(1.0, min(4.0, volumeBoost))
  }

  private enum CodingKeys: String, CodingKey {
    case desiredVolume
    case isMuted
    case volumeBoost
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let desiredVolume = try container.decodeIfPresent(Float.self, forKey: .desiredVolume) ?? 1.0
    let isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    let volumeBoost = try container.decodeIfPresent(Float.self, forKey: .volumeBoost) ?? 1.0
    self.init(desiredVolume: desiredVolume, isMuted: isMuted, volumeBoost: volumeBoost)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(desiredVolume, forKey: .desiredVolume)
    try container.encode(isMuted, forKey: .isMuted)
    try container.encode(volumeBoost, forKey: .volumeBoost)
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
