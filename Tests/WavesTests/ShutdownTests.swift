import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func appStoreShutdownRejectsMutationsSettlesWorkAndPreservesOneResult() async {
  let fixture = await makeShutdownFixture(initialStartupState: .running)
  fixture.preferencesStore.suspendNextSave()
  fixture.store.preferences.showRecentApps.toggle()
  fixture.store.persistPreferences()
  await fixture.preferencesStore.waitUntilSaveIsSuspended()

  fixture.store.setMuted(true, for: fixture.app)
  await fixture.backend.waitUntilIntentIsSuspended()

  let firstCaller = Task { @MainActor in await fixture.store.shutdown() }
  await waitUntil { fixture.store.startupState == .shuttingDown }

  let intentCountAtShutdown = await fixture.backend.callCount("backend.intent.begin")
  fixture.store.setMuted(false, for: fixture.app)
  fixture.store.refresh()
  fixture.store.applyProfile(
    Profile(
      name: "Rejected",
      entries: [
        ProfileEntry(appID: fixture.app.logicalID, desiredVolume: 0.2)
      ]))
  fixture.store.refreshOutputDevices()
  fixture.store.recoverRoutes()
  let rejected = await fixture.store.applyAppIntent(
    forAppID: fixture.app.logicalID,
    overrides: AppIntentOverrides(isMuted: false),
    reason: .userEdit
  )
  #expect(rejected.outcome == .failed)
  #expect(await fixture.backend.callCount("backend.intent.begin") == intentCountAtShutdown)
  #expect(await fixture.backend.callCount("backend.refresh") == 0)
  #expect(await fixture.backend.callCount("backend.profile") == 0)
  #expect(await fixture.backend.callCount("backend.shutdown") == 0)

  let secondCaller = Task { @MainActor in await fixture.store.shutdown() }
  fixture.backend.resumeIntent()
  await Task.yield()
  #expect(await fixture.backend.callCount("backend.shutdown") == 0)

  fixture.preferencesStore.resumeSave()
  let firstResult = await firstCaller.value
  let secondResult = await secondCaller.value
  let repeatedResult = await fixture.store.shutdown()

  #expect(firstResult == secondResult)
  #expect(secondResult == repeatedResult)
  #expect(fixture.store.shutdownResult == firstResult)
  #expect(firstResult.completion == .clean)
  #expect(firstResult.backendResult?.completion == .clean)
  #expect(await fixture.backend.callCount("backend.shutdown") == 1)

  let events = fixture.recorder.events()
  let backendShutdownIndex = try? #require(events.firstIndex(of: "backend.shutdown"))
  let finalFlushIndex = try? #require(events.lastIndex(where: { $0.hasSuffix(".flush") }))
  #expect(backendShutdownIndex != nil)
  #expect(finalFlushIndex != nil)
  if let backendShutdownIndex, let finalFlushIndex {
    #expect(finalFlushIndex < backendShutdownIndex)
  }
}

@MainActor
@Test func appStoreShutdownSkipsBackendWhenPrivacyGatedAndIsIdempotent() async {
  let fixture = await makeShutdownFixture(initialStartupState: .awaitingPrivacy)
  #expect(fixture.store.preferences.hasCompletedPrivacySetup == false)

  async let first = fixture.store.shutdown()
  async let second = fixture.store.shutdown()
  let (firstResult, secondResult) = await (first, second)

  #expect(firstResult == secondResult)
  #expect(firstResult.backendResult == nil)
  #expect(firstResult.completion == .clean)
  #expect(await fixture.backend.callCount("backend.adaptive.reset") == 0)
  #expect(await fixture.backend.callCount("backend.shutdown") == 0)
  #expect(fixture.preferencesStore.value.hasCompletedPrivacySetup == false)
  #expect(!fixture.recorder.events().contains("session.save"))
}

