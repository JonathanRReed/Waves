import Darwin
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func persistenceStoresRoundTripAtomicSnapshotsWithPrivatePermissions() async throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let preferencesStore = PreferencesStore(directory: directory)
  var preferences = UserPreferences()
  preferences.showRecentApps = false
  try await preferencesStore.save(preferences)

  let profileStore = ProfileStore(directory: directory)
  let profile = Profile(
    name: "Focus",
    entries: [ProfileEntry(appID: "com.example.editor", desiredVolume: 0.45)]
  )
  try await profileStore.save([profile])

  let sessionStore = SessionStore(directory: directory)
  var session = AudioSessionSnapshot.empty
  session.apps = [
    AudioApp(
      id: "runtime-editor",
      logicalID: "com.example.editor",
      displayName: "Editor",
      iconTIFFData: Data([1, 2, 3]),
      category: .media,
      desiredVolume: 0.45,
      routingState: .managed
    )
  ]
  session.recentDeviceIDs = ["device.test"]
  try await sessionStore.save(session)

  let presetsStore = DeviceVolumePresetsStore(directory: directory)
  var presets = DeviceVolumePresets()
  let settings = AppVolumeSettings(desiredVolume: 0.45, isMuted: true, volumeBoost: 2)
  presets.saveVolumeSettings(for: "com.example.editor", deviceID: "device.test", settings: settings)
  try await presetsStore.save(presets)

  #expect(preferencesStore.load().showRecentApps == false)
  #expect(profileStore.load(defaults: []) == [profile])
  let loadedSession = try #require(sessionStore.load())
  #expect(loadedSession.apps.first?.logicalID == "com.example.editor")
  #expect(loadedSession.apps.first?.desiredVolume == 0.45)
  #expect(loadedSession.apps.first?.iconTIFFData == nil)
  #expect(loadedSession.recentDeviceIDs == ["device.test"])
  #expect(
    presetsStore.load().getVolumeSettings(
      for: "com.example.editor",
      deviceID: "device.test"
    ) == settings)

  #expect(try persistencePermissions(at: directory) == 0o700)
  for filename in [
    "preferences.json",
    "profiles.json",
    "session.json",
    "deviceVolumePresets.json",
  ] {
    #expect(try persistencePermissions(at: directory.appendingPathComponent(filename)) == 0o600)
  }
}

@Test func profileStoreMigratesLegacyPresetsOnlyAfterDurableReplacement() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let legacyURL = directory.appendingPathComponent("presets.json")
  let profile = Profile(
    name: "Legacy",
    entries: [ProfileEntry(appID: "com.example.legacy", isMuted: true)]
  )
  try JSONEncoder().encode([profile]).write(to: legacyURL, options: .atomic)

  let store = ProfileStore(directory: directory)
  let loaded = store.load(defaults: [])

  #expect(loaded == [profile])
  #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("profiles.json").path))
  #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  #expect(FileManager.default.fileExists(atPath: legacyURL.appendingPathExtension("migrated").path))
  #expect(try persistencePermissions(at: directory.appendingPathComponent("profiles.json")) == 0o600)
}

@Test func profileStorePreservesCorruptFileAndReturnsDefaults() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let profilesURL = directory.appendingPathComponent("profiles.json")
  try Data("not-json".utf8).write(to: profilesURL)
  let fallback = [Profile(name: "Fallback", entries: [])]

  let store = ProfileStore(directory: directory)
  let loaded = store.load(defaults: fallback)

  #expect(loaded == fallback)
  #expect(!FileManager.default.fileExists(atPath: profilesURL.path))
  #expect(FileManager.default.fileExists(atPath: profilesURL.appendingPathExtension("corrupt").path))
  #expect(store.consumeDidRecoverFromCorruptFile())
  #expect(!store.consumeDidRecoverFromCorruptFile())
}

@Test func profileStoreRejectsCollectionsOverTheProfileLimitBeforeMaterializingEveryProfile() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let profilesURL = directory.appendingPathComponent("profiles.json")
  let profiles = (0...ProfilePayloadDecoder.maxProfiles).map {
    Profile(name: "Profile \($0)", entries: [])
  }
  try PersistedSchema.encode(profiles, using: JSONEncoder()).write(to: profilesURL)
  let fallback = [Profile(name: "Fallback", entries: [])]

  let store = ProfileStore(directory: directory)

  #expect(store.load(defaults: fallback) == fallback)
  #expect(!FileManager.default.fileExists(atPath: profilesURL.path))
  #expect(FileManager.default.fileExists(atPath: profilesURL.appendingPathExtension("corrupt").path))
}

