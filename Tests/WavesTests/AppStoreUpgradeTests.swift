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

  try OneFourFourFixtureLoader.copyRawFiles(to: directory)
  let rawSnapshot = try #require(SessionStore(directory: directory).load())
  let expected = OneFourFourFixtureLoader.expected(snapshot: rawSnapshot)
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

  let relaunchSnapshot = try #require(SessionStore(directory: directory).load())
  let second = makeUpgradeStore(directory: directory, snapshot: relaunchSnapshot)
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
  #expect(expected.app.isMuted)
  #expect(expected.app.muteSource == .autoConferencing)
  #expect(intent?.isMuted == false)
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

private enum OneFourFourFixtureLoader {
  static let fileNames = [
    "preferences.json",
    "profiles.json",
    "session.json",
    "deviceVolumePresets.json",
  ]

  static func copyRawFiles(to directory: URL) throws {
    let sourceDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Waves-1.4.4", isDirectory: true)
    for fileName in fileNames {
      let source = sourceDirectory.appendingPathComponent(fileName)
      let destination = directory.appendingPathComponent(fileName)
      let sourceBytes = try Data(contentsOf: source)
      try validateHistoricalShape(sourceBytes, fileName: fileName)
      try FileManager.default.copyItem(at: source, to: destination)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destination.path
      )
      #expect(try Data(contentsOf: destination) == sourceBytes)
    }
  }

  private static func validateHistoricalShape(_ data: Data, fileName: String) throws {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FixtureError.notAnEnvelope(fileName)
    }
    #expect(envelope["schemaVersion"] as? Int == 1)
    if fileName == "preferences.json" {
      let payload = try #require(envelope["payload"] as? [String: Any])
      #expect(payload["appAudioIntentMigrationVersion"] as? Int == 0)
      #expect(payload["pinMigrationVersion"] == nil)
      let hotkeys = try #require(payload["hotkeys"] as? [String: Any])
      let bindings = try #require(hotkeys["bindings"] as? [[String: Any]])
      let action = try #require(bindings.first?["action"] as? [String: Any])
      #expect(action["muteApp"] != nil)
    }
    if fileName == "session.json" {
      let payload = try #require(envelope["payload"] as? [String: Any])
      let apps = try #require(payload["apps"] as? [[String: Any]])
      let app = try #require(apps.first)
      #expect(app["isPinned"] as? Bool == true)
      #expect(app["muteSource"] as? String == "autoConferencing")
    }
  }

  static func expected(snapshot: AudioSessionSnapshot) -> OneFourFourFixture {
    let appID = "com.example.waves-1-4-4.music"
    let device = snapshot.currentDevice!
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
    let app = snapshot.apps[0]
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

  private enum FixtureError: Error {
    case notAnEnvelope(String)
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
