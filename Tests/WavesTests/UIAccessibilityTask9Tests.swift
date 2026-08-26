import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func settingsPanesConstructFromFocusedFilesAndUseStableOrder() {
  #expect(
    SettingsPane.allCases
      == [.general, .mixer, .profiles, .control, .setup, .diagnostics, .help]
  )
  _ = GeneralSettingsView()
  _ = MixerSettingsView()
  _ = ProfileSettingsView()
  _ = ControlSettingsView(draft: ControlSettingsDraft())
  _ = DiagnosticsSettingsView(onOpenSetup: {})
}

@MainActor
@Test func sharedPreferenceBindingPersistsExactlyOncePerAcceptedMutation() {
  var value = false
  var persistenceCount = 0
  let binding = PreferenceBinding.make(
    get: { value },
    set: { value = $0 },
    persist: { persistenceCount += 1 }
  )

  binding.wrappedValue = true
  #expect(value)
  #expect(persistenceCount == 1)
}

@Test func readinessStatusVocabularyIncludesReadyAttentionAndUnavailable() {
  #expect(ReadinessStatus.allCases == [.ready, .attention, .unavailable])
  #expect(Set(ReadinessStatus.allCases.map(\.statusWord)).count == 3)
  #expect(Set(ReadinessStatus.allCases.map(\.symbolName)).count == 3)
}

@MainActor
@Test func profileSaveReturnsEveryValidationResultWithoutMutatingOnFailure() async throws {
  let store = await makeControlStoreFixture()
  let appID = try #require(store.session.apps.first?.logicalID)

  #expect(store.saveProfile(named: "   ", appIDs: [appID], captureLevels: false) == .blankName)
  #expect(
    store.saveProfile(named: String(repeating: "a", count: 101), appIDs: [appID], captureLevels: false)
      == .nameTooLong(maximum: 100)
  )
  #expect(store.saveProfile(named: "Empty", appIDs: [], captureLevels: false) == .noEligibleApps)

  let focus = try #require(
    store.saveProfile(named: "Task 9 Focus", appIDs: [appID], captureLevels: false).savedProfileID)
  let work = try #require(
    store.saveProfile(named: "Task 9 Work", appIDs: [appID], captureLevels: false).savedProfileID)
  #expect(
    store.saveProfile(named: " task 9 focus ", appIDs: [appID], captureLevels: false)
      == .duplicateName("Task 9 Focus")
  )
  #expect(
    store.saveProfile(id: work, named: "TASK 9 FOCUS", appIDs: [appID], captureLevels: false)
      == .duplicateName("Task 9 Focus")
  )

  store.preferences.excludedAppIDs = [appID]
  #expect(
    store.saveProfile(id: focus, named: "Task 9 Focus", appIDs: [appID], captureLevels: false)
      == .noEligibleApps)
  #expect(store.profiles.contains { $0.name == "Task 9 Focus" })
  #expect(store.profiles.contains { $0.name == "Task 9 Work" })
}

@MainActor
@Test func profileSaveReportsShutdownInsteadOfSilentlyReturning() async {
  let store = await makeControlStoreFixture(startupState: .shuttingDown)
  #expect(
    store.saveProfile(named: "Focus", appIDs: ["com.example.render"], captureLevels: false)
      == .unavailableDuringShutdown)
}

@Test func everyProfileValidationFailureHasActionablePresentationCopy() {
  let failures: [ProfileSaveResult] = [
    .unavailableDuringShutdown,
    .blankName,
    .nameTooLong(maximum: 100),
    .duplicateName("Focus"),
    .noEligibleApps,
  ]
  for result in failures {
    #expect(result.message?.isEmpty == false)
  }
  #expect(ProfileSaveResult.saved(UUID()).message == nil)
}

@Test func routeHealthPresentationDistinguishesEveryManagedAudioCondition() {
  let ordinary = task9App(state: .monitorOnly)
  let publicClaim = task9App(state: .monitorOnly, context: .verifiedRouterOwnership)
  let fallback = task9App(state: .monitorOnly, context: .unattributableRouterFallback)
  let recovering = task9App(state: .managed, context: .geometryRecoveryInProgress)
  let exhausted = task9App(state: .error, context: .geometryRecoveryExhausted)

  #expect(RouteHealthPresentation(app: ordinary).title == "Monitoring only")
  #expect(RouteHealthPresentation(app: publicClaim).title == "Wave Link route")
  #expect(RouteHealthPresentation(app: fallback).title == "Conservative handoff")
  #expect(RouteHealthPresentation(app: recovering).title == "Recovering route")
  #expect(RouteHealthPresentation(app: exhausted).title == "Recovery failed")
  #expect(RouteHealthPresentation(app: publicClaim).title != "Ready")
  #expect(RouteHealthPresentation(app: fallback).title != "Ready")

  for app in [ordinary, publicClaim, fallback, recovering, exhausted] {
    let presentation = RouteHealthPresentation(app: app)
    #expect(!presentation.symbolName.isEmpty)
    #expect(!presentation.accessibilityLabel.isEmpty)
    #expect(!presentation.accessibilityValue.isEmpty)
    #expect(!presentation.help.isEmpty)
  }
}

