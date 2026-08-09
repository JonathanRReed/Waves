import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func freshInstallBootstrapsWithoutCaptureCapableBackendCalls() async {
  let fixture = makePrivacyFixture()

  fixture.store.start()
  await Task.yield()

  #expect(fixture.store.startupState == .awaitingPrivacy)
  #expect(fixture.store.privacySetupPresentationState == .awaitingPrivacy)
  #expect(fixture.store.onboarding.hasCompletedPrivacySetup == false)
  #expect(await fixture.backend.calls().isEmpty)
}

@MainActor
@Test func existingInstallMissingPrivacyKeyStartsNormally() async throws {
  let data = Data(#"{"urlSchemeAutomationAcknowledged":true,"appAudioIntentMigrationVersion":1}"#.utf8)
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
  #expect(decoded.hasCompletedPrivacySetup)

  let fixture = makePrivacyFixture(preferences: decoded)
  fixture.store.start()
  await fixture.store.waitForAudioStartup()

  #expect(fixture.store.startupState == .running)
  #expect(fixture.store.privacySetupPresentationState == .hidden)
  #expect(await fixture.backend.callCount(named: "backend.start") == 1)
  #expect(await fixture.backend.callCount(named: "backend.currentSnapshot") >= 1)
  #expect(await fixture.backend.callCount(named: "backend.diagnostics") == 1)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func continueSavesConsentBeforeStartingAudio() async {
  let recorder = PrivacyCallRecorder()
  let fixture = makePrivacyFixture(recorder: recorder)

  fixture.store.start()
  await fixture.store.acceptPrivacySetupAndStart()

  let events = recorder.events()
  #expect(events.first == "preferences.save:true")
  #expect(events.dropFirst().first == "backend.start")
  #expect(fixture.preferencesStore.value.hasCompletedPrivacySetup)
  #expect(fixture.store.preferences.hasCompletedPrivacySetup)
  #expect(fixture.store.startupState == .running)
  #expect(fixture.store.sessionMaintenanceStartCount == 1)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func requiredSetupCompletionIsDurableBeforeItBecomesLaunchState() async {
  var preferences = freshPrivacyPreferences()
  preferences.hasCompletedPrivacySetup = true
  let fixture = makePrivacyFixture(preferences: preferences)
  fixture.store.start()
  await fixture.store.waitForAudioStartup()

  let completed = await fixture.store.completeRequiredSetup(
    version: OnboardingExperience.currentVersion
  )

  #expect(completed)
  #expect(
    fixture.store.preferences.requiredSetupVersion == OnboardingExperience.currentVersion
  )
  #expect(fixture.store.preferences.hasCompletedGuidedSetup)
  #expect(
    fixture.preferencesStore.value.requiredSetupVersion == OnboardingExperience.currentVersion
  )
  #expect(fixture.preferencesStore.value.hasCompletedGuidedSetup)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func requiredSetupLaunchStateRemainsIncompleteWhileDurableSaveIsPending() async {
  var preferences = freshPrivacyPreferences()
  preferences.hasCompletedPrivacySetup = true
  let fixture = makePrivacyFixture(preferences: preferences)
  fixture.store.start()
  await fixture.store.waitForAudioStartup()
  await fixture.preferencesStore.suspendNextSave()

  let completion = Task { @MainActor in
    await fixture.store.completeRequiredSetup(
      version: OnboardingExperience.currentVersion
    )
  }
  await fixture.preferencesStore.waitUntilSaveBegins()

  #expect(fixture.store.onboardingLaunchDecision == .requiredSetup(.readiness))
  #expect(fixture.store.preferences.requiredSetupVersion == 0)
  #expect(!fixture.store.preferences.hasCompletedGuidedSetup)
  #expect(fixture.store.trackedPersistenceTaskCount == 1)

  fixture.store.preferences.appearance = .dark
  fixture.store.persistPreferences()

  await fixture.preferencesStore.resumeSave()
  #expect(await completion.value)
  #expect(
    fixture.store.onboardingLaunchDecision
      == .mixer(showWhatsNew: false, showTourTip: false)
  )
  await fixture.store.drainPersistenceTasks()
  #expect(fixture.preferencesStore.value.appearance == .dark)
  #expect(
    fixture.preferencesStore.value.requiredSetupVersion
      == OnboardingExperience.currentVersion
  )
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func requiredSetupPersistenceFailureLeavesSetupIncomplete() async {
  var preferences = freshPrivacyPreferences()
  preferences.hasCompletedPrivacySetup = true
  let fixture = makePrivacyFixture(preferences: preferences)
  fixture.store.start()
  await fixture.store.waitForAudioStartup()
  fixture.preferencesStore.saveError = PrivacyStartupTestError.writeFailed

  let completed = await fixture.store.completeRequiredSetup(
    version: OnboardingExperience.currentVersion
  )

  #expect(!completed)
  #expect(fixture.store.preferences.requiredSetupVersion == 0)
  #expect(!fixture.store.preferences.hasCompletedGuidedSetup)
  #expect(fixture.preferencesStore.value.requiredSetupVersion == 0)
  #expect(fixture.store.toasts.contains { $0.title == "Setup may appear again" })
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func completedUpgradeLaunchesWarmMixerAndOffersWhatsNewOnly() {
  var preferences = freshPrivacyPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion
  let fixture = makePrivacyFixture(
    preferences: preferences,
    cachedSession: privacyTestSnapshot(apps: [privacyTestApp()]),
    installLocation: .applications
  )

  #expect(
    fixture.store.onboardingLaunchDecision
      == .mixer(showWhatsNew: true, showTourTip: false)
  )
  #expect(fixture.store.showsWarmStartMixer)
}

