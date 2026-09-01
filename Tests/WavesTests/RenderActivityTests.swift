import AppKit
import SwiftUI
import Testing
import WavesAudioCore

@testable import Waves

// Regression coverage for the 1.3.0 CPU incident (WAV-001). The shipped build
// gated every animated surface on *audio being present* and nothing else, so a
// single live route kept the waveform and every row meter at display rate for
// days behind other windows — roughly two saturated cores, and a macOS CPU
// resource report. These tests pin the two halves of the fix: the render clock
// stops when nothing is on screen, and the backend level poll stops with it.

// MARK: - Render cadence

@Test func pausedCadenceMountsNoClock() {
  #expect(RenderCadence.paused.isAnimating == false)
  #expect(RenderCadence.background.isAnimating)
  #expect(RenderCadence.foreground.isAnimating)
}

@Test func backgroundCadenceThrottlesAndForegroundCapsAtSixtyHertz() {
  // A visible-but-inactive window still has to animate, just more cheaply.
  #expect(RenderCadence.background.minimumInterval == 1.0 / 30.0)
  // Frontmost is capped at 60 Hz rather than following a 120 Hz display: the
  // waveform draws several blurred layers per frame and nothing that small
  // benefits from the extra frames.
  #expect(RenderCadence.foreground.minimumInterval == 1.0 / 60.0)
}

@Test func cadenceOrdersFromCheapestToMostExpensive() {
  #expect(RenderCadence.paused < RenderCadence.background)
  #expect(RenderCadence.background < RenderCadence.foreground)
}

@MainActor
@Test func monitorPausesWhenNothingIsVisibleAndThrottlesWhenNotFrontmost() {
  let monitor = RenderActivityMonitor()

  monitor.setStateForTesting(isVisible: true, isActive: true)
  #expect(monitor.cadence == .foreground)

  // The incident's exact shape: audio live, window on screen, app in the
  // background. Still animates — but at the reduced rate.
  monitor.setStateForTesting(isVisible: true, isActive: false)
  #expect(monitor.cadence == .background)

  // Occluded, minimized, closed, or on another Space: no clock at all, and
  // being frontmost cannot resurrect it.
  monitor.setStateForTesting(isVisible: false, isActive: false)
  #expect(monitor.cadence == .paused)
  monitor.setStateForTesting(isVisible: false, isActive: true)
  #expect(monitor.cadence == .paused)
}

@MainActor
@Test func monitorReportsOnlyRealVisibilityTransitions() {
  let monitor = RenderActivityMonitor()
  // Establish a known baseline before observing: a fresh monitor reads the real
  // NSApplication's occlusion state, which is not visible under a test host.
  monitor.setStateForTesting(isVisible: true, isActive: true)

  var transitions: [Bool] = []
  monitor.onVisibilityChange = { transitions.append($0) }

  // Activation changes alone must not churn the store's poll — only visibility.
  monitor.setStateForTesting(isVisible: true, isActive: false)
  monitor.setStateForTesting(isVisible: false, isActive: false)
  monitor.setStateForTesting(isVisible: false, isActive: true)
  monitor.setStateForTesting(isVisible: true, isActive: true)

  #expect(transitions == [false, true])
}

// MARK: - Level poll gating

@MainActor
@Test func levelPollDropsToItsHeartbeatWhileNoSurfaceIsVisible() async {
  let fixture = await makeRenderActivityFixture()
  fixture.store.beginLiveLevels()

  #expect(
    await waitUntil { await fixture.backend.levelCallCount() > 3 },
    "a visible surface must poll levels at the fast cadence"
  )

  // Every window goes off screen. The view is still mounted — `onDisappear`
  // does not fire for a merely occluded window — so only the occlusion gate
  // sees this.
  fixture.store.setUISurfaceVisible(false)
  await boundedObservationWindow()
  await fixture.backend.resetLevelCallCount()
  let elapsed = await boundedObservationWindow()

  // Bounded on BOTH sides. An upper bound alone would be satisfied by the poll
  // stopping altogether — which is exactly the regression that made the
  // menu-bar glyph claim "idle" during playback — so the lower bound is the
  // half that actually protects the fix.
  let hiddenCalls = await fixture.backend.levelCallCount()
  let allowed = Int(elapsed.rounded(.up)) + 1
  #expect(
    hiddenCalls > 0,
    "the heartbeat must keep running so the menu-bar glyph stays honest"
  )
  #expect(
    hiddenCalls <= allowed,
    "hidden surfaces polled \(hiddenCalls) times in \(elapsed)s (allowed \(allowed))"
  )
}

