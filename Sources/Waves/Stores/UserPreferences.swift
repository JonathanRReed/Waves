import Foundation

struct UserPreferences: Codable, Sendable {
  var launchAtLoginEnabled = false
  var showRecentApps = true
  var showSystemProcesses = false
  var sortMode: SortMode = .name
  var customAppOrder: [String] = []
  var autoPauseMusicForConferencing = true
  var enableKeyboardShortcuts = true
  var enablePerDeviceVolumePresets = true
  var enableURLScheme = false
  var urlSchemeAutomationAcknowledged = false
  /// Logical IDs of apps the user has excluded from Waves' management — Waves
  /// will not tap or alter their audio (the escape hatch for DAWs, VoIP /
  /// echo-cancellation apps, and other audio tools that dislike being tapped).
  var excludedAppIDs: [String] = []

  init() {}

  private enum CodingKeys: String, CodingKey {
    case launchAtLoginEnabled
    case showRecentApps
    case showSystemProcesses
    case sortMode
    case customAppOrder
    case autoPauseMusicForConferencing
    case enableKeyboardShortcuts
    case enablePerDeviceVolumePresets
    case enableURLScheme
    case urlSchemeAutomationAcknowledged
    case excludedAppIDs
  }

  // Decode each field independently so a preferences file written by an older
  // build (missing keys added in a later version) loads cleanly instead of
  // throwing and wiping every saved setting on the first launch after an update.
  init(from decoder: Decoder) throws {
    let defaults = UserPreferences()
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      self = defaults
      return
    }
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
      (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback
    }
    launchAtLoginEnabled = value(.launchAtLoginEnabled, defaults.launchAtLoginEnabled)
    showRecentApps = value(.showRecentApps, defaults.showRecentApps)
    showSystemProcesses = value(.showSystemProcesses, defaults.showSystemProcesses)
    sortMode = value(.sortMode, defaults.sortMode)
    customAppOrder = value(.customAppOrder, defaults.customAppOrder)
    autoPauseMusicForConferencing = value(.autoPauseMusicForConferencing, defaults.autoPauseMusicForConferencing)
    enableKeyboardShortcuts = value(.enableKeyboardShortcuts, defaults.enableKeyboardShortcuts)
    enablePerDeviceVolumePresets = value(.enablePerDeviceVolumePresets, defaults.enablePerDeviceVolumePresets)
    enableURLScheme = value(.enableURLScheme, defaults.enableURLScheme)
    urlSchemeAutomationAcknowledged = value(.urlSchemeAutomationAcknowledged, defaults.urlSchemeAutomationAcknowledged)
    excludedAppIDs = value(.excludedAppIDs, defaults.excludedAppIDs)
  }
}

struct AppVolumeSettings: Codable, Hashable, Sendable {
  var desiredVolume: Float
  var isMuted: Bool
  var volumeBoost: Float

  init(desiredVolume: Float = 1.0, isMuted: Bool = false, volumeBoost: Float = 1.0) {
    self.desiredVolume = max(0.0, min(1.0, desiredVolume))
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