@Test func sessionStoreNormalizesPersistedBackendCapabilityStateOnLoad() async throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = SessionStore(directory: directory)
  var snapshot = AudioSessionSnapshot.empty
  snapshot.backendStatus = BackendStatus(
    isAudioComponentInstalled: true,
    hasRequiredPermissions: true,
    isRouteRecoveryHealthy: true,
    lastError: String(repeating: "x", count: 2_000)
  )
  try await store.save(snapshot)

  let loaded = try #require(store.load())

  #expect(loaded.backendStatus == .unprobed)
}

@Test func everyPersistenceStoreSaveSurfacesInjectedWriteFailure() async throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let failingWrite: PersistenceDataWrite = { _, _ in throw PersistenceStoreTestError.writeFailed }

  let preferences = PreferencesStore(directory: directory, writeData: failingWrite)
  #expect(await receivesInjectedWriteFailure { try await preferences.save(UserPreferences()) })

  let profiles = ProfileStore(directory: directory, writeData: failingWrite)
  #expect(await receivesInjectedWriteFailure { try await profiles.save([]) })

  let sessions = SessionStore(directory: directory, writeData: failingWrite)
  #expect(await receivesInjectedWriteFailure { try await sessions.save(.empty) })

  let presets = DeviceVolumePresetsStore(directory: directory, writeData: failingWrite)
  #expect(await receivesInjectedWriteFailure { try await presets.save(DeviceVolumePresets()) })
}

@Test func persistenceStoreFlushSurfacesAnActiveWriteFailure() async throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let gate = FailingPersistenceDataWriteGate()
  let store = PreferencesStore(directory: directory) { data, url in
    try gate.write(data, to: url)
  }

  let save = Task { try await store.save(UserPreferences()) }
  await gate.waitUntilStarted()
  gate.release()

  #expect(await receivesInjectedWriteFailure { try await save.value })
  #expect(await receivesInjectedWriteFailure { try await store.flush() })
}

@Test func devicePresetStoreKeepsValidEntriesAcrossAdditiveFieldsAndMissingDefaults() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("deviceVolumePresets.json")
  try Data(
    """
    {
      "schemaVersion": 1,
      "payload": {
        "deviceVolumes": {
          "device.one": {
            "complete.app": {
              "desiredVolume": 0.25,
              "isMuted": true,
              "volumeBoost": 2.5,
              "futureSetting": "ignored"
            },
            "defaulted.app": {
              "isMuted": true
            }
          }
        },
        "futureDevicePolicy": true
      }
    }
    """.utf8
  ).write(to: url)

  let store = DeviceVolumePresetsStore(directory: directory)
  let loaded = store.load()

  #expect(
    loaded.getVolumeSettings(for: "complete.app", deviceID: "device.one")
      == AppVolumeSettings(desiredVolume: 0.25, isMuted: true, volumeBoost: 2.5)
  )
  #expect(
    loaded.getVolumeSettings(for: "defaulted.app", deviceID: "device.one")
      == AppVolumeSettings(desiredVolume: 1, isMuted: true, volumeBoost: 1)
  )
  #expect(!store.consumeDidRecoverFromCorruptFile())

  try Data("{\"schemaVersion\":1,\"payload\":{}}".utf8).write(to: url)
  #expect(store.load().deviceVolumes.isEmpty)
  #expect(!store.consumeDidRecoverFromCorruptFile())
}

@Test func profileStoreDefaultsAdditiveMetadataWithoutDiscardingProfile() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("profiles.json")
  try Data(
    """
    {
      "schemaVersion": 1,
      "payload": [
        {
          "id": "A5E588B4-BA92-4DA1-8020-A8A0B42B0488",
          "name": "Legacy Focus",
          "entries": [{"appID": "com.example.editor"}],
          "futureProfileField": 42
        }
      ]
    }
    """.utf8
  ).write(to: url)

  let store = ProfileStore(directory: directory)
  let loaded = store.load(defaults: [])

  #expect(loaded.count == 1)
  #expect(loaded.first?.name == "Legacy Focus")
  #expect(loaded.first?.entries.map(\.appID) == ["com.example.editor"])
  #expect(!store.consumeDidRecoverFromCorruptFile())
}

