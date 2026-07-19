import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func persistedAppAudioIntentSanitizesAndRoundTrips() throws {
  let longID = String(repeating: "a", count: 300)
  let intent = PersistedAppAudioIntent(
    appID: longID,
    desiredVolume: .infinity,
    isMuted: true,
    volumeBoost: .nan,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: String(repeating: "d", count: 300)
  )

  #expect(intent.appID.count == 256)
  #expect(intent.desiredVolume == 1)
  #expect(intent.volumeBoost == 1)
  #expect(intent.targetDeviceUID?.count == 256)

  let data = try JSONEncoder().encode(intent)
  let decoded = try JSONDecoder().decode(PersistedAppAudioIntent.self, from: data)
  #expect(decoded == intent)

  let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(json["generation"] == nil)
  #expect(json["appliedVolume"] == nil)
  #expect(json["routingState"] == nil)
  #expect(json["muteSource"] == nil)
}

@Test func audioFormatPlanRejectsUnknownAndInvalidGeometry() {
  #expect(AudioFormatPlan(
    sampleFormat: .float32,
    sampleRate: 48_000,
    channelCount: 2,
    isInterleaved: true,
    bytesPerSample: 4,
    bytesPerFrame: 8
  ) != nil)
  #expect(AudioFormatPlan(
    sampleFormat: .unknown,
    sampleRate: 48_000,
    channelCount: 2,
    isInterleaved: true,
    bytesPerSample: 4,
    bytesPerFrame: 8
  ) == nil)
  #expect(AudioFormatPlan(
    sampleFormat: .int16,
    sampleRate: 48_000,
    channelCount: 2,
    isInterleaved: true,
    bytesPerSample: 2,
    bytesPerFrame: 2
  ) == nil)
  #expect(AudioFormatPlan(
    sampleFormat: .float32,
    sampleRate: 48_000,
    channelCount: 2,
    isInterleaved: true,
    bytesPerSample: 2,
    bytesPerFrame: 4
  ) == nil)
  #expect(AudioFormatPlan(
    sampleFormat: .float32,
    sampleRate: 48_000,
    channelCount: .max,
    isInterleaved: true,
    bytesPerSample: 4,
    bytesPerFrame: .max
  ) == nil)
}

@Test func legacyIntentAdapterFailsSafeWithoutMutating() async {
  let backend = LegacyRecordingBackend()
  let app = await backend.firstApp()
  let intent = AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.42,
    isMuted: true,
    volumeBoost: 2.5,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: "device.external",
    generation: 7,
    reason: .startupRestore
  )

  let result = await backend.applyAppIntent(intent)

  #expect(await backend.recordedCalls().isEmpty)
  #expect(result.appID == app.logicalID)
  #expect(result.generation == 7)
  #expect(result.outcome == .unsupported)
  #expect(result.resultingApp == app)
  #expect(result.detail?.contains("generation-aware") == true)
}