@MainActor
@Test func appStoreShutdownReportsPersistenceFailureAndStillCleansBackend() async {
  let fixture = await makeShutdownFixture(initialStartupState: .running)
  fixture.preferencesStore.failSaves = true

  let result = await fixture.store.shutdown()

  #expect(result.completion == .degraded)
  #expect(result.persistenceDegradations.contains { $0.contains("settings") })
  #expect(result.backendResult?.completion == .clean)
  #expect(await fixture.backend.callCount("backend.shutdown") == 1)
}

@MainActor
@Test func terminationTimeoutDecisionReturnsWithoutWaitingForSlowCleanup() async {
  let outcome = await AppTerminationTimeoutDecision.awaitShutdown(
    timeout: .milliseconds(5)
  ) {
    try? await Task.sleep(for: .milliseconds(50))
    return AppShutdownResult()
  }

  #expect(outcome == .timedOut)
  try? await Task.sleep(for: .milliseconds(60))
}

@MainActor
@Test func terminationCoordinatorRepliesExactlyOnceForEveryOutcome() async {
  await verifyTerminationCoordinator(
    expected: .clean(AppShutdownResult()),
    timeout: .seconds(5)
  ) {
    AppShutdownResult()
  }

  let degraded = AppShutdownResult(persistenceDegradations: ["settings: injected failure"])
  await verifyTerminationCoordinator(
    expected: .degraded(degraded),
    timeout: .seconds(5)
  ) {
    degraded
  }

  await verifyTerminationCoordinator(
    expected: .timedOut,
    timeout: .milliseconds(5)
  ) {
    try? await Task.sleep(for: .milliseconds(50))
    return AppShutdownResult()
  }
  try? await Task.sleep(for: .milliseconds(60))
}

@Test func cleanupAggregationFiltersSuccessAndPreservesFailureOrder() {
  let degradations = checkedCleanupDegradations(from: [
    CleanupStatusObservation(stage: .listenerRemoval, nativeStatus: 0, detail: "success"),
    CleanupStatusObservation(
      appID: "app.one", stage: .ioProcStop, nativeStatus: -50, detail: "stop"),
    CleanupStatusObservation(
      appID: "app.one", stage: .ioProcDestroy, nativeStatus: 0, detail: "destroy"),
    CleanupStatusObservation(
      appID: "app.two", stage: .processTapDestroy, nativeStatus: -60, detail: "tap"),
  ])

  #expect(degradations.map(\.stage) == [.ioProcStop, .processTapDestroy])
  #expect(degradations.map(\.nativeStatus) == [-50, -60])
  #expect(BackendShutdownResult(checkedDegradations: []).completion == .clean)
  #expect(BackendShutdownResult(checkedDegradations: degradations).completion == .degraded)
}

@Test func controllerCleanupSeamAndBackendShutdownDoNotDuplicateDegradations() async {
  let cleanupOnce = IdempotentCleanupResult()
  var cleanupRuns = 0
  let expected = [
    CleanupDegradation(
      appID: "app.test",
      stage: .ioProcDestroy,
      nativeStatus: -1,
      detail: "Injected"
    )
  ]

  let firstControllerResult = cleanupOnce.run {
    cleanupRuns += 1
    return expected
  }
  let secondControllerResult = cleanupOnce.run {
    cleanupRuns += 1
    return []
  }
  #expect(firstControllerResult == expected)
  #expect(secondControllerResult == expected)
  #expect(cleanupRuns == 1)

  let counter = ShutdownCounter()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: shutdownSnapshot(),
    intentRouteApplyOverride: { _, _ in },
    shutdownCleanupOverride: {
      counter.increment()
      return expected
    }
  )

  async let firstBackendResult = backend.shutdownWithResult()
  async let secondBackendResult = backend.shutdownWithResult()
  let (firstResult, secondResult) = await (firstBackendResult, secondBackendResult)

  #expect(firstResult == secondResult)
  #expect(firstResult.degradations == expected)
  #expect(firstResult.completion == .degraded)
  #expect(counter.value == 1)
}