@Test func sessionStoreDefaultsMissingAdditiveRootFieldsAndNormalizesBackend() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("session.json")
  try Data(
    """
    {
      "schemaVersion": 1,
      "payload": {
        "apps": [
          {
            "id": "runtime.player",
            "logicalID": "com.example.player",
            "displayName": "Player",
            "futureAppField": true
          }
        ],
        "futureSessionField": "ignored"
      }
    }
    """.utf8
  ).write(to: url)

  let store = SessionStore(directory: directory)
  let loaded = try #require(store.load())

  #expect(loaded.apps.map(\.logicalID) == ["com.example.player"])
  #expect(loaded.currentDevice == nil)
  #expect(loaded.recentDeviceIDs.isEmpty)
  #expect(loaded.supportMatrix.entries.isEmpty)
  #expect(loaded.backendStatus == .unprobed)
  #expect(!store.consumeDidRecoverFromCorruptFile())
}

@Test func knownInvalidDevicePresetFieldPreservesOriginalAsCorrupt() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("deviceVolumePresets.json")
  let invalid = Data(
    """
    {"schemaVersion":1,"payload":{"deviceVolumes":{"device":{"app":{"desiredVolume":"loud"}}}}}
    """.utf8
  )
  try invalid.write(to: url)

  let store = DeviceVolumePresetsStore(directory: directory)

  #expect(store.load().deviceVolumes.isEmpty)
  #expect(store.consumeDidRecoverFromCorruptFile())
  #expect(!FileManager.default.fileExists(atPath: url.path))
  let corruptURL = url.appendingPathExtension("corrupt")
  #expect(try Data(contentsOf: corruptURL) == invalid)
  #expect(try persistencePermissions(at: corruptURL) == 0o600)
}

@Test func everyPrimaryStoreRejectsOversizedTruncatedPartialAndFuturePayloads() throws {
  for store in TaskSevenPersistenceStore.allCases {
    let invalidPayloads = [
      store.validOversizedPayload(),
      Data("{\"schemaVersion\":1,\"payload\":".utf8),
      Data("{\"schemaVersion\":1}".utf8),
      Data("{\"schemaVersion\":2,\"payload\":{}}".utf8),
    ]

    for payload in invalidPayloads {
      let directory = try makePersistenceStoreDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent(store.filename)
      try payload.write(to: url)

      let recovered = store.loadAndConsumeRecovery(in: directory)
      let corruptURL = url.appendingPathExtension("corrupt")

      #expect(recovered)
      #expect(!FileManager.default.fileExists(atPath: url.path))
      #expect(FileManager.default.fileExists(atPath: corruptURL.path))
      #expect(try persistencePermissions(at: corruptURL) == 0o600)
      #expect(try Data(contentsOf: corruptURL) == payload)
    }
  }
}

@Test func everyPrimaryStoreLoadsLegacyUnversionedPayloads() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  var preferences = UserPreferences()
  preferences.showRecentApps = false
  try JSONEncoder().encode(preferences)
    .write(to: directory.appendingPathComponent("preferences.json"))

  let profile = Profile(name: "Legacy", entries: [])
  try JSONEncoder().encode([profile])
    .write(to: directory.appendingPathComponent("profiles.json"))

  var session = AudioSessionSnapshot.empty
  session.recentDeviceIDs = ["legacy.device"]
  try JSONEncoder().encode(session)
    .write(to: directory.appendingPathComponent("session.json"))

  var presets = DeviceVolumePresets()
  presets.saveVolumeSettings(
    for: "legacy.app",
    deviceID: "legacy.device",
    settings: AppVolumeSettings(desiredVolume: 0.3, isMuted: true, volumeBoost: 2)
  )
  try JSONEncoder().encode(presets)
    .write(to: directory.appendingPathComponent("deviceVolumePresets.json"))

  #expect(!PreferencesStore(directory: directory).load().showRecentApps)
  #expect(ProfileStore(directory: directory).load(defaults: []) == [profile])
  #expect(SessionStore(directory: directory).load()?.recentDeviceIDs == ["legacy.device"])
  #expect(
    DeviceVolumePresetsStore(directory: directory).load().getVolumeSettings(
      for: "legacy.app",
      deviceID: "legacy.device"
    ) == AppVolumeSettings(desiredVolume: 0.3, isMuted: true, volumeBoost: 2)
  )
}

