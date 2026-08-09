import Carbon.HIToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func exactOneFourFourFixtureUpgradesOnceAndRelaunchesEquivalently() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-1.4.4-upgrade-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let expected = try await OneFourFourFixtureBuilder.write(to: directory)
  let first = makeUpgradeStore(directory: directory, snapshot: expected.snapshot)
  await first.drainPersistenceTasks()

  assertUpgradedState(first, expected: expected)
  let firstProfiles = first.profiles
  let firstIntent = first.preferences.appAudioIntents[expected.appID]
  let firstPreset = first.deviceVolumePresets.getVolumeSettings(
    for: expected.appID,
    deviceID: expected.device.id
  )

  _ = await first.shutdown()
  #expect(first.lifecycleSnapshot.isIdle)

  let second = makeUpgradeStore(directory: directory, snapshot: expected.snapshot)
  await second.drainPersistenceTasks()

  assertUpgradedState(second, expected: expected)
  #expect(second.profiles == firstProfiles)
  #expect(second.preferences.appAudioIntents[expected.appID] == firstIntent)
  #expect(
    second.deviceVolumePresets.getVolumeSettings(
      for: expected.appID,
      deviceID: expected.device.id
    ) == firstPreset
  )

  _ = await second.shutdown()
  #expect(second.lifecycleSnapshot.isIdle)
}

@MainActor
private func makeUpgradeStore(
  directory: URL,
  snapshot: AudioSessionSnapshot
) -> AppStore {
  AppStore(
    backend: PreviewAudioControlBackend(snapshot: snapshot),
    preferencesStore: PreferencesStore(directory: directory),
    profileStore: ProfileStore(directory: directory),
    sessionStore: SessionStore(directory: directory),
    loginItemService: UpgradeLoginItemService(),
    deviceVolumePresetsStore: DeviceVolumePresetsStore(directory: directory)
  )
}

@MainActor
private func assertUpgradedState(
  _ store: AppStore,
  expected: OneFourFourFixture
) {
  let preferences = store.preferences
  let intent = preferences.appAudioIntents[expected.appID]

  #expect(preferences.pinMigrationVersion == 1)
  #expect(preferences.appAudioIntentMigrationVersion == 1)
  #expect(preferences.pinnedAppIDs == [expected.appID])
  #expect(preferences.enableKeyboardShortcuts)
  #expect(preferences.hotkeys.bindings == expected.hotkeys.bindings)
  #expect(preferences.adaptiveMixMode == .both)
  #expect(preferences.adaptiveStrategy == .lectureFocus)
  #expect(preferences.adaptiveFocusMode == .followFrontApp)
  #expect(preferences.adaptiveAppPolicies[expected.appID] == expected.policy)
  #expect(preferences.enableURLScheme)
  #expect(preferences.enableExternalControl)
  #expect(intent?.desiredVolume == expected.app.desiredVolume)
  #expect(intent?.isMuted == false)
  #expect(intent?.volumeBoost == expected.app.volumeBoost)
  #expect(intent?.equalizerSettings == expected.equalizer)
  #expect(intent?.targetDeviceUID == expected.app.targetDeviceUID)
  #expect(store.profiles == [expected.profile])
  #expect(
    store.deviceVolumePresets.getVolumeSettings(
      for: expected.appID,
      deviceID: expected.device.id
    ) == expected.preset
  )
}

private struct OneFourFourFixture {
  let appID: String
  let app: AudioApp
  let device: AudioDevice
  let snapshot: AudioSessionSnapshot
  let equalizer: EqualizerSettings
  let policy: AdaptiveAppPolicy
  let hotkeys: HotkeyBindingSet
  let profile: Profile
  let preset: AppVolumeSettings
}