@Test func legacyIntentAdapterPrefersLogicalIdentityOverRuntimeCollision() async {
  let collision = AudioApp(
    id: "shared-key",
    logicalID: "other-logical-id",
    displayName: "Collision",
    category: .unknown
  )
  let intended = AudioApp(
    id: "runtime-id",
    logicalID: "shared-key",
    displayName: "Intended",
    category: .media
  )
  let snapshot = AudioSessionSnapshot(
    apps: [collision, intended],
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
  let backend = LegacyRecordingBackend(snapshot: snapshot)
  let intent = AppRouteIntent(
    appID: "shared-key",
    desiredVolume: 1,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: 8,
    reason: .userEdit
  )

  let result = await backend.applyAppIntent(intent)

  #expect(result.resultingApp?.logicalID == "shared-key")
  #expect(result.resultingApp?.displayName == "Intended")
}

@Test func legacyProfileAdapterOnlyAcceptsMembershipRows() async {
  let backend = LegacyRecordingBackend()
  let app = await backend.firstApp()
  let profile = Profile(
    name: "Ordered",
    entries: [
      ProfileEntry(appID: app.logicalID),
      ProfileEntry(appID: app.logicalID, desiredVolume: 0.5),
      ProfileEntry(appID: "missing", isMuted: true),
      ProfileEntry(appID: app.logicalID, volumeBoost: 2),
    ]
  )

  let result = await backend.applyProfileWithResults(profile, generation: 19)

  #expect(result.rows.map(\.entryIndex) == [0, 1, 2, 3])
  #expect(result.rows.map(\.appID) == [app.logicalID, app.logicalID, "missing", app.logicalID])
  #expect(result.rows.map(\.outcome) == [.membershipOnly, .unsupported, .unsupported, .unsupported])
  #expect(result.rows.allSatisfy { $0.generation == 19 })
  #expect(result.rows.allSatisfy { $0.resultingApp == nil })
  #expect(await backend.recordedCalls().isEmpty)
}

@Test func legacyCapabilityAndShutdownAdaptersAreConservative() async {
  let backend = LegacyRecordingBackend()
  #expect(await backend.audioCapabilityMode() == .full)
  #expect(await backend.captureAuthorizationResult() == .authorized)

  let result = await backend.shutdownWithResult()
  #expect(result.completion == .unverified)
  #expect(await backend.recordedCalls().contains("stop"))
}

@Test func workspaceBackendExposesItsAuthorizationState() async {
  let backend = WorkspaceAudioControlBackend()

  #expect(await backend.captureAuthorizationResult() == .undetermined)
  #expect(await backend.audioCapabilityMode() == .limited)
}

@Test func protocolRequirementDispatchesToBackendOverride() async {
  let concrete = OverrideDispatchBackend()
  let backend: any AudioControlBackend = concrete
  let app = await concrete.firstApp()
  let intent = AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.5,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: 23,
    reason: .automation
  )

  let result = await backend.applyAppIntent(intent)

  #expect(result.outcome == .noChange)
  #expect(await concrete.overrideCallCount() == 1)
  #expect(await concrete.legacyCalls().isEmpty)
}

@MainActor
@Test func diagnosticsMetadataUsesInjectedValuesAndAppStoreAcceptsInjectedDependencies() async {
  let metadata = DiagnosticsMetadata(
    bundleInfo: [
      "CFBundleShortVersionString": " 1.1.0 \n",
      "CFBundleVersion": " 42 ",
    ],
    operatingSystemVersion: " macOS Test 99.1 \n"
  )
  #expect(metadata.shortVersion == "1.1.0")
  #expect(metadata.buildVersion == "42")
  #expect(metadata.operatingSystemVersion == "macOS Test 99.1")

  let developmentMetadata = DiagnosticsMetadata(
    bundleInfo: [:],
    operatingSystemVersion: ""
  )
  #expect(developmentMetadata.shortVersion == "development")
  #expect(developmentMetadata.buildVersion == "development")
  #expect(developmentMetadata.operatingSystemVersion == "unknown")

  let previousBootstrapStore = AppDelegate.bootstrapStore
  defer { AppDelegate.bootstrapStore = previousBootstrapStore }

  let preferences = MemoryPreferencesStore()
  let profiles = MemoryProfilesStore()
  let sessions = MemorySessionStore()
  let presets = MemoryDevicePresetsStore()
  let login = MemoryLoginItemService()
  var createdStore: AppStore?
  let composition = WavesComposition {
    let store = AppStore(
      backend: PreviewAudioControlBackend(),
      preferencesStore: preferences,
      profileStore: profiles,
      sessionStore: sessions,
      loginItemService: login,
      deviceVolumePresetsStore: presets
    )
    createdStore = store
    return store
  }

  _ = WavesApp(composition: composition)
  await createdStore?.drainPersistenceTasks()

  #expect(createdStore?.preferences.showRecentApps == true)
  #expect(preferences.saveCount == 1)
  #expect(AppDelegate.bootstrapStore === createdStore)
}

