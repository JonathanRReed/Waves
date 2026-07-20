import Foundation
import WavesAudioCore

struct UserPreferences: Codable, Sendable {
  var launchAtLoginEnabled = false
  var showRecentApps = true
  var liveListLinger: LiveListLinger = .standard
  var showSystemProcesses = false
  var sortMode: SortMode = .name
  var customAppOrder: [String] = []
  var autoPauseMusicForConferencing = true
  var enableKeyboardShortcuts = false
  var enablePerDeviceVolumePresets = true
  /// Whether switching the default output device should automatically restore
  /// that device's remembered per-app volumes (when `enablePerDeviceVolumePresets`
  /// is also on). Does NOT affect route recovery — Waves always re-establishes
  /// managed Core Audio routes on a device change regardless of this setting;
  /// that part isn't optional, since disabling it would silently break per-app
  /// volume/mute control until the user noticed and manually recovered routes.
  /// Defaults to on to match the existing behavior.
  var autoRestoreDevice = true
  var enableURLScheme = false
  var urlSchemeAutomationAcknowledged = false
  /// Logical IDs of apps the user has excluded from Waves' management — Waves
  /// will not tap or alter their audio (the escape hatch for DAWs, VoIP /
  /// echo-cancellation apps, and other audio tools that dislike being tapped).
  var excludedAppIDs: [String] = []
  /// Logical IDs of apps the user has pinned to the top of the menu bar. Stored
  /// here (rather than only on the per-app session row) so a pin survives the
  /// app quitting and relaunching, and a full relaunch of Waves.
  var pinnedAppIDs: [String] = []
  /// Legacy EQ-only map retained for one release during the additive schema-1
  /// app-intent rollout.
  var appEqualizerSettings: [String: EqualizerSettings] = [:]
  /// Durable audio intent keyed by logical app ID, independent of whether the app
  /// is running when Waves launches.
  var appAudioIntents: [String: PersistedAppAudioIntent] = [:]
  /// One-time migration version for folding legacy session and EQ state into
  /// `appAudioIntents`. New installs start after the migration.
  var appAudioIntentMigrationVersion = 1
  /// New installs see the privacy explanation before the first capture request.
  /// Existing preference files missing this key decode it as already completed.
  var hasCompletedPrivacySetup = false
  /// New installs continue through readiness and personalization after consent.
  /// Existing preference files skip the new walkthrough and can reopen it from Setup & Repair.
  var hasCompletedGuidedSetup = false
  /// Global adaptive processing mode. Temporary gains themselves are never persisted.
  var adaptiveMixMode: AdaptiveMixMode = .off
  /// Curated starting point for app content and priority policies.
  var adaptiveStrategy: AdaptiveStrategy = .balanced
  /// How audible frontmost apps interact with explicit adaptive priorities.
  var adaptiveFocusMode: AdaptiveFocusMode = .smartHybrid
  /// Explicit or migrated adaptive policy keyed by stable logical app ID.
  var adaptiveAppPolicies: [String: AdaptiveAppPolicy] = [:]
  /// The app's visual palette, independent from the selected light or dark appearance.
  var palette: WavesPalette = .waves
  /// Whether Waves follows macOS or forces a light or dark appearance.
  var appearance: WavesAppearance = .system
  /// Equalization applied to every stream currently managed by Waves.
  var managedAudioEqualizer = GlobalEqualizerSettings()

  init() {}

  private enum CodingKeys: String, CodingKey {
    case launchAtLoginEnabled
    case showRecentApps
    case liveListLinger
    case showSystemProcesses
    case sortMode
    case customAppOrder
    case autoPauseMusicForConferencing
    case enableKeyboardShortcuts
    case enablePerDeviceVolumePresets
    case autoRestoreDevice
    case enableURLScheme
    case urlSchemeAutomationAcknowledged
    case excludedAppIDs
    case pinnedAppIDs
    case appEqualizerSettings
    case appAudioIntents
    case appAudioIntentMigrationVersion
    case hasCompletedPrivacySetup
    case hasCompletedGuidedSetup
    case adaptiveMixMode
    case adaptiveStrategy
    case adaptiveFocusMode
    case adaptiveAppPolicies
    case palette
    case appearance
    case managedAudioEqualizer
  }