@Test func boundedRegularFileReaderRejectsOversizeSymlinkAndFIFOWithoutFollowing() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let regular = directory.appendingPathComponent("regular.json")
  try Data("12345".utf8).write(to: regular)
  #expect(try BoundedRegularFileReader.read(from: regular, maximumBytes: 5) == Data("12345".utf8))
  #expect(throws: BoundedRegularFileReaderError.fileTooLarge(actual: 5, maximum: 4)) {
    _ = try BoundedRegularFileReader.read(from: regular, maximumBytes: 4)
  }

  let symlink = directory.appendingPathComponent("linked.json")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
  #expect(throws: BoundedRegularFileReaderError.symbolicLink) {
    _ = try BoundedRegularFileReader.read(from: symlink, maximumBytes: 100)
  }

  let fifo = directory.appendingPathComponent("pipe.json")
  #expect(mkfifo(fifo.path, 0o600) == 0)
  #expect(throws: BoundedRegularFileReaderError.notRegularFile) {
    _ = try BoundedRegularFileReader.read(from: fifo, maximumBytes: 100)
  }
}

@Test func persistenceLoadDoesNotFollowOrChmodASymlinkedStateFile() throws {
  let directory = try makePersistenceStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let target = directory.appendingPathComponent("outside.json")
  var enabled = UserPreferences()
  enabled.enableExternalControl = true
  let original = try JSONEncoder().encode(enabled)
  try original.write(to: target)
  try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)

  let linkedState = directory.appendingPathComponent("preferences.json")
  try FileManager.default.createSymbolicLink(at: linkedState, withDestinationURL: target)
  let loaded = PreferencesStore(directory: directory).load()

  #expect(!loaded.enableExternalControl)
  #expect(try Data(contentsOf: target) == original)
  #expect(try persistencePermissions(at: target) == 0o644)
  var status = stat()
  #expect(lstat(linkedState.path, &status) == 0)
  #expect(status.st_mode & S_IFMT == S_IFLNK)
}

private enum TaskSevenPersistenceStore: String, CaseIterable {
  case preferences
  case profiles
  case session
  case devicePresets

  var filename: String {
    switch self {
    case .preferences: "preferences.json"
    case .profiles: "profiles.json"
    case .session: "session.json"
    case .devicePresets: "deviceVolumePresets.json"
    }
  }

  func loadAndConsumeRecovery(in directory: URL) -> Bool {
    switch self {
    case .preferences:
      let store = PreferencesStore(directory: directory)
      _ = store.load()
      return store.consumeDidRecoverFromCorruptFile() && !store.consumeDidRecoverFromCorruptFile()
    case .profiles:
      let store = ProfileStore(directory: directory)
      _ = store.load(defaults: [])
      return store.consumeDidRecoverFromCorruptFile() && !store.consumeDidRecoverFromCorruptFile()
    case .session:
      let store = SessionStore(directory: directory)
      _ = store.load()
      return store.consumeDidRecoverFromCorruptFile() && !store.consumeDidRecoverFromCorruptFile()
    case .devicePresets:
      let store = DeviceVolumePresetsStore(directory: directory)
      _ = store.load()
      return store.consumeDidRecoverFromCorruptFile() && !store.consumeDidRecoverFromCorruptFile()
    }
  }

  func validOversizedPayload() -> Data {
    let padding = String(
      repeating: "a",
      count: Int(JSONPersistenceEngine<UserPreferences>.standardMaximumFileSize)
    )
    let json: String
    switch self {
    case .preferences:
      json = "{\"futurePadding\":\"\(padding)\"}"
    case .profiles:
      json = "{\"schemaVersion\":1,\"payload\":[],\"futurePadding\":\"\(padding)\"}"
    case .session:
      json = "{\"schemaVersion\":1,\"payload\":{\"apps\":[],\"futurePadding\":\"\(padding)\"}}"
    case .devicePresets:
      json = "{\"schemaVersion\":1,\"payload\":{\"futurePadding\":\"\(padding)\"}}"
    }
    return Data(json.utf8)
  }
}

private enum PersistenceStoreTestError: Error {
  case writeFailed
}

private final class FailingPersistenceDataWriteGate: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var started = false

  func write(_ data: Data, to url: URL) throws {
    lock.lock()
    started = true
    lock.unlock()
    semaphore.wait()
    throw PersistenceStoreTestError.writeFailed
  }

  func waitUntilStarted() async {
    while !hasStarted {
      await Task.yield()
    }
  }

  func release() {
    semaphore.signal()
  }

  private var hasStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }
}

private func receivesInjectedWriteFailure(
  _ operation: () async throws -> Void
) async -> Bool {
  do {
    try await operation()
    return false
  } catch is PersistenceStoreTestError {
    return true
  } catch {
    return false
  }
}

private func makePersistenceStoreDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("WavesPersistenceTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func persistencePermissions(at url: URL) throws -> Int {
  let raw = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
  return raw?.intValue ?? -1
}