@MainActor
@Test func appStoreMigratesLegacyAudioIntentsOnlyAtVersionZero() async {
  var session = AudioSessionSnapshot.empty
  session.apps = [
    AudioApp(
      id: "com.example.session",
      displayName: "Session App",
      category: .media,
      desiredVolume: 0.4
    )
  ]
  let legacyEqualizer = EqualizerSettings(isEnabled: true)

  let preferences = MemoryPreferencesStore()
  preferences.value.urlSchemeAutomationAcknowledged = true
  preferences.value.appAudioIntentMigrationVersion = 0
  preferences.value.appEqualizerSettings["com.example.eq"] = legacyEqualizer
  let sessions = MemorySessionStore()
  sessions.value = session

  let firstStore = AppStore(
    backend: PreviewAudioControlBackend(),
    preferencesStore: preferences,
    profileStore: MemoryProfilesStore(),
    sessionStore: sessions,
    loginItemService: MemoryLoginItemService(),
    deviceVolumePresetsStore: MemoryDevicePresetsStore()
  )
  await firstStore.drainPersistenceTasks()

  #expect(preferences.value.appAudioIntentMigrationVersion == 1)
  #expect(preferences.value.appAudioIntents["com.example.session"]?.desiredVolume == 0.4)
  #expect(preferences.value.appAudioIntents["com.example.eq"]?.equalizerSettings == legacyEqualizer)
  #expect(preferences.saveCount == 1)

  var alreadyMigrated = preferences.value
  alreadyMigrated.appAudioIntents = [:]
  let secondPreferences = MemoryPreferencesStore()
  secondPreferences.value = alreadyMigrated
  let secondSessions = MemorySessionStore()
  secondSessions.value = session

  let secondStore = AppStore(
    backend: PreviewAudioControlBackend(),
    preferencesStore: secondPreferences,
    profileStore: MemoryProfilesStore(),
    sessionStore: secondSessions,
    loginItemService: MemoryLoginItemService(),
    deviceVolumePresetsStore: MemoryDevicePresetsStore()
  )
  await secondStore.drainPersistenceTasks()

  #expect(secondPreferences.value.appAudioIntentMigrationVersion == 1)
  #expect(secondPreferences.value.appAudioIntents.isEmpty)
  #expect(secondPreferences.saveCount == 0)
}

@MainActor
@Test func appStoreTracksPersistenceFailureAndShowsDebouncedWarning() async {
  let preferences = MemoryPreferencesStore()
  preferences.saveError = AppStorePersistenceTestError.writeFailed
  let store = AppStore(
    backend: PreviewAudioControlBackend(),
    preferencesStore: preferences,
    profileStore: MemoryProfilesStore(),
    sessionStore: MemorySessionStore(),
    loginItemService: MemoryLoginItemService(),
    deviceVolumePresetsStore: MemoryDevicePresetsStore()
  )

  await store.drainPersistenceTasks()

  #expect(store.persistenceFailureCount == 1)
  #expect(store.lastPersistenceError?.contains("settings") == true)
  #expect(store.trackedPersistenceTaskCount == 0)
  #expect(store.toasts.contains { $0.title == "Changes may not be saved" })
}

private enum AppStorePersistenceTestError: Error {
  case writeFailed
}

private actor LegacyRecordingBackend: AudioControlBackend {
  nonisolated let deviceChangeEvents: AsyncStream<Void> = AsyncStream { $0.finish() }

  private var snapshot: AudioSessionSnapshot
  private var calls: [String] = []

  init(snapshot: AudioSessionSnapshot? = nil) {
    var snapshot = snapshot ?? AudioSessionSnapshot.preview
    snapshot.backendStatus = BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
    self.snapshot = snapshot
  }

  func firstApp() -> AudioApp { snapshot.apps[0] }
  func recordedCalls() -> [String] { calls }

  func start() async throws { calls.append("start") }
  func stop() async { calls.append("stop") }
  func currentSnapshot() async -> AudioSessionSnapshot { snapshot }
  func refresh() async throws -> AudioSessionSnapshot { snapshot }

  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    calls.append("volume")
    guard let index = appIndex(appID) else { throw BackendError.appNotFound(appID) }
    snapshot.apps[index].desiredVolume = volume
    snapshot.apps[index].routingState = .managed
  }

  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    calls.append("mute")
    guard let index = appIndex(appID) else { throw BackendError.appNotFound(appID) }
    snapshot.apps[index].isMuted = isMuted
  }

  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    calls.append("boost")
    guard let index = appIndex(appID) else { throw BackendError.appNotFound(appID) }
    snapshot.apps[index].volumeBoost = boost
  }

  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {
    calls.append("equalizer")
    guard appIndex(appID) != nil else { throw BackendError.appNotFound(appID) }
  }

  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] { [:] }
  func setAdaptiveGains(_ gainsDB: [String: Float]) async {}
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {}
  func pinApp(_ isPinned: Bool, appID: String) async throws {}

  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot {
    calls.append("profile")
    return snapshot
  }

  func saveCurrentProfile(named name: String) async throws -> Profile {
    Profile(name: name, entries: [])
  }

  func recoverRoutes() async throws -> AudioSessionSnapshot { snapshot }
  func autoRestoreDevice() async throws -> AudioSessionSnapshot { snapshot }
  func diagnosticsReport() async -> DiagnosticsReport { DiagnosticsReport(summary: "Test", checks: []) }
  func availableOutputDevices() async -> [AudioDevice] { [] }
  func setDefaultOutputDevice(uid: String) async throws {}

  func setOutputDevice(uid: String?, forAppID appID: String) async throws {
    calls.append("output")
    guard let index = appIndex(appID) else { throw BackendError.appNotFound(appID) }
    snapshot.apps[index].targetDeviceUID = uid
  }

  func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool) async {}
  func audioLevels() async -> [String: AudioLevels] { [:] }

  private func appIndex(_ appID: String) -> Int? {
    snapshot.apps.firstIndex { $0.id == appID || $0.logicalID == appID }
  }

}