@MainActor
@Test func hidingTheWindowDoesNotMakeTheMenuBarGlyphClaimIdle() async {
  // Regression: clearing levels when the last window went off screen made
  // `isLive` fall back to the snapshot's levels, which are structurally zero for
  // a managed app — so the icon and its VoiceOver label reported "idle" for the
  // whole time a managed route was playing behind a hidden window.
  let fixture = await makeRenderActivityFixture(routingState: .managed)
  fixture.store.beginLiveLevels()
  await fixture.backend.setLevels(["com.example.render": AudioLevels(peak: 0.8, rms: 0.6)])

  #expect(
    await waitUntil { fixture.store.hasLiveAudio },
    "precondition: a playing managed app reads as live while visible"
  )

  fixture.store.setUISurfaceVisible(false)
  #expect(
    await waitUntil { await fixture.backend.levelCallCount() > 0 },
    "the hidden heartbeat must complete another level pass"
  )

  #expect(fixture.store.hasLiveAudio, "a hidden window must not make playback invisible")
  #expect(fixture.store.liveLevels.isEmpty == false, "levels must survive going off screen")
}

@MainActor
@Test func releasingTheLastSurfaceKeepsOnlyTheHeartbeat() async {
  let fixture = await makeRenderActivityFixture()
  fixture.store.beginLiveLevels()
  #expect(await waitUntil { await fixture.backend.levelCallCount() > 3 })

  fixture.store.endLiveLevels()
  await boundedObservationWindow()
  await fixture.backend.resetLevelCallCount()
  let elapsed = await boundedObservationWindow()

  let calls = await fixture.backend.levelCallCount()
  let allowed = Int(elapsed.rounded(.up)) + 1
  // Both bounds again: releasing the last meter surface drops to the heartbeat,
  // it does not stop the poll.
  #expect(calls > 0, "the heartbeat must survive the last surface going away")
  #expect(calls <= allowed, "expected the heartbeat, got \(calls) calls in \(elapsed)s")
}

// MARK: - Adaptive Mix idle cost (WAV-005)

@MainActor
@Test func adaptiveMixIdlesWhenNothingIsRoutedThroughWaves() async {
  // No managed route: Adaptive Mix has nothing to balance or duck, so the
  // 100 ms coordinator pass is guaranteed to be a no-op. Through 1.3.0 it still
  // woke and hit the backend ten times a second for as long as the feature was
  // enabled — for days, on a machine with nothing routed.
  let fixture = await makeRenderActivityFixture(routingState: .live)
  fixture.store.setAdaptiveMixMode(.both)
  await boundedObservationWindow()
  await fixture.backend.resetAdaptiveAnalysisCount()
  let elapsed = await boundedObservationWindow()

  let idleCalls = await fixture.backend.adaptiveAnalysisCount()
  // Bound scales with real elapsed time so a loaded machine cannot fail this:
  // at the 1 s idle heartbeat the count tracks seconds, where the old 100 ms
  // cadence would be ten times that.
  let allowed = Int(elapsed.rounded(.up)) + 1
  #expect(
    idleCalls <= allowed,
    "idle Adaptive Mix asked the backend \(idleCalls) times in \(elapsed)s (allowed \(allowed))"
  )
}

@MainActor
@Test func adaptiveMixRunsAtFullCadenceWithAManagedRoute() async {
  let sleepRecorder = AdaptiveMixSleepRecorder()
  let fixture = await makeRenderActivityFixture(
    routingState: .managed,
    adaptiveMixSleep: { duration in
      try await sleepRecorder.sleep(for: duration)
    }
  )
  fixture.store.setAdaptiveMixMode(.both)

  #expect(
    await waitUntil { await sleepRecorder.contains(.milliseconds(100)) },
    "a managed route must request the 100 ms active interval"
  )
  #expect(await fixture.backend.adaptiveAnalysisCount() > 0)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func unchangedAdaptiveGainsAreNotRewrittenEveryPass() async {
  // The test backend reports no analysis levels, so the policy engine produces
  // the same (empty) gain map every pass. Rewriting it ten times a second wakes
  // the backend actor and every managed controller to change nothing.
  let fixture = await makeRenderActivityFixture(routingState: .managed)
  fixture.store.setAdaptiveMixMode(.both)
  await fixture.backend.resetGainWriteCount()
  await fixture.backend.resetAdaptiveAnalysisCount()

  // Wait for enough passes that a per-pass write would be unmistakable.
  #expect(
    await waitUntil { await fixture.backend.adaptiveAnalysisCount() > 10 },
    "precondition: the coordinator is running at full cadence"
  )

  let writes = await fixture.backend.gainWriteCount()
  let passes = await fixture.backend.adaptiveAnalysisCount()
  #expect(writes < passes, "unchanged gains were rewritten on every pass (\(writes)/\(passes))")
}

