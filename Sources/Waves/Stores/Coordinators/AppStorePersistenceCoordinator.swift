import Foundation
import WavesAudioCore

struct AppStorePersistenceFailure: Equatable, Sendable {
  let store: PersistenceStoreIdentifier
  let message: String
  let errorDescription: String
  let shouldWarn: Bool
}

struct AppStorePersistenceLifecycleSnapshot: Equatable, Sendable {
  let runnerCount: Int
  let pendingSnapshotCount: Int
  let isAcceptingWork: Bool

  static let idle = AppStorePersistenceLifecycleSnapshot(
    runnerCount: 0,
    pendingSnapshotCount: 0,
    isAcceptingWork: false
  )
}

/// Owns all asynchronous persistence runners and their durable rollback state.
/// AppStore remains responsible for presenting typed failure outputs.
@MainActor
final class AppStorePersistenceCoordinator {
  typealias FailureHandler = @MainActor (AppStorePersistenceFailure) -> Void

  private let preferencesStore: any PreferencesPersisting
  private let profileStore: any ProfilesPersisting
  private let sessionStore: any SessionPersisting
  private let devicePresetsStore: any DeviceVolumePresetsPersisting
  private let now: @MainActor @Sendable () -> Date
  private let warningDebounceInterval: TimeInterval

  private var pendingPreferences: UserPreferences?
  private var pendingProfiles: [Profile]?
  private var pendingSession: AudioSessionSnapshot?
  private var pendingDevicePresets: DeviceVolumePresets?
  private var preferencesTask: Task<Void, Never>?
  private var profilesTask: Task<Void, Never>?
  private var sessionTask: Task<Void, Never>?
  private var devicePresetsTask: Task<Void, Never>?
  private var isShuttingDown = false
  private var isFinalizing = false
  private var lastWarningDate: Date?

  private(set) var failureHistory: [String] = []
  private(set) var durablySavedPreferences: UserPreferences
  private(set) var durablySavedDevicePresets: DeviceVolumePresets
  var onFailure: FailureHandler?

  init(
    preferencesStore: any PreferencesPersisting,
    profileStore: any ProfilesPersisting,
    sessionStore: any SessionPersisting,
    devicePresetsStore: any DeviceVolumePresetsPersisting,
    initialPreferences: UserPreferences,
    initialDevicePresets: DeviceVolumePresets,
    warningDebounceInterval: TimeInterval = 5,
    now: @escaping @MainActor @Sendable () -> Date = Date.init
  ) {
    self.preferencesStore = preferencesStore
    self.profileStore = profileStore
    self.sessionStore = sessionStore
    self.devicePresetsStore = devicePresetsStore
    self.durablySavedPreferences = initialPreferences
    self.durablySavedDevicePresets = initialDevicePresets
    self.warningDebounceInterval = warningDebounceInterval
    self.now = now
  }

  var trackedTaskCount: Int {
    [preferencesTask, profilesTask, sessionTask, devicePresetsTask]
      .compactMap { $0 }.count
  }

  var pendingSnapshotCount: Int {
    [
      pendingPreferences.map { _ in true },
      pendingProfiles.map { _ in true },
      pendingSession.map { _ in true },
      pendingDevicePresets.map { _ in true },
    ].compactMap { $0 }.count
  }

  var lifecycleSnapshot: AppStorePersistenceLifecycleSnapshot {
    AppStorePersistenceLifecycleSnapshot(
      runnerCount: trackedTaskCount,
      pendingSnapshotCount: pendingSnapshotCount,
      isAcceptingWork: !isShuttingDown || isFinalizing
    )
  }

  func enqueuePreferences(_ snapshot: UserPreferences) {
    guard acceptsWork else { return }
    pendingPreferences = snapshot
    guard preferencesTask == nil else { return }
    preferencesTask = Task { @MainActor [weak self] in
      await self?.runPreferences()
    }
  }

  func enqueueProfiles(_ snapshot: [Profile]) {
    guard acceptsWork else { return }
    pendingProfiles = snapshot
    guard profilesTask == nil else { return }
    profilesTask = Task { @MainActor [weak self] in
      await self?.runProfiles()
    }
  }

  func enqueueSession(_ snapshot: AudioSessionSnapshot) {
    guard acceptsWork else { return }
    pendingSession = snapshot
    guard sessionTask == nil else { return }
    sessionTask = Task { @MainActor [weak self] in
      await self?.runSession()
    }
  }