@MainActor
@Test func mountedImageAdvisoryPrecedesSetupAndCanContinue() {
  let fixture = makePrivacyFixture(installLocation: .mountedDiskImage)

  #expect(
    fixture.store.onboardingLaunchDecision
      == .installationAdvisory(.mountedDiskImage)
  )

  fixture.store.continueFromInstallationAdvisory()

  #expect(fixture.store.onboardingLaunchDecision == .requiredSetup(.welcome))
}

@MainActor
@Test func setupWhatsNewAndTourReplayRemainSeparate() {
  var preferences = freshPrivacyPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion
  preferences.whatsNewDismissedVersion = OnboardingExperience.currentVersion
  let fixture = makePrivacyFixture(
    preferences: preferences,
    cachedSession: privacyTestSnapshot(apps: [privacyTestApp()])
  )

  fixture.store.runRequiredSetupReplay()
  #expect(fixture.store.onboardingLaunchDecision == .requiredSetup(.welcome))
  #expect(fixture.store.guidedMixerTourCoordinator.state == .inactive)

  fixture.store.cancelRequiredSetupReplay()
  fixture.store.showWhatsNew()
  #expect(fixture.store.shouldShowWhatsNew)
  #expect(fixture.store.guidedMixerTourCoordinator.state == .inactive)

  fixture.store.startGuidedMixerTour()
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .chooseSound, appID: "privacy.app")
  )
  #expect(!fixture.store.shouldShowWhatsNew)

  fixture.store.endGuidedMixerTour(reason: .escape)
  #expect(
    fixture.store.preferences.guidedTourDismissedVersion
      == OnboardingExperience.currentVersion
  )
}

@MainActor
@Test func guidedTourRemainsVisibleAndDismissibleAfterItsTargetExits() {
  var preferences = freshPrivacyPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion
  preferences.whatsNewDismissedVersion = OnboardingExperience.currentVersion
  let fixture = makePrivacyFixture(
    preferences: preferences,
    cachedSession: privacyTestSnapshot(apps: [privacyTestApp()])
  )

  fixture.store.startGuidedMixerTour()
  fixture.store.session.apps = []

  let presentation = fixture.store.guidedMixerTourPresentation
  #expect(presentation?.appName == "Privacy App")
  #expect(presentation?.isTargetAvailable == false)
  fixture.store.advanceGuidedMixerTour()
  fixture.store.advanceGuidedMixerTour()
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .muteAndRestore, appID: "privacy.app")
  )
  fixture.store.endGuidedMixerTour(reason: .escape)
  #expect(fixture.store.guidedMixerTourPresentation == nil)
}