/// Polls until `condition` holds, up to `timeout`.
///
/// These tests observe background loops, and a fixed sleep is not a safe way to
/// wait for one: the full suite runs dozens of tests concurrently, and a window
/// that is comfortably long in isolation can stretch past a minute on a loaded
/// machine. Positive assertions ("this must happen") therefore wait for the
/// condition rather than for the clock.
@MainActor
private func waitUntil(
  timeout: Duration = .seconds(30),
  _ condition: @MainActor () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    await Task.yield()
  }
  return await condition()
}

/// A quiet window for negative assertions ("this must NOT happen"), returning
/// how long it actually lasted so the caller can scale its bound to real
/// elapsed time instead of assuming the sleep was honoured promptly.
@discardableResult
private func boundedObservationWindow(_ duration: Duration = .milliseconds(900)) async -> Double {
  let start = ContinuousClock.now
  let deadline = start.advanced(by: duration)
  while ContinuousClock.now < deadline {
    await Task.yield()
  }
  let elapsed = ContinuousClock.now - start
  return Double(elapsed.components.seconds)
    + Double(elapsed.components.attoseconds) / 1e18
}

// MARK: - Fixture

private struct RenderActivityFixture {
  let store: AppStore
  let backend: RenderActivityBackend
}

/// Shared with the control-surface tests: a running store with one managed app.
@MainActor
func makeControlStoreFixture(
  routingState: RoutingState = .managed,
  startupState: AppStartupState = .running,
  includeApp: Bool = true,
  iconTIFFData: Data? = nil
) async -> AppStore {
  await makeRenderActivityFixture(
    routingState: routingState,
    startupState: startupState,
    includeApp: includeApp,
    iconTIFFData: iconTIFFData
  ).store
}

