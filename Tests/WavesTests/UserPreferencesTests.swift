import Foundation
import Testing

@testable import Waves

// MARK: - Forward/backward-compatible decoding

@Test func userPreferencesDecodesFromEmptyObjectUsingDefaults() throws {
  // A preferences file from before any keys existed must still load as defaults
  // rather than throwing (which previously wiped all settings on upgrade).
  let data = Data("{}".utf8)
  let prefs = try JSONDecoder().decode(UserPreferences.self, from: data)
  #expect(prefs.showRecentApps == true)
  #expect(prefs.enableURLScheme == false)
  #expect(prefs.sortMode == .name)
}

@Test func userPreferencesPreservesKnownKeysAndDefaultsMissingOnes() throws {
  // Simulates an older file that predates the `enablePerDeviceVolumePresets`
  // key: the present key is honored, the missing one falls back to its default.
  let json = """
  { "enableKeyboardShortcuts": false, "sortMode": "activity" }
  """
  let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
  #expect(prefs.enableKeyboardShortcuts == false)
  #expect(prefs.sortMode == .activity)
  #expect(prefs.enablePerDeviceVolumePresets == true) // default preserved
}

@Test func userPreferencesRoundTripsThroughCodable() throws {
  var prefs = UserPreferences()
  prefs.enableURLScheme = true
  prefs.sortMode = .category
  prefs.customAppOrder = ["com.a", "com.b"]

  let data = try JSONEncoder().encode(prefs)
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

  #expect(decoded.enableURLScheme == true)
  #expect(decoded.sortMode == .category)
  #expect(decoded.customAppOrder == ["com.a", "com.b"])
}

// MARK: - Per-app volume settings

@Test func appVolumeSettingsClampsBoostOnInit() {
  let tooHigh = AppVolumeSettings(desiredVolume: 0.5, isMuted: false, volumeBoost: 9)
  #expect(tooHigh.volumeBoost == 4.0)

  let tooLow = AppVolumeSettings(desiredVolume: 0.5, isMuted: false, volumeBoost: 0)
  #expect(tooLow.volumeBoost == 1.0)
}

@Test func appVolumeSettingsDecodeToleratesMissingKeys() throws {
  let prefs = try JSONDecoder().decode(AppVolumeSettings.self, from: Data("{}".utf8))
  #expect(prefs.desiredVolume == 1.0)
  #expect(prefs.isMuted == false)
  #expect(prefs.volumeBoost == 1.0)
}
