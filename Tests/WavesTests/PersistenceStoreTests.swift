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
  #expect(presetsStore.load().getVolumeSettings(
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