@Test func headerRouteHealthBadgeMakesEveryRecoveryActionExplicitlyGlobal() {
  let exhausted = RouteHealthPresentation(
    app: task9App(state: .error, context: .geometryRecoveryExhausted)
  )
  let contextualError = RouteHealthBadgeSemantics(contextual: exhausted)
  #expect(contextualError.interaction == .recoverAllRoutes)
  #expect(contextualError.visibleLabel == "Recover All Routes")
  #expect(contextualError.accessibilityLabel == "Recover all managed Waves routes")
  #expect(contextualError.accessibilityValue == "Recovery failed. Geometry retry limit reached")
  #expect(contextualError.help == "Recovery failed. Rebuild all managed Waves routes.")
  #expect(
    contextualError.hint
      == "Reattaches every active per-app audio route managed by Waves."
  )

  let genericUnhealthy = RouteHealthBadgeSemantics(
    genericTitle: "Needs attention",
    isHealthy: false
  )
  #expect(genericUnhealthy.interaction == .recoverAllRoutes)
  #expect(genericUnhealthy.visibleLabel == "Recover All Routes")
  #expect(genericUnhealthy.accessibilityLabel == "Recover all managed Waves routes")
  #expect(genericUnhealthy.accessibilityValue == "Needs attention")
  #expect(genericUnhealthy.help == "Needs attention. Rebuild all managed Waves routes.")
  #expect(
    genericUnhealthy.hint
      == "Reattaches every active per-app audio route managed by Waves."
  )

  let waveLink = RouteHealthPresentation(
    app: task9App(state: .monitorOnly, context: .verifiedRouterOwnership)
  )
  let contextualStatus = RouteHealthBadgeSemantics(contextual: waveLink)
  #expect(contextualStatus.interaction == .statusOnly)
  #expect(contextualStatus.visibleLabel == "Wave Link route")
  #expect(contextualStatus.accessibilityLabel == "Route status: Wave Link route")
  #expect(contextualStatus.accessibilityValue == "Claimed by verified Wave Link")
  #expect(contextualStatus.help == waveLink.help)
  #expect(contextualStatus.hint == waveLink.help)

  let genericHealthy = RouteHealthBadgeSemantics(genericTitle: "Ready", isHealthy: true)
  #expect(genericHealthy.interaction == .statusOnly)
  #expect(genericHealthy.visibleLabel == "Ready")
  #expect(genericHealthy.accessibilityLabel == "Routing status: Ready")
  #expect(genericHealthy.accessibilityValue == nil)
  #expect(genericHealthy.help == "Routing status: Ready")
  #expect(genericHealthy.hint == nil)
}

@Test func routeContextCapabilityPolicyPreventsMisleadingControl() {
  let ordinary = MixerRouteControlPolicy(app: task9App(state: .monitorOnly))
  #expect(ordinary.allowsAudioControl)
  #expect(ordinary.offersRecovery == false)
  #expect(ordinary.sliderHelp.contains("starts managing"))

  for context in [
    RouteHealthContext.verifiedRouterOwnership,
    .unattributableRouterFallback,
    .routerMixedOutput,
  ] {
    let policy = MixerRouteControlPolicy(
      app: task9App(state: .monitorOnly, context: context)
    )
    #expect(policy.allowsAudioControl == false)
    #expect(policy.offersRecovery == false)
    #expect(policy.controlHint.contains("Wave Link"))
    #expect(policy.sliderHelp.contains("starts managing") == false)
  }

  let bridged = MixerRouteControlPolicy(
    app: task9App(state: .monitorOnly, context: .waveLinkBridge)
  )
  #expect(bridged.allowsAudioControl)
  #expect(bridged.allowsDSPControl == false)
  #expect(bridged.offersRecovery == false)
  #expect(bridged.controlHint.contains("Wave Link"))

  let bridgedApp = task9App(state: .monitorOnly, context: .waveLinkBridge)
  #expect(
    MixerRowAccessibility.semantics(
      for: .volume,
      app: bridgedApp,
      isExcluded: false,
      isRecovering: false
    ).isEnabled
  )
  #expect(
    MixerRowAccessibility.semantics(
      for: .mute,
      app: bridgedApp,
      isExcluded: false,
      isRecovering: false
    ).isEnabled
  )
  #expect(
    MixerRowAccessibility.semantics(
      for: .boost,
      app: bridgedApp,
      isExcluded: false,
      isRecovering: false
    ).isEnabled == false
  )

  let recovering = MixerRouteControlPolicy(
    app: task9App(state: .managed, context: .geometryRecoveryInProgress)
  )
  #expect(recovering.allowsAudioControl == false)
  #expect(recovering.offersRecovery == false)
  #expect(recovering.controlHint.contains("rebuilding"))

  let exhausted = MixerRouteControlPolicy(
    app: task9App(state: .error, context: .geometryRecoveryExhausted)
  )
  #expect(exhausted.allowsAudioControl == false)
  #expect(exhausted.offersRecovery)
  #expect(exhausted.controlHint.contains("Recover Routes"))
  #expect(
    MixerRowAccessibility.recoveryLabel(for: task9App(state: .error))
      == "Recover all managed Waves routes"
  )
  #expect(MixerRowAccessibility.recoveryHelp == "Rebuild all managed Waves routes")
  #expect(MixerRowAccessibility.recoveryVisibleLabel == "Recover All Routes")
  #expect(
    MixerRowAccessibility.recoveryHint
      == "Reattaches every active per-app audio route managed by Waves."
  )
}