@MainActor
@Test func privacyPersistenceFailureKeepsBackendUntouchedAndSetupIncomplete() async {
  let fixture = makePrivacyFixture()
  fixture.preferencesStore.saveError = PrivacyStartupTestError.writeFailed

  fixture.store.start()
  await fixture.store.acceptPrivacySetupAndStart()

  #expect(fixture.store.startupState == .awaitingPrivacy)
  #expect(fixture.store.privacySetupPresentationState == .awaitingPrivacy)
  #expect(fixture.store.preferences.hasCompletedPrivacySetup == false)
  #expect(fixture.preferencesStore.value.hasCompletedPrivacySetup == false)
  #expect(fixture.store.privacySetupError?.contains("couldn't save") == true)
  #expect(await fixture.backend.calls().isEmpty)
  #expect(fixture.store.toasts.contains { $0.title == "Setup wasn't saved" })
}

@MainActor
@Test func backendStartupFailureRetainsConsentAndRetryDoesNotResave() async {
  let fixture = makePrivacyFixture(startFailures: 1)

  fixture.store.start()
  await fixture.store.acceptPrivacySetupAndStart()

  guard case .failed = fixture.store.startupState else {
    Issue.record("Expected failed startup state")
    return
  }
  #expect(fixture.store.preferences.hasCompletedPrivacySetup)
  #expect(fixture.preferencesStore.value.hasCompletedPrivacySetup)
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(await fixture.backend.callCount(named: "backend.start") == 1)
  #expect(fixture.store.sessionMaintenanceStartCount == 0)

  await fixture.store.acceptPrivacySetupAndStart()

  #expect(fixture.store.startupState == .running)
  #expect(fixture.store.privacySetupPresentationState == .hidden)
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(await fixture.backend.callCount(named: "backend.start") == 2)
  #expect(fixture.store.sessionMaintenanceStartCount == 1)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func repeatedStartContinueAndRetryShareSingleLifecycleTasks() async {
  let fixture = makePrivacyFixture()

  fixture.store.start()
  fixture.store.start()
  let firstContinue = Task { @MainActor in
    await fixture.store.acceptPrivacySetupAndStart()
  }
  let secondContinue = Task { @MainActor in
    await fixture.store.acceptPrivacySetupAndStart()
  }
  await firstContinue.value
  await secondContinue.value

  fixture.store.start()
  await fixture.store.acceptPrivacySetupAndStart()
  fixture.store.start()

  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(await fixture.backend.callCount(named: "backend.start") == 1)
  #expect(fixture.store.sessionMaintenanceStartCount == 1)
  #expect(fixture.store.hasActiveSessionMaintenance)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func gatedEntryPointsCannotReachBackendOrMutateCachedAudio() async {
  let cachedApp = privacyTestApp()
  let snapshot = privacyTestSnapshot(apps: [cachedApp])
  var preferences = freshPrivacyPreferences()
  preferences.enableURLScheme = true
  preferences.enableKeyboardShortcuts = true
  let fixture = makePrivacyFixture(preferences: preferences, cachedSession: snapshot)
  let alternateDevice = AudioDevice(id: "device.other", name: "Other", kind: .bluetooth)
  let profile = Profile(
    name: "Blocked",
    entries: [ProfileEntry(appID: cachedApp.logicalID, desiredVolume: 0.2)]
  )

  fixture.store.start()
  fixture.store.refresh(announce: false)
  fixture.store.refreshDiagnostics()
  fixture.store.recoverRoutes()
  fixture.store.refreshOutputDevices()
  fixture.store.selectOutputDevice(alternateDevice)
  fixture.store.handleDeviceChange()
  fixture.store.setDesiredVolume(0.2, for: cachedApp)
  fixture.store.commitDesiredVolume(for: cachedApp)
  fixture.store.setMuted(true, for: cachedApp)
  fixture.store.setVolumeBoost(3, for: cachedApp)
  fixture.store.setEqualizerEnabled(true, for: cachedApp)
  fixture.store.setAdaptiveRole(.voice, for: cachedApp)
  fixture.store.setAdaptiveMixMode(.both)
  fixture.store.setOutputDevice(alternateDevice, for: cachedApp)
  fixture.store.togglePinned(cachedApp)
  fixture.store.setExcluded(true, for: cachedApp)
  fixture.store.applyProfile(profile)
  fixture.store.handleURLScheme(URL(string: "waves://refresh")!)
  fixture.store.increaseVolumeForFrontmostApp()
  fixture.store.decreaseVolumeForFrontmostApp()
  fixture.store.toggleMuteForFrontmostApp()
  fixture.store.setAutoPauseMusicEnabled(false)
  fixture.store.setAutoRestoreDeviceEnabled(false)
  fixture.store.checkAutoPauseMusic()
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  let result = await fixture.store.applyAppIntent(
    forAppID: cachedApp.logicalID,
    reason: .userEdit
  )
  fixture.store.beginLiveLevels()
  await Task.yield()

  #expect(result.outcome == .failed)
  #expect(result.detail?.contains("Finish setup") == true)
  #expect(await fixture.backend.calls().isEmpty)
  #expect(fixture.store.session.apps.first?.desiredVolume == cachedApp.desiredVolume)
  #expect(fixture.store.session.apps.first?.isMuted == cachedApp.isMuted)
  #expect(fixture.store.session.apps.first?.volumeBoost == cachedApp.volumeBoost)
  #expect(fixture.store.preferences.adaptiveMixMode == .off)
  #expect(fixture.store.preferences.excludedAppIDs.isEmpty)
  #expect(fixture.store.preferences.pinnedAppIDs.isEmpty)
  #expect(fixture.store.preferences.autoPauseMusicForConferencing)
  #expect(fixture.store.preferences.autoRestoreDevice)
  #expect(fixture.store.toasts.count { $0.title == "Finish setup" } == 1)

  fixture.store.endLiveLevels()
  _ = await fixture.store.shutdown()
  await Task.yield()
  #expect(await fixture.backend.calls().isEmpty)
}