@MainActor
private func verifyTerminationCoordinator(
  expected: AppTerminationOutcome,
  timeout: Duration,
  shutdown: @escaping @MainActor @Sendable () async -> AppShutdownResult
) async {
  let coordinator = AppTerminationCoordinator(timeout: timeout)
  let recorder = TerminationReplyRecorder()

  let firstDecision = coordinator.requestTermination(
    shutdown: shutdown,
    report: { recorder.outcomes.append($0) },
    reply: { recorder.replies.append($0) }
  )
  let repeatedDecision = coordinator.requestTermination(
    shutdown: {
      recorder.unexpectedShutdownStarts += 1
      return AppShutdownResult()
    },
    report: { recorder.outcomes.append($0) },
    reply: { recorder.replies.append($0) }
  )

  #expect(firstDecision == .terminateLater)
  #expect(repeatedDecision == .terminateLater)
  await waitUntil { coordinator.completedOutcome != nil }
  #expect(coordinator.completedOutcome == expected)
  #expect(recorder.outcomes == [expected])
  #expect(recorder.replies == [true])
  #expect(recorder.unexpectedShutdownStarts == 0)

  let completedDecision = coordinator.requestTermination(
    shutdown: {
      recorder.unexpectedShutdownStarts += 1
      return AppShutdownResult()
    },
    report: { recorder.outcomes.append($0) },
    reply: { recorder.replies.append($0) }
  )
  #expect(completedDecision == .terminateNow)
  #expect(recorder.replies == [true])
  #expect(recorder.unexpectedShutdownStarts == 0)
}

@MainActor
private func waitUntil(
  attempts: Int = 2_000,
  _ condition: @MainActor () -> Bool
) async {
  for _ in 0..<attempts {
    if condition() { return }
    await Task.yield()
  }
}

@MainActor
private func makeShutdownFixture(
  initialStartupState: AppStartupState
) async -> ShutdownFixture {
  let recorder = ShutdownRecorder()
  let app = AudioApp(
    id: "runtime.shutdown.app",
    logicalID: "com.example.shutdown",
    displayName: "Shutdown App",
    category: .media,
    desiredVolume: 0.8,
    appliedVolume: 0.8,
    routingState: .managed
  )
  let snapshot = shutdownSnapshot(app: app)
  let backend = ShutdownBackend(snapshot: snapshot, recorder: recorder)
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = initialStartupState == .running
  preferences.urlSchemeAutomationAcknowledged = true
  let preferencesStore = ShutdownPreferencesStore(value: preferences, recorder: recorder)
  let profileStore = ShutdownProfilesStore(recorder: recorder)
  let sessionStore = ShutdownSessionStore(value: snapshot, recorder: recorder)
  let presetsStore = ShutdownDevicePresetsStore(recorder: recorder)
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: profileStore,
    sessionStore: sessionStore,
    loginItemService: ShutdownLoginItemService(),
    deviceVolumePresetsStore: presetsStore,
    initialStartupState: initialStartupState
  )
  await store.drainPersistenceTasks()
  recorder.clear()
  return ShutdownFixture(
    store: store,
    backend: backend,
    preferencesStore: preferencesStore,
    recorder: recorder,
    app: app
  )
}

private struct ShutdownFixture {
  let store: AppStore
  let backend: ShutdownBackend
  let preferencesStore: ShutdownPreferencesStore
  let recorder: ShutdownRecorder
  let app: AudioApp
}