@Test func routeHealthContextDecodingIsAdditiveForLegacySessions() throws {
  let app = task9App(state: .monitorOnly)
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
  object.removeValue(forKey: "routeHealthContext")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  #expect(try JSONDecoder().decode(AudioApp.self, from: legacy).routeHealthContext == nil)
}

@Test func sessionPersistenceRetainsTypedRouteHealthContext() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-task9-route-health-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = SessionStore(directory: directory)
  let app = task9App(state: .monitorOnly, context: .verifiedRouterOwnership)
  let snapshot = AudioSessionSnapshot(
    apps: [app],
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: .unprobed
  )

  try await store.save(snapshot)
  try await store.flush()

  #expect(store.load()?.apps.first?.routeHealthContext == .verifiedRouterOwnership)
}

@MainActor
@Test func pausedHotkeyCenterAcceptsLatestBindingsWithoutReregisteringUntilResume() throws {
  let center = HotkeyCenter()
  defer { center.unregisterAll() }
  let first = task9Chord(kVK_F15)
  let second = task9Chord(kVK_F16)
  try #require(center.isChordAvailable(first) && center.isChordAvailable(second))

  center.apply([task9Binding(first, .frontmostMute)])
  center.pause()
  #expect(center.isChordAvailable(first))
  #expect(center.apply([task9Binding(second, .frontmostVolumeUp)]).isEmpty)
  #expect(center.isPaused)
  #expect(center.isChordAvailable(first))
  #expect(center.isChordAvailable(second))

  center.resume()
  #expect(center.isChordAvailable(first))
  #expect(center.isChordAvailable(second) == false)
}

@MainActor
@Test func overlappingRecorderRequestsResumeOnlyForTheCurrentOwner() {
  let draft = ControlSettingsDraft()
  let first = HotkeyAction.frontmostMute
  let second = HotkeyAction.showMixer

  #expect(draft.beginRecording(first))
  #expect(draft.beginRecording(second) == false)
  #expect(draft.finishRecording(first) == false)
  #expect(draft.recordingAction == second)
  #expect(draft.finishRecording(second))
  #expect(draft.finishRecording(second) == false)
}

@MainActor
@Test func staleRecorderLeaseCannotFinishARecreatedRecorderForTheSameAction() {
  let draft = ControlSettingsDraft()
  let first = draft.acquireRecording(.frontmostMute)
  let second = draft.acquireRecording(.frontmostMute)

  #expect(first.shouldSuspend)
  #expect(second.shouldSuspend == false)
  #expect(draft.finishRecording(first.lease) == false)
  #expect(draft.recordingAction == .frontmostMute)
  #expect(draft.finishRecording(second.lease))
}

@Test func shortcutRecorderMotionContractDisablesChangedMotionUnderReduceMotion() {
  #expect(ShortcutRecorderMotion.allowsAnimation(reduceMotion: false))
  #expect(ShortcutRecorderMotion.allowsAnimation(reduceMotion: true) == false)
}

@Test func iconEncodingTraversesInjectedExecutorBeforeBlockingWork() async {
  let events = Task9StringEvents()
  let executor = AppIconEncodingExecutor { operation in
    events.append("executor")
    return operation()
  }
  let raster = AppIconRaster(width: 1, height: 1, bytesPerRow: 4, rgbaBytes: Data([0, 0, 0, 255]))
  let encoder = AppIconEncoder(
    operation: { _ in
      events.append("operation")
      return Data([1])
    },
    executor: executor
  )

  #expect(await encoder.encode(raster) == Data([1]))
  #expect(events.values == ["executor", "operation"])
}