@MainActor
@Test func setupPresentationAndStructuredProbeFailureAreBackendIndependent() async {
  let fresh = makePrivacyFixture()
  fresh.store.start()
  #expect(fresh.store.privacySetupPresentationState == .awaitingPrivacy)

  var existing = freshPrivacyPreferences()
  existing.hasCompletedPrivacySetup = true
  let probeFailure = makePrivacyFixture(
    preferences: existing,
    captureAuthorization: .probeFailed(nativeStatus: -50)
  )
  probeFailure.store.start()
  await probeFailure.store.waitForAudioStartup()

  #expect(probeFailure.store.privacySetupPresentationState == .hidden)
  #expect(probeFailure.store.onboarding.captureAuthorization == .probeFailed(nativeStatus: -50))
  #expect(probeFailure.store.onboarding.permissionsGranted == false)
  #expect(probeFailure.store.onboarding.routeHealthReady == false)
  _ = await probeFailure.store.shutdown()
}

@MainActor
@Test func legacySessionPinsImportOnceAndAdvanceExplicitMarker() async {
  var preferences = freshPrivacyPreferences()
  preferences.pinMigrationVersion = 0
  let legacyPinnedApp = AudioApp(
    id: "legacy.pin.runtime",
    logicalID: "legacy.pin",
    displayName: "Legacy Pin",
    category: .media,
    isPinned: true
  )

  let fixture = makePrivacyFixture(
    preferences: preferences,
    cachedSession: privacyTestSnapshot(apps: [legacyPinnedApp])
  )
  await fixture.store.drainPersistenceTasks()

  #expect(fixture.store.preferences.pinnedAppIDs == ["legacy.pin"])
  #expect(fixture.store.preferences.pinMigrationVersion == 1)
  #expect(fixture.preferencesStore.value.pinMigrationVersion == 1)
}