@MainActor
private func makeRenderActivityFixture(
  routingState: RoutingState = .managed,
  startupState: AppStartupState = .running,
  includeApp: Bool = true,
  iconTIFFData: Data? = nil,
  adaptiveMixSleep: @escaping @Sendable (Duration) async throws -> Void = {
    duration in try await Task.sleep(for: duration)
  }
) async -> RenderActivityFixture {
  let app = AudioApp(
    id: "runtime.render.app",
    logicalID: "com.example.render",
    displayName: "Render App",
    iconTIFFData: iconTIFFData,
    category: .media,
    desiredVolume: 0.8,
    appliedVolume: 0.8,
    routingState: routingState
  )
  let device = AudioDevice(
    id: "device.render",
    name: "Render Device",
    kind: .builtInOutput,
    isCurrent: true,
    isManagedRouteAvailable: true
  )
  let snapshot = AudioSessionSnapshot(
    apps: includeApp ? [app] : [],
    currentDevice: device,
    recentDeviceIDs: [device.id],
    supportMatrix: SupportMatrix(
      entries: includeApp
        ? [
          SupportMatrixEntry(
            appID: app.logicalID,
            displayName: app.displayName,
            category: app.category,
            state: app.compatibility
          )
        ]
        : []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.urlSchemeAutomationAcknowledged = true

  let backend = RenderActivityBackend(snapshot: snapshot)
  let store = AppStore(
    backend: backend,
    preferencesStore: RenderActivityPreferencesStore(value: preferences),
    profileStore: RenderActivityProfilesStore(),
    sessionStore: RenderActivitySessionStore(value: snapshot),
    loginItemService: RenderActivityLoginItemService(),
    deviceVolumePresetsStore: RenderActivityPresetsStore(),
    initialStartupState: startupState,
    adaptiveMixSleep: adaptiveMixSleep
  )
  await store.drainPersistenceTasks()
  return RenderActivityFixture(store: store, backend: backend)
}

private actor AdaptiveMixSleepRecorder {
  private var requestedDurations: [Duration] = []

  func sleep(for duration: Duration) async throws {
    requestedDurations.append(duration)
    try await Task.sleep(for: .seconds(60))
  }

  func contains(_ duration: Duration) -> Bool {
    requestedDurations.contains(duration)
  }
}

private actor RenderActivityBackend: AudioControlBackend {
  nonisolated let deviceChangeEvents: AsyncStream<Void> = AsyncStream { $0.finish() }

  private let snapshot: AudioSessionSnapshot
  private var levelCalls = 0
  private var adaptiveAnalysisCalls = 0
  private var gainWrites = 0

  init(snapshot: AudioSessionSnapshot) {
    self.snapshot = snapshot
  }

  private var levels: [String: AudioLevels] = [:]

  func levelCallCount() -> Int { levelCalls }
  func resetLevelCallCount() { levelCalls = 0 }
  func setLevels(_ levels: [String: AudioLevels]) { self.levels = levels }
  func adaptiveAnalysisCount() -> Int { adaptiveAnalysisCalls }
  func resetAdaptiveAnalysisCount() { adaptiveAnalysisCalls = 0 }
  func gainWriteCount() -> Int { gainWrites }
  func resetGainWriteCount() { gainWrites = 0 }

  func audioLevels() async -> [String: AudioLevels] {
    levelCalls += 1
    return levels
  }

  func start() async throws {}
  func stop() async {}
  func currentSnapshot() async -> AudioSessionSnapshot { snapshot }
  func refresh() async throws -> AudioSessionSnapshot { snapshot }
  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {}
  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {}
  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {}
  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {}
  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] {
    adaptiveAnalysisCalls += 1
    return [:]
  }
  func setAdaptiveGains(_ gainsDB: [String: Float]) async {
    gainWrites += 1
  }
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {}
  func pinApp(_ isPinned: Bool, appID: String) async throws {}
  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot { snapshot }
  func saveCurrentProfile(named name: String) async throws -> Profile {
    Profile(name: name, entries: [])
  }
  func recoverRoutes() async throws -> AudioSessionSnapshot { snapshot }
  func autoRestoreDevice() async throws -> AudioSessionSnapshot { snapshot }
  func diagnosticsReport() async -> DiagnosticsReport {
    DiagnosticsReport(summary: "Render activity test", checks: [])
  }
  func availableOutputDevices() async -> [AudioDevice] {
    snapshot.currentDevice.map { [$0] } ?? []
  }
  func setDefaultOutputDevice(uid: String) async throws {}
  func setOutputDevice(uid: String?, forAppID appID: String) async throws {}
  func releaseControllers(
    forRuntimeIdentity runtimeIdentity: AppRuntimeIdentity,
    clearMuteState: Bool
  ) async {}
  func audioCapabilityMode() async -> AudioCapabilityMode { .full }
  func captureAuthorizationResult() async -> CaptureAuthorizationResult { .authorized }
  func shutdownWithResult() async -> BackendShutdownResult {
    BackendShutdownResult(completion: .clean)
  }
}

private struct RenderActivityPreferencesStore: PreferencesPersisting {
  let value: UserPreferences
  func load() -> UserPreferences { value }
  func save(_ preferences: UserPreferences) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private struct RenderActivityProfilesStore: ProfilesPersisting {
  func load(defaults: [Profile]) -> [Profile] { defaults }
  func save(_ profiles: [Profile]) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private struct RenderActivitySessionStore: SessionPersisting {
  let value: AudioSessionSnapshot
  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private struct RenderActivityPresetsStore: DeviceVolumePresetsPersisting {
  func load() -> DeviceVolumePresets { DeviceVolumePresets() }
  func save(_ presets: DeviceVolumePresets) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class RenderActivityLoginItemService: LoginItemServicing {
  var status: LoginItemStatus {
    LoginItemStatus(isEnabled: false, isUserIntentEnabled: false, statusDescription: "Disabled")
  }
  func setEnabled(_ enabled: Bool) throws {}
  func openSystemSettingsLoginItems() {}
}

// MARK: - Warm start (1.4 D2)

@MainActor
@Test func aReturningUserSeesTheMixerImmediatelyNotASplash() async {
  // The restored session is loaded synchronously in AppStore.init, so a
  // returning user's rows exist before the first frame. Showing a full-window
  // "Starting Waves" splash meant spinning for data already in memory, then
  // reflowing the whole window when the real surface replaced it.
  let fixture = await makeRenderActivityFixture(startupState: .idle)

  #expect(fixture.store.showsWarmStartMixer, "a restored session must render the mixer at once")
  #expect(fixture.store.isWarmingUp, "...while still saying it is coming up")
}

@MainActor
@Test func warmStartNeverHidesASurfaceThatExplainsItself() async {
  // Deliberately narrow: an empty session, incomplete setup, or a failed start
  // must still get the surface that says what is going on. An empty mixer would
  // read as "Waves found nothing", which is worse than a splash.
  let empty = await makeRenderActivityFixture(startupState: .idle, includeApp: false)
  #expect(empty.store.showsWarmStartMixer == false)

  let failed = await makeRenderActivityFixture(startupState: .failed("boom"))
  #expect(failed.store.showsWarmStartMixer == false)

  let awaiting = await makeRenderActivityFixture(startupState: .awaitingPrivacy)
  #expect(awaiting.store.showsWarmStartMixer == false)
}

@MainActor
@Test func warmingUpEndsOnceTheBackendIsRunning() async {
  let fixture = await makeRenderActivityFixture(startupState: .running)
  #expect(fixture.store.showsWarmStartMixer)
  #expect(fixture.store.isWarmingUp == false, "a running store is not warming up")
}
