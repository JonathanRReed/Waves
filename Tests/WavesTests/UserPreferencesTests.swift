import Foundation
import ServiceManagement
import Testing
import WavesAudioCore

@testable import Waves

// MARK: - Login item status mapping

@Test func loginItemStatusMapsRequiresApprovalAsUserIntentEnabled() {
  let status = LoginItemService.loginItemStatus(from: .requiresApproval)
  #expect(status.isEnabled == false)
  #expect(status.isUserIntentEnabled == true)
  #expect(status.requiresApproval == true)
}

@Test func loginItemStatusMapsEnabledAndNotRegisteredIntent() {
  let enabled = LoginItemService.loginItemStatus(from: .enabled)
  #expect(enabled.isEnabled == true)
  #expect(enabled.isUserIntentEnabled == true)

  let disabled = LoginItemService.loginItemStatus(from: .notRegistered)
  #expect(disabled.isEnabled == false)
  #expect(disabled.isUserIntentEnabled == false)
}

// MARK: - Profile import decoding

@Test func decodeImportedProfilesAcceptsEmptyBackup() throws {
  // An empty-but-valid profiles backup must decode to [] (importable), not nil
  // (rejected) — and must not be misread as a single-Profile file.
  let data = try PersistedSchema.encode([Profile](), using: JSONEncoder())
  let decoded = AppStore.decodeImportedProfiles(from: data)
  #expect(decoded != nil)
  #expect(decoded?.isEmpty == true)
}

@Test func decodeImportedProfilesAcceptsSingleExportedProfile() throws {
  let profile = Profile(name: "Solo", entries: [ProfileEntry(appID: "com.example.app")])
  let data = try JSONEncoder().encode(profile)
  let decoded = AppStore.decodeImportedProfiles(from: data)
  #expect(decoded?.count == 1)
  #expect(decoded?.first?.name == "Solo")
}

// MARK: - Forward/backward-compatible decoding

@Test func userPreferencesDecodesFromEmptyObjectUsingDefaults() throws {
  // A preferences file from before any keys existed must still load as defaults
  // rather than throwing (which previously wiped all settings on upgrade).
  let data = Data("{}".utf8)
  let prefs = try JSONDecoder().decode(UserPreferences.self, from: data)
  #expect(prefs.showRecentApps == true)
  #expect(prefs.liveListLinger == .standard)
  #expect(prefs.enableKeyboardShortcuts == false)
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
  #expect(prefs.liveListLinger == .standard)
  #expect(prefs.enablePerDeviceVolumePresets == true) // default preserved
}

@Test func userPreferencesRoundTripsThroughCodable() throws {
  var prefs = UserPreferences()
  prefs.enableURLScheme = true
  prefs.liveListLinger = .relaxed
  prefs.sortMode = .category
  prefs.customAppOrder = ["com.a", "com.b"]
  prefs.excludedAppIDs = ["com.apple.logic", "com.zoom.xos"]
  prefs.pinnedAppIDs = ["com.spotify.client", "com.hnc.Discord"]

  let data = try JSONEncoder().encode(prefs)
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

  #expect(decoded.enableURLScheme == true)
  #expect(decoded.liveListLinger == .relaxed)
  #expect(decoded.sortMode == .category)
  #expect(decoded.customAppOrder == ["com.a", "com.b"])
  #expect(decoded.excludedAppIDs == ["com.apple.logic", "com.zoom.xos"])
  #expect(decoded.pinnedAppIDs == ["com.spotify.client", "com.hnc.Discord"])
}

@Test func userPreferencesDefaultsPinsEmptyForLegacyFile() throws {
  // Older files predate pinnedAppIDs; they must default to empty, not throw.
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
  #expect(decoded.pinnedAppIDs.isEmpty)
}

@Test func userPreferencesDefaultsExclusionsEmptyForLegacyFile() throws {
  // Older files predate exclusions; they must default to empty, not throw.
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
  #expect(decoded.excludedAppIDs.isEmpty)
}

@Test func preferencesStoreWritesPrivatePermissions() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-preferences-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = PreferencesStore(directory: directory)
  var prefs = UserPreferences()
  prefs.showRecentApps = false
  store.save(prefs)
  store.flush()

  let file = directory.appendingPathComponent("preferences.json")
  let directoryMode = try permissions(at: directory)
  let fileMode = try permissions(at: file)
  #expect(directoryMode == 0o700)
  #expect(fileMode == 0o600)
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

private func permissions(at url: URL) throws -> Int {
  let raw = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
  return raw?.intValue ?? -1
}