@MainActor
@Test func emptyLegacySessionStillAdvancesPinMigrationMarker() async {
  var preferences = freshPrivacyPreferences()
  preferences.pinMigrationVersion = 0

  let fixture = makePrivacyFixture(
    preferences: preferences,
    cachedSession: privacyTestSnapshot(apps: [])
  )
  await fixture.store.drainPersistenceTasks()

  #expect(fixture.store.preferences.pinnedAppIDs.isEmpty)
  #expect(fixture.store.preferences.pinMigrationVersion == 1)
  #expect(fixture.preferencesStore.value.pinMigrationVersion == 1)
}

@MainActor
@Test func completedEmptyPinMigrationNeverReimportsSessionPins() async {
  var preferences = freshPrivacyPreferences()
  preferences.pinMigrationVersion = 1
  preferences.pinnedAppIDs = []
  let legacyPinnedApp = AudioApp(
    id: "cleared.pin.runtime",
    logicalID: "cleared.pin",
    displayName: "Cleared Pin",
    category: .media,
    isPinned: true
  )

  let firstLaunch = makePrivacyFixture(
    preferences: preferences,
    cachedSession: privacyTestSnapshot(apps: [legacyPinnedApp])
  )
  await firstLaunch.store.drainPersistenceTasks()
  let persisted = firstLaunch.preferencesStore.value
  let secondLaunch = makePrivacyFixture(
    preferences: persisted,
    cachedSession: privacyTestSnapshot(apps: [legacyPinnedApp])
  )
  await secondLaunch.store.drainPersistenceTasks()

  #expect(firstLaunch.store.preferences.pinnedAppIDs.isEmpty)
  #expect(secondLaunch.store.preferences.pinnedAppIDs.isEmpty)
  #expect(secondLaunch.store.preferences.pinMigrationVersion == 1)
}

@MainActor
@Test func aggregateAppStoreLifecycleShutdownDrainsEveryOwnerRepeatedly() async {
  for iteration in 0..<10 {
    var preferences = freshPrivacyPreferences()
    preferences.hasCompletedPrivacySetup = true
    preferences.adaptiveMixMode = .both
    let app = privacyTestApp()
    let fixture = makePrivacyFixture(
      preferences: preferences,
      cachedSession: privacyTestSnapshot(apps: [app])
    )

    fixture.store.start()
    await fixture.store.waitForAudioStartup()
    fixture.store.beginLiveLevels()
    fixture.store.setEqualizerEnabled(true, for: app)
    fixture.store.selectOutputDevice(
      AudioDevice(
        id: "device.pending.\(iteration)",
        name: "Pending \(iteration)",
        kind: .virtual
      ))
    await Task.yield()

    let active = fixture.store.lifecycleSnapshot
    #expect(active.intent.equalizerDebounces == 1)
    #expect(active.adaptive.hasLoop)
    #expect(active.deviceSuppression.trackedTaskCount == 1)
    #expect(active.hasLevelPoll)
    #expect(active.hasSessionMaintenance)
    #expect(active.observerCount == 3)
    #expect(active.backendStarted)

    _ = await fixture.store.shutdown()
    #expect(fixture.store.lifecycleSnapshot.isIdle)
  }
}

private struct PrivacyFixture {
  let store: AppStore
  let backend: PrivacyRecordingBackend
  let preferencesStore: PrivacyPreferencesStore
}

@MainActor
private func makePrivacyFixture(
  preferences: UserPreferences = freshPrivacyPreferences(),
  cachedSession: AudioSessionSnapshot? = nil,
  recorder: PrivacyCallRecorder = PrivacyCallRecorder(),
  startFailures: Int = 0,
  captureAuthorization: CaptureAuthorizationResult = .authorized,
  installLocation: InstallLocationClassification = .applications
) -> PrivacyFixture {
  let snapshot = cachedSession ?? privacyTestSnapshot(apps: [])
  let backend = PrivacyRecordingBackend(
    snapshot: snapshot,
    recorder: recorder,
    startFailures: startFailures,
    captureAuthorization: captureAuthorization
  )
  let preferencesStore = PrivacyPreferencesStore(value: preferences, recorder: recorder)
  let sessionStore = PrivacySessionStore(value: cachedSession)
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: PrivacyProfilesStore(),
    sessionStore: sessionStore,
    loginItemService: PrivacyLoginItemService(),
    deviceVolumePresetsStore: PrivacyDevicePresetsStore(),
    installLocation: installLocation
  )
  return PrivacyFixture(
    store: store,
    backend: backend,
    preferencesStore: preferencesStore
  )
}