private func shutdownSnapshot(app: AudioApp? = nil) -> AudioSessionSnapshot {
  let device = AudioDevice(
    id: "device.shutdown",
    name: "Shutdown Device",
    kind: .builtInOutput,
    isCurrent: true,
    isManagedRouteAvailable: true
  )
  let apps = app.map { [$0] } ?? []
  return AudioSessionSnapshot(
    apps: apps,
    currentDevice: device,
    recentDeviceIDs: [device.id],
    supportMatrix: SupportMatrix(
      entries: apps.map {
        SupportMatrixEntry(
          appID: $0.logicalID,
          displayName: $0.displayName,
          category: $0.category,
          state: $0.compatibility
        )
      }),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

private final class ShutdownRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  func append(_ event: String) {
    lock.withLock { recorded.append(event) }
  }

  func events() -> [String] {
    lock.withLock { recorded }
  }

  func clear() {
    lock.withLock { recorded.removeAll() }
  }
}

private actor ShutdownBackend: AudioControlBackend {
  nonisolated let deviceChangeEvents: AsyncStream<Void> = AsyncStream { _ in }

  private var snapshot: AudioSessionSnapshot
  private let recorder: ShutdownRecorder
  private var intentSuspended = false
  private var intentResume: CheckedContinuation<Void, Never>?
  private var intentWaiters: [CheckedContinuation<Void, Never>] = []
  private var preservedShutdownResult: BackendShutdownResult?

  init(snapshot: AudioSessionSnapshot, recorder: ShutdownRecorder) {
    self.snapshot = snapshot
    self.recorder = recorder
  }

  func callCount(_ event: String) -> Int {
    recorder.events().count { $0 == event }
  }

  func waitUntilIntentIsSuspended() async {
    if intentSuspended { return }
    await withCheckedContinuation { continuation in
      intentWaiters.append(continuation)
    }
  }

  nonisolated func resumeIntent() {
    Task { await self.resumeSuspendedIntent() }
  }

  private func resumeSuspendedIntent() {
    intentResume?.resume()
    intentResume = nil
  }

  func start() async throws { recorder.append("backend.start") }
  func stop() async { _ = await shutdownWithResult() }
  func currentSnapshot() async -> AudioSessionSnapshot {
    recorder.append("backend.snapshot")
    return snapshot
  }
  func refresh() async throws -> AudioSessionSnapshot {
    recorder.append("backend.refresh")
    return snapshot
  }
  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {}
  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {}
  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {}
  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {}
  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] { [:] }
  func setAdaptiveGains(_ gainsDB: [String: Float]) async {
    if gainsDB.isEmpty { recorder.append("backend.adaptive.reset") }
  }
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {}
  func pinApp(_ isPinned: Bool, appID: String) async throws {}
  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot { snapshot }
  func saveCurrentProfile(named name: String) async throws -> Profile {
    Profile(name: name, entries: [])
  }
  func recoverRoutes() async throws -> AudioSessionSnapshot {
    recorder.append("backend.recover")
    return snapshot
  }
  func autoRestoreDevice() async throws -> AudioSessionSnapshot { snapshot }
  func diagnosticsReport() async -> DiagnosticsReport {
    DiagnosticsReport(summary: "Shutdown test", checks: [])
  }
  func availableOutputDevices() async -> [AudioDevice] {
    recorder.append("backend.devices")
    return snapshot.currentDevice.map { [$0] } ?? []
  }
  func setDefaultOutputDevice(uid: String) async throws {
    recorder.append("backend.defaultDevice")
  }
  func setOutputDevice(uid: String?, forAppID appID: String) async throws {}
  func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool) async {}
  func audioLevels() async -> [String: AudioLevels] { [:] }

  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    recorder.append("backend.intent.begin")
    intentSuspended = true
    let waiters = intentWaiters
    intentWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      intentResume = continuation
    }
    intentSuspended = false

    if let index = snapshot.apps.firstIndex(where: { $0.logicalID == intent.appID }) {
      snapshot.apps[index].isMuted = intent.isMuted
      snapshot.apps[index].desiredVolume = intent.desiredVolume
      snapshot.apps[index].volumeBoost = intent.volumeBoost
      snapshot.apps[index].appliedVolume = intent.isMuted ? 0 : intent.desiredVolume
    }
    recorder.append("backend.intent.complete")
    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: .applied,
      resultingApp: snapshot.apps.first { $0.logicalID == intent.appID },
      backendStatus: snapshot.backendStatus
    )
  }

  func applyProfileWithResults(_ profile: Profile, generation: UInt64) async -> ProfileApplyResult {
    recorder.append("backend.profile")
    return ProfileApplyResult(rows: [], backendStatus: snapshot.backendStatus)
  }

  func shutdownWithResult() async -> BackendShutdownResult {
    if let preservedShutdownResult { return preservedShutdownResult }
    recorder.append("backend.shutdown")
    let result = BackendShutdownResult(completion: .clean)
    preservedShutdownResult = result
    return result
  }
}