@Test(.timeLimit(.minutes(1)))
func defaultIconEncodingExecutorSuspendsMainActorBeforeBlockingWork() async {
  let raster = AppIconRaster(width: 1, height: 1, bytesPerRow: 4, rgbaBytes: Data([0, 0, 0, 255]))
  let encodingStarted = Task9Signal()
  let mainActorRelease = Task9BlockingGate()
  let encoder = AppIconEncoder { _ in
    encodingStarted.signal()
    return Data([mainActorRelease.wait(timeout: 20) ? 1 : 0])
  }
  let task = Task { @MainActor in await encoder.encode(raster) }

  await encodingStarted.wait()
  await MainActor.run {
    mainActorRelease.open()
  }
  #expect(await task.value == Data([1]))
}

@MainActor
@Test func knownIconBytesBypassRasterCaptureAndEncoding() async {
  let captureCount = Task9Counter()
  let encodingCount = Task9Counter()
  let known = Data([1, 2, 3])
  let result = await AppRuntimeDiscovery.resolveIconData(
    logicalID: "com.example.known",
    knownIconData: ["com.example.known": known],
    captureRaster: {
      captureCount.increment()
      return AppIconRaster(
        width: 1,
        height: 1,
        bytesPerRow: 4,
        rgbaBytes: Data([0, 0, 0, 255])
      )
    },
    iconEncoder: AppIconEncoder { raster in
      encodingCount.increment()
      return raster.rgbaBytes
    }
  )

  #expect(result == known)
  #expect(captureCount.value == 0)
  #expect(encodingCount.value == 0)
}

@MainActor
@Test func levelMeterModelUsesDeterministicAttackReleaseHoldAndStallClamp() {
  let model = LevelMeterModel()
  let start = Date(timeIntervalSinceReferenceDate: 1_000)
  model.update(barTarget: 1, peakTarget: 1, at: start)
  let initialBar = model.bar
  #expect(initialBar > 0 && initialBar < 1)
  #expect(model.peak == 1)

  model.update(barTarget: 0, peakTarget: 0, at: start.addingTimeInterval(0.1))
  #expect(model.bar > 0)
  #expect(model.peak == 1)
  let releasedBar = model.bar

  model.update(barTarget: 0, peakTarget: 0, at: start.addingTimeInterval(10))
  #expect(model.bar < releasedBar)
  #expect(model.bar > 0, "the 100 ms stall clamp must prevent a snap to zero")
  #expect(model.peak == 1, "the fixed hold must consume clamped time, not the full stall")

  let beforeNegativeDelta = model.bar
  model.update(barTarget: 1, peakTarget: 1, at: start.addingTimeInterval(9))
  #expect(
    model.bar == beforeNegativeDelta,
    "negative time deltas are clamped to zero and cannot reverse state"
  )

  model.reset()
  #expect(model.bar == 0)
  #expect(model.peak == 0)
  #expect(model.isSettled)
}

private func task9App(
  state: RoutingState,
  context: RouteHealthContext? = nil
) -> AudioApp {
  AudioApp(
    id: "task9.runtime",
    logicalID: "com.example.task9",
    displayName: "Task 9 App",
    category: .media,
    routingState: state,
    compatibility: .supported,
    routeHealthContext: context
  )
}

@MainActor
private func task9Chord(_ keyCode: Int) -> HotkeyChord {
  HotkeyChord(
    keyCode: UInt16(keyCode),
    carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
  )
}

@MainActor
private func task9Binding(_ chord: HotkeyChord, _ action: HotkeyAction) -> HotkeyBinding {
  HotkeyBinding(action: action, keyCode: chord.keyCode, carbonModifiers: chord.carbonModifiers)
}

private final class Task9Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.withLock { count += 1 }
  }

  var value: Int { lock.withLock { count } }
}

private final class Task9BlockingGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var isOpen = false

  func wait(timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while !isOpen, condition.wait(until: deadline) {}
    return isOpen
  }

  func open() {
    condition.lock()
    isOpen = true
    condition.broadcast()
    condition.unlock()
  }
}

private final class Task9Signal: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var isSignaled = false

  func signal() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      isSignaled = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        if isSignaled { return true }
        self.continuation = continuation
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }
}

private final class Task9StringEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues: [String] = []

  func append(_ value: String) {
    lock.withLock { recordedValues.append(value) }
  }

  var values: [String] { lock.withLock { recordedValues } }
}