private enum OneFourFourFixtureBuilder {
  static func write(to directory: URL) async throws -> OneFourFourFixture {
    let appID = "com.example.waves-1-4-4.music"
    let device = AudioDevice(
      id: "device.1-4-4",
      name: "Legacy Speakers",
      kind: .builtInOutput
    )
    var equalizer = EqualizerSettings(isEnabled: true, mode: .advanced)
    equalizer.setGain(4.5, at: 2, mode: .advanced)
    let policy = AdaptiveAppPolicy(contentType: .music, priority: .background)
    let hotkeys = HotkeyBindingSet(
      bindings: [
        HotkeyBinding(
          id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
          action: .muteApp(appID),
          keyCode: UInt16(kVK_ANSI_M),
          carbonModifiers: UInt32(cmdKey | optionKey)
        )
      ])
    let app = AudioApp(
      id: "legacy.runtime",
      logicalID: appID,
      pid: 144,
      bundleID: appID,
      displayName: "Legacy Music",
      category: .media,
      isActive: true,
      desiredVolume: 0.37,
      appliedVolume: 0,
      isMuted: true,
      isPinned: true,
      routingState: .managed,
      compatibility: .supported,
      volumeBoost: 2.5,
      muteSource: .autoConferencing,
      targetDeviceUID: "device.per-app-target"
    )
    let snapshot = AudioSessionSnapshot(
      apps: [app],
      currentDevice: device,
      recentDeviceIDs: [device.id],
      supportMatrix: SupportMatrix(
        entries: [
          SupportMatrixEntry(
            appID: appID,
            displayName: app.displayName,
            category: .media,
            state: .supported
          )
        ]),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: true,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true
      ),
      updatedAt: Date(timeIntervalSince1970: 1_722_830_400)
    )
    let profile = Profile(
      id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      name: "Legacy Focus",
      entries: [
        ProfileEntry(
          appID: appID,
          desiredVolume: 0.44,
          isMuted: false,
          volumeBoost: 1.5
        )
      ],
      createdAt: Date(timeIntervalSince1970: 1_722_830_400),
      updatedAt: Date(timeIntervalSince1970: 1_722_830_400)
    )
    let preset = AppVolumeSettings(
      desiredVolume: 0.31,
      isMuted: false,
      volumeBoost: 3
    )

    var preferences = UserPreferences()
    preferences.hasCompletedPrivacySetup = true
    preferences.hasCompletedGuidedSetup = true
    preferences.enableKeyboardShortcuts = true
    preferences.hotkeys = hotkeys
    preferences.hotkeyMigrationVersion = 1
    preferences.enablePerDeviceVolumePresets = true
    preferences.autoRestoreDevice = false
    preferences.enableURLScheme = true
    preferences.urlSchemeAutomationAcknowledged = true
    preferences.enableExternalControl = true
    preferences.adaptiveMixMode = .both
    preferences.adaptiveStrategy = .lectureFocus
    preferences.adaptiveFocusMode = .followFrontApp
    preferences.adaptiveAppPolicies[appID] = policy
    preferences.appEqualizerSettings[appID] = equalizer
    preferences.pinnedAppIDs = []
    preferences.pinMigrationVersion = 0
    preferences.appAudioIntents = [:]
    preferences.appAudioIntentMigrationVersion = 0

    var presets = DeviceVolumePresets()
    presets.saveVolumeSettings(
      for: appID,
      deviceID: device.id,
      settings: preset
    )

    let preferencesStore = PreferencesStore(directory: directory)
    let profileStore = ProfileStore(directory: directory)
    let sessionStore = SessionStore(directory: directory)
    let presetsStore = DeviceVolumePresetsStore(directory: directory)
    try await preferencesStore.save(preferences)
    try await profileStore.save([profile])
    try await sessionStore.save(snapshot)
    try await presetsStore.save(presets)
    try await preferencesStore.flush()
    try await profileStore.flush()
    try await sessionStore.flush()
    try await presetsStore.flush()

    try removePostOneFourFourMigrationMarkers(
      from: directory.appendingPathComponent("preferences.json")
    )

    return OneFourFourFixture(
      appID: appID,
      app: app,
      device: device,
      snapshot: snapshot,
      equalizer: equalizer,
      policy: policy,
      hotkeys: hotkeys,
      profile: profile,
      preset: preset
    )
  }

  private static func removePostOneFourFourMigrationMarkers(from url: URL) throws {
    let data = try Data(contentsOf: url)
    guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var payload = envelope["payload"] as? [String: Any]
    else {
      throw FixtureError.invalidPreferencesEnvelope
    }
    payload.removeValue(forKey: "pinMigrationVersion")
    payload.removeValue(forKey: "appAudioIntentMigrationVersion")
    envelope["payload"] = payload
    let legacyData = try JSONSerialization.data(
      withJSONObject: envelope,
      options: [.prettyPrinted, .sortedKeys]
    )
    try legacyData.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private enum FixtureError: Error {
    case invalidPreferencesEnvelope
  }
}

@MainActor
private final class UpgradeLoginItemService: LoginItemServicing {
  var status = LoginItemStatus(
    isEnabled: false,
    isUserIntentEnabled: false,
    statusDescription: "Disabled"
  )

  func setEnabled(_ enabled: Bool) throws {
    status.isEnabled = enabled
    status.isUserIntentEnabled = enabled
  }

  func openSystemSettingsLoginItems() {}
}