private func freshPrivacyPreferences() -> UserPreferences {
  var preferences = UserPreferences()
  preferences.urlSchemeAutomationAcknowledged = true
  preferences.appAudioIntentMigrationVersion = 1
  return preferences
}

private func privacyTestApp() -> AudioApp {
  AudioApp(
    id: "privacy.app.runtime",
    logicalID: "privacy.app",
    pid: 77,
    bundleID: "privacy.app",
    displayName: "Privacy App",
    category: .media,
    isActive: true,
    peakLevel: 0.35,
    rmsLevel: 0.22,
    desiredVolume: 0.7,
    appliedVolume: 0.7,
    isMuted: false,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: 1.5
  )
}

private func privacyTestSnapshot(apps: [AudioApp]) -> AudioSessionSnapshot {
  let device = AudioDevice(id: "device.current", name: "Current", kind: .builtInOutput)
  return AudioSessionSnapshot(
    apps: apps,
    currentDevice: device,
    recentDeviceIDs: [device.id],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

private enum PrivacyStartupTestError: LocalizedError {
  case writeFailed
  case startFailed

  var errorDescription: String? {
    switch self {
    case .writeFailed: "Injected privacy preference write failure"
    case .startFailed: "Injected audio startup failure"
    }
  }
}

private final class PrivacyCallRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedEvents: [String] = []

  func append(_ event: String) {
    lock.withLock { recordedEvents.append(event) }
  }

  func events() -> [String] {
    lock.withLock { recordedEvents }
  }
}

private actor PrivacyRecordingBackend: AudioControlBackend {
  nonisolated let deviceChangeEvents: AsyncStream<Void> = AsyncStream { _ in }

  private var snapshot: AudioSessionSnapshot
  private let recorder: PrivacyCallRecorder
  private var startFailuresRemaining: Int
  private let captureAuthorization: CaptureAuthorizationResult

  init(
    snapshot: AudioSessionSnapshot,
    recorder: PrivacyCallRecorder,
    startFailures: Int,
    captureAuthorization: CaptureAuthorizationResult
  ) {
    self.snapshot = snapshot
    self.recorder = recorder
    self.startFailuresRemaining = startFailures
    self.captureAuthorization = captureAuthorization
  }

  func calls() -> [String] { recorder.events().filter { $0.hasPrefix("backend.") } }
  func callCount(named name: String) -> Int { calls().count { $0 == name } }

  func start() async throws {
    recorder.append("backend.start")
    if startFailuresRemaining > 0 {
      startFailuresRemaining -= 1
      throw PrivacyStartupTestError.startFailed
    }
  }

  func stop() async { recorder.append("backend.stop") }

  func currentSnapshot() async -> AudioSessionSnapshot {
    recorder.append("backend.currentSnapshot")
    return snapshot
  }

  func refresh() async throws -> AudioSessionSnapshot {
    recorder.append("backend.refresh")
    return snapshot
  }

  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    recorder.append("backend.volume")
  }

  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    recorder.append("backend.mute")
  }

  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    recorder.append("backend.boost")
  }

  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {
    recorder.append("backend.equalizer")
  }

  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] {
    recorder.append("backend.adaptiveAnalysis")
    return [:]
  }

  func setAdaptiveGains(_ gainsDB: [String: Float]) async {
    recorder.append("backend.adaptiveGains")
  }

  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {
    recorder.append("backend.volumeMode")
  }

  func pinApp(_ isPinned: Bool, appID: String) async throws {
    recorder.append("backend.pin")
  }

  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot {
    recorder.append("backend.profile")
    return snapshot
  }

  func saveCurrentProfile(named name: String) async throws -> Profile {
    recorder.append("backend.saveProfile")
    return Profile(name: name, entries: [])
  }

  func recoverRoutes() async throws -> AudioSessionSnapshot {
    recorder.append("backend.recover")
    return snapshot
  }

  func autoRestoreDevice() async throws -> AudioSessionSnapshot {
    recorder.append("backend.autoRestore")
    return snapshot
  }

  func diagnosticsReport() async -> DiagnosticsReport {
    recorder.append("backend.diagnostics")
    return DiagnosticsReport(summary: "Privacy startup test", checks: [])
  }

  func availableOutputDevices() async -> [AudioDevice] {
    recorder.append("backend.availableDevices")
    return snapshot.currentDevice.map { [$0] } ?? []
  }

  func setDefaultOutputDevice(uid: String) async throws {
    recorder.append("backend.defaultDevice")
  }

  func setOutputDevice(uid: String?, forAppID appID: String) async throws {
    recorder.append("backend.appOutput")
  }

  func releaseControllers(
    forRuntimeIdentity runtimeIdentity: AppRuntimeIdentity,
    clearMuteState: Bool
  ) async {
    recorder.append("backend.release")
  }

  func audioLevels() async -> [String: AudioLevels] {
    recorder.append("backend.levels")
    return [:]
  }

  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    recorder.append("backend.intent")
    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: .noChange,
      resultingApp: snapshot.apps.first { $0.logicalID == intent.appID },
      backendStatus: snapshot.backendStatus
    )
  }

  func applyProfileWithResults(_ profile: Profile, generation: UInt64) async -> ProfileApplyResult {
    recorder.append("backend.profileResults")
    return ProfileApplyResult(rows: [], backendStatus: snapshot.backendStatus)
  }

  func audioCapabilityMode() async -> AudioCapabilityMode {
    recorder.append("backend.capability")
    return .full
  }

  func captureAuthorizationResult() async -> CaptureAuthorizationResult {
    recorder.append("backend.captureAuthorization")
    return captureAuthorization
  }
}