  // Missing fields use backward-compatible defaults. A present field with the
  // wrong type remains a decoding error so the store can preserve the damaged
  // file instead of silently replacing it with defaults.
  init(from decoder: Decoder) throws {
    let defaults = UserPreferences()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
      guard container.contains(key) else { return fallback }
      return try container.decodeIfPresent(T.self, forKey: key) ?? fallback
    }
    launchAtLoginEnabled = try value(.launchAtLoginEnabled, defaults.launchAtLoginEnabled)
    showRecentApps = try value(.showRecentApps, defaults.showRecentApps)
    liveListLinger = try value(.liveListLinger, defaults.liveListLinger)
    showSystemProcesses = try value(.showSystemProcesses, defaults.showSystemProcesses)
    sortMode = try value(.sortMode, defaults.sortMode)
    customAppOrder = try value(.customAppOrder, defaults.customAppOrder)
    autoPauseMusicForConferencing = try value(
      .autoPauseMusicForConferencing, defaults.autoPauseMusicForConferencing)
    enableKeyboardShortcuts = try value(.enableKeyboardShortcuts, defaults.enableKeyboardShortcuts)
    enablePerDeviceVolumePresets = try value(
      .enablePerDeviceVolumePresets, defaults.enablePerDeviceVolumePresets)
    autoRestoreDevice = try value(.autoRestoreDevice, defaults.autoRestoreDevice)
    enableURLScheme = try value(.enableURLScheme, defaults.enableURLScheme)
    urlSchemeAutomationAcknowledged = try value(
      .urlSchemeAutomationAcknowledged, defaults.urlSchemeAutomationAcknowledged)
    excludedAppIDs = try value(.excludedAppIDs, defaults.excludedAppIDs)
    pinnedAppIDs = try value(.pinnedAppIDs, defaults.pinnedAppIDs)
    appEqualizerSettings = try value(.appEqualizerSettings, defaults.appEqualizerSettings)
    appAudioIntents = try value(.appAudioIntents, defaults.appAudioIntents)
    // Preference files predating durable app intents must run the migration once.
    appAudioIntentMigrationVersion = try value(.appAudioIntentMigrationVersion, 0)
    // A preference file predating guided setup belongs to an existing install.
    hasCompletedPrivacySetup = try value(.hasCompletedPrivacySetup, true)
    hasCompletedGuidedSetup = try value(.hasCompletedGuidedSetup, true)
    adaptiveMixMode = try value(.adaptiveMixMode, defaults.adaptiveMixMode)
    adaptiveStrategy = try value(.adaptiveStrategy, defaults.adaptiveStrategy)
    adaptiveFocusMode = try value(.adaptiveFocusMode, defaults.adaptiveFocusMode)
    adaptiveAppPolicies = try value(.adaptiveAppPolicies, defaults.adaptiveAppPolicies)
    palette = try value(.palette, defaults.palette)
    appearance = try value(.appearance, defaults.appearance)
    managedAudioEqualizer = try value(.managedAudioEqualizer, defaults.managedAudioEqualizer)
  }
}

enum LiveListLinger: String, Codable, CaseIterable, Identifiable, Sendable {
  case brief
  case standard
  case relaxed

  var id: Self { self }

  var displayName: String {
    switch self {
    case .brief:
      "Brief"
    case .standard:
      "Standard"
    case .relaxed:
      "Relaxed"
    }
  }

  var duration: Duration {
    switch self {
    case .brief:
      .seconds(1)
    case .standard:
      .milliseconds(2500)
    case .relaxed:
      .seconds(5)
    }
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

  mutating func saveVolumeSettings(for appID: String, deviceID: String, settings: AppVolumeSettings)
  {
    if deviceVolumes[deviceID] == nil {
      deviceVolumes[deviceID] = [:]
    }
    deviceVolumes[deviceID]?[appID] = settings
  }

  func getVolumeSettings(for appID: String, deviceID: String) -> AppVolumeSettings? {
    deviceVolumes[deviceID]?[appID]
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