private actor OverrideDispatchBackend: AudioControlBackend {
  nonisolated let deviceChangeEvents: AsyncStream<Void> = AsyncStream { $0.finish() }

  private let legacy = LegacyRecordingBackend()
  private var overrideCalls = 0

  func firstApp() async -> AudioApp { await legacy.firstApp() }
  func overrideCallCount() -> Int { overrideCalls }
  func legacyCalls() async -> [String] { await legacy.recordedCalls() }

  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    overrideCalls += 1
    let snapshot = await legacy.currentSnapshot()
    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: .noChange,
      resultingApp: snapshot.apps.first,
      backendStatus: snapshot.backendStatus
    )
  }

  func start() async throws { try await legacy.start() }
  func stop() async { await legacy.stop() }
  func currentSnapshot() async -> AudioSessionSnapshot { await legacy.currentSnapshot() }
  func refresh() async throws -> AudioSessionSnapshot { try await legacy.refresh() }
  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws { try await legacy.setDesiredVolume(volume, forAppID: appID) }
  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws { try await legacy.setMuted(isMuted, forAppID: appID) }
  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws { try await legacy.setVolumeBoost(boost, forAppID: appID) }
  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws { try await legacy.setEqualizer(settings, forAppID: appID) }
  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] { await legacy.adaptiveAnalysis() }
  func setAdaptiveGains(_ gainsDB: [String: Float]) async { await legacy.setAdaptiveGains(gainsDB) }
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws { try await legacy.setVolumeControlMode(mode, forDeviceID: deviceID) }
  func pinApp(_ isPinned: Bool, appID: String) async throws { try await legacy.pinApp(isPinned, appID: appID) }
  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot { try await legacy.applyProfile(profile) }
  func saveCurrentProfile(named name: String) async throws -> Profile { try await legacy.saveCurrentProfile(named: name) }
  func recoverRoutes() async throws -> AudioSessionSnapshot { try await legacy.recoverRoutes() }
  func autoRestoreDevice() async throws -> AudioSessionSnapshot { try await legacy.autoRestoreDevice() }
  func diagnosticsReport() async -> DiagnosticsReport { await legacy.diagnosticsReport() }
  func availableOutputDevices() async -> [AudioDevice] { await legacy.availableOutputDevices() }
  func setDefaultOutputDevice(uid: String) async throws { try await legacy.setDefaultOutputDevice(uid: uid) }
  func setOutputDevice(uid: String?, forAppID appID: String) async throws { try await legacy.setOutputDevice(uid: uid, forAppID: appID) }
  func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool) async { await legacy.releaseControllers(forBundleID: bundleID, pid: pid, clearMuteState: clearMuteState) }
  func audioLevels() async -> [String: AudioLevels] { await legacy.audioLevels() }
}

private final class MemoryPreferencesStore: PreferencesPersisting, @unchecked Sendable {
  var value = UserPreferences()
  var saveCount = 0
  var saveError: Error?
  func load() -> UserPreferences { value }
  func save(_ preferences: UserPreferences) async throws {
    if let saveError { throw saveError }
    value = preferences
    saveCount += 1
  }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class MemoryProfilesStore: ProfilesPersisting, @unchecked Sendable {
  var value = Profile.defaults
  func load(defaults: [Profile]) -> [Profile] { value }
  func save(_ profiles: [Profile]) async throws { value = profiles }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class MemorySessionStore: SessionPersisting, @unchecked Sendable {
  var value: AudioSessionSnapshot?
  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws { value = snapshot }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class MemoryDevicePresetsStore: DeviceVolumePresetsPersisting, @unchecked Sendable {
  var value = DeviceVolumePresets()
  func load() -> DeviceVolumePresets { value }
  func save(_ presets: DeviceVolumePresets) async throws { value = presets }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class MemoryLoginItemService: LoginItemServicing {
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