  func enqueueDevicePresets(_ snapshot: DeviceVolumePresets) {
    guard acceptsWork else { return }
    pendingDevicePresets = snapshot
    guard devicePresetsTask == nil else { return }
    devicePresetsTask = Task { @MainActor [weak self] in
      await self?.runDevicePresets()
    }
  }

  func drain() async {
    while true {
      let tasks = [preferencesTask, profilesTask, sessionTask, devicePresetsTask]
        .compactMap { $0 }
      guard !tasks.isEmpty else { return }
      for task in tasks { await task.value }
    }
  }

  func savePreferencesDurably(_ snapshot: UserPreferences) async throws {
    await drain()
    try await preferencesStore.save(snapshot)
    durablySavedPreferences = snapshot
  }

  func saveProfilesDurably(_ snapshot: [Profile]) async throws {
    await drain()
    try await profileStore.save(snapshot)
  }

  func saveSessionDurably(_ snapshot: AudioSessionSnapshot) async throws {
    await drain()
    try await sessionStore.save(snapshot)
  }

  func saveDevicePresetsDurably(_ snapshot: DeviceVolumePresets) async throws {
    await drain()
    try await devicePresetsStore.save(snapshot)
    durablySavedDevicePresets = snapshot
  }

  func flush() async {
    await drain()
    let flushes: [(PersistenceStoreIdentifier, () async throws -> Void)] = [
      (.preferences, preferencesStore.flush),
      (.profiles, profileStore.flush),
      (.session, sessionStore.flush),
      (.deviceVolumePresets, devicePresetsStore.flush),
    ]
    for (store, flush) in flushes {
      do {
        try await flush()
      } catch {
        recordFailure(store: store, error: error, showWarning: false)
      }
    }
  }

  @discardableResult
  func beginShutdown() -> [Task<Void, Never>] {
    isShuttingDown = true
    let tasks = [preferencesTask, profilesTask, sessionTask, devicePresetsTask]
      .compactMap { $0 }
    for task in tasks { task.cancel() }
    preferencesTask = nil
    profilesTask = nil
    sessionTask = nil
    devicePresetsTask = nil
    return tasks
  }

  func beginFinalization() {
    isFinalizing = true
  }

  func endFinalization() {
    isFinalizing = false
  }

  func finishShutdown() {
    isShuttingDown = true
    isFinalizing = false
    pendingPreferences = nil
    pendingProfiles = nil
    pendingSession = nil
    pendingDevicePresets = nil
    onFailure = nil
  }

  func recordFailure(
    store: PersistenceStoreIdentifier,
    error: Error,
    showWarning: Bool = true
  ) {
    let message = "\(store.displayName): \(error.localizedDescription)"
    failureHistory.append(message)
    let currentTime = now()
    let shouldWarn =
      showWarning
      && (lastWarningDate.map {
        currentTime.timeIntervalSince($0) >= warningDebounceInterval
      } ?? true)
    if shouldWarn { lastWarningDate = currentTime }
    onFailure?(
      AppStorePersistenceFailure(
        store: store,
        message: message,
        errorDescription: error.localizedDescription,
        shouldWarn: shouldWarn
      ))
  }

  private var acceptsWork: Bool { !isShuttingDown || isFinalizing }

  private func runPreferences() async {
    defer { preferencesTask = nil }
    while let snapshot = pendingPreferences {
      pendingPreferences = nil
      do {
        try await preferencesStore.save(snapshot)
        durablySavedPreferences = snapshot
      } catch {
        recordFailure(store: .preferences, error: error)
      }
    }
  }

  private func runProfiles() async {
    defer { profilesTask = nil }
    while let snapshot = pendingProfiles {
      pendingProfiles = nil
      do {
        try await profileStore.save(snapshot)
      } catch {
        recordFailure(store: .profiles, error: error)
      }
    }
  }

  private func runSession() async {
    defer { sessionTask = nil }
    while let snapshot = pendingSession {
      pendingSession = nil
      do {
        try await sessionStore.save(snapshot)
      } catch {
        recordFailure(store: .session, error: error)
      }
    }
  }

  private func runDevicePresets() async {
    defer { devicePresetsTask = nil }
    while let snapshot = pendingDevicePresets {
      pendingDevicePresets = nil
      do {
        try await devicePresetsStore.save(snapshot)
        durablySavedDevicePresets = snapshot
      } catch {
        recordFailure(store: .deviceVolumePresets, error: error)
      }
    }
  }
}