private final class ShutdownPreferencesStore: PreferencesPersisting, @unchecked Sendable {
  private let lock = NSLock()
  private let recorder: ShutdownRecorder
  private var storedValue: UserPreferences
  private var shouldSuspendNextSave = false
  private var saveIsSuspended = false
  private var saveResume: CheckedContinuation<Void, Never>?
  private var saveWaiters: [CheckedContinuation<Void, Never>] = []
  var failSaves = false

  init(value: UserPreferences, recorder: ShutdownRecorder) {
    self.storedValue = value
    self.recorder = recorder
  }

  var value: UserPreferences { lock.withLock { storedValue } }

  func suspendNextSave() {
    lock.withLock { shouldSuspendNextSave = true }
  }

  func waitUntilSaveIsSuspended() async {
    if lock.withLock({ saveIsSuspended }) { return }
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock { () -> Bool in
        if saveIsSuspended { return true }
        saveWaiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func resumeSave() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { saveResume = nil }
      return saveResume
    }
    continuation?.resume()
  }

  func load() -> UserPreferences { value }

  func save(_ preferences: UserPreferences) async throws {
    recorder.append("preferences.save.begin")
    let shouldSuspend = lock.withLock { () -> Bool in
      defer { shouldSuspendNextSave = false }
      return shouldSuspendNextSave
    }
    if shouldSuspend {
      await withCheckedContinuation { continuation in
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
          saveIsSuspended = true
          saveResume = continuation
          defer { saveWaiters.removeAll() }
          return saveWaiters
        }
        for waiter in waiters { waiter.resume() }
      }
      lock.withLock { saveIsSuspended = false }
    }
    if failSaves { throw ShutdownTestError.persistence }
    lock.withLock { storedValue = preferences }
    recorder.append("preferences.save.end")
  }

  func flush() async throws { recorder.append("preferences.flush") }
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class ShutdownProfilesStore: ProfilesPersisting, @unchecked Sendable {
  private let recorder: ShutdownRecorder
  init(recorder: ShutdownRecorder) { self.recorder = recorder }
  func load(defaults: [Profile]) -> [Profile] { defaults }
  func save(_ profiles: [Profile]) async throws { recorder.append("profiles.save") }
  func flush() async throws { recorder.append("profiles.flush") }
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class ShutdownSessionStore: SessionPersisting, @unchecked Sendable {
  private let recorder: ShutdownRecorder
  private var value: AudioSessionSnapshot?
  init(value: AudioSessionSnapshot?, recorder: ShutdownRecorder) {
    self.value = value
    self.recorder = recorder
  }
  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws {
    value = snapshot
    recorder.append("session.save")
  }
  func flush() async throws { recorder.append("session.flush") }
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class ShutdownDevicePresetsStore: DeviceVolumePresetsPersisting, @unchecked Sendable {
  private let recorder: ShutdownRecorder
  init(recorder: ShutdownRecorder) { self.recorder = recorder }
  func load() -> DeviceVolumePresets { DeviceVolumePresets() }
  func save(_ presets: DeviceVolumePresets) async throws { recorder.append("presets.save") }
  func flush() async throws { recorder.append("presets.flush") }
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class ShutdownLoginItemService: LoginItemServicing {
  var status = LoginItemStatus(
    isEnabled: false,
    isUserIntentEnabled: false,
    statusDescription: "Disabled"
  )
  func setEnabled(_ enabled: Bool) throws {}
  func openSystemSettingsLoginItems() {}
}

@MainActor
private final class TerminationReplyRecorder {
  var outcomes: [AppTerminationOutcome] = []
  var replies: [Bool] = []
  var unexpectedShutdownStarts = 0
}

private final class ShutdownCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.withLock { count += 1 } }
  var value: Int { lock.withLock { count } }
}

private enum ShutdownTestError: Error {
  case persistence
}