private final class PrivacyPreferencesStore: PreferencesPersisting, @unchecked Sendable {
  var value: UserPreferences
  var saveError: Error?
  private(set) var saveCount = 0
  private let recorder: PrivacyCallRecorder
  private let saveGate = PrivacySaveGate()

  init(value: UserPreferences, recorder: PrivacyCallRecorder) {
    self.value = value
    self.recorder = recorder
  }

  func load() -> UserPreferences { value }

  func save(_ preferences: UserPreferences) async throws {
    recorder.append("preferences.save:\(preferences.hasCompletedPrivacySetup)")
    await saveGate.waitIfArmed()
    if let saveError { throw saveError }
    value = preferences
    saveCount += 1
  }

  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }

  func suspendNextSave() async {
    await saveGate.arm()
  }

  func waitUntilSaveBegins() async {
    await saveGate.waitUntilStarted()
  }

  func resumeSave() async {
    await saveGate.resume()
  }
}

private actor PrivacySaveGate {
  private var isArmed = false
  private var hasStarted = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var resumeContinuation: CheckedContinuation<Void, Never>?

  func arm() {
    isArmed = true
    hasStarted = false
  }

  func waitIfArmed() async {
    guard isArmed else { return }
    hasStarted = true
    let waiters = startedWaiters
    startedWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      resumeContinuation = continuation
    }
    isArmed = false
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { continuation in
      startedWaiters.append(continuation)
    }
  }

  func resume() {
    resumeContinuation?.resume()
    resumeContinuation = nil
  }
}

private final class PrivacyProfilesStore: ProfilesPersisting, @unchecked Sendable {
  func load(defaults: [Profile]) -> [Profile] { defaults }
  func save(_ profiles: [Profile]) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class PrivacySessionStore: SessionPersisting, @unchecked Sendable {
  var value: AudioSessionSnapshot?

  init(value: AudioSessionSnapshot?) {
    self.value = value
  }

  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws { value = snapshot }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class PrivacyDevicePresetsStore: DeviceVolumePresetsPersisting, @unchecked Sendable {
  func load() -> DeviceVolumePresets { DeviceVolumePresets() }
  func save(_ presets: DeviceVolumePresets) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class PrivacyLoginItemService: LoginItemServicing {
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
