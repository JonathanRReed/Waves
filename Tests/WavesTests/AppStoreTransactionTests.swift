import AppKit
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test(arguments: [
  AppIntentApplyOutcome.applied, .noChange, .superseded, .excluded, .unavailable, .unsupported, .failed,
])
func firstControlTelemetryConfirmsOnlyAcceptedBackendResults(outcome: AppIntentApplyOutcome) async {
  let app = transactionTestApp()
  let fixture = makeTransactionFixture(
    apps: [app], device: transactionTestDevice(), outcomes: [outcome]
  )
  let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)

  _ = await fixture.store.startAppIntentTransaction(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(desiredVolume: app.desiredVolume, isMuted: app.isMuted),
    reason: .userEdit,
    persistencePolicy: .none,
    feedbackPolicy: .none,
    optimistic: false,
    performanceRecorder: recorder
  ).value

  if outcome == .applied || outcome == .noChange {
    #expect(recorder.snapshot.map(\.milestone) == [.firstControlSubmitted, .firstControlConfirmed])
  } else {
    #expect(recorder.snapshot.map(\.milestone) == [.firstControlSubmitted])
  }
}

@MainActor
@Test func noChangeFromADifferentGenerationCannotConfirmFirstControl() async {
  let app = transactionTestApp()
  let fixture = makeTransactionFixture(
    apps: [app], device: transactionTestDevice(), outcomes: [.noChange], resultGenerationOffset: 1
  )
  let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)

  _ = await fixture.store.startAppIntentTransaction(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(desiredVolume: app.desiredVolume, isMuted: app.isMuted),
    reason: .userEdit,
    persistencePolicy: .none,
    feedbackPolicy: .none,
    optimistic: false,
    performanceRecorder: recorder
  ).value

  #expect(recorder.snapshot.map(\.milestone) == [.firstControlSubmitted])
}

@MainActor
@Test func guidedTourAdvancesOnlyAfterAcceptedAppStoreIntents() async {
  var app = transactionTestApp(desiredVolume: 0.7)
  app.peakLevel = 0.25
  app.rmsLevel = 0.1
  let fixture = makeTransactionFixture(apps: [app], device: transactionTestDevice())

  fixture.store.startGuidedMixerTour()
  #expect(fixture.store.consumeSourceFocusRequest() == .running)
  fixture.store.advanceGuidedMixerTour()
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .setLevel, appID: app.logicalID)
  )
  fixture.store.advanceGuidedMixerTour()
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .setLevel, appID: app.logicalID)
  )

  _ = await fixture.store.applyAppIntent(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(desiredVolume: 0.4),
    reason: .userEdit
  )
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .muteAndRestore, appID: app.logicalID)
  )

  _ = await fixture.store.applyAppIntent(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(isMuted: true),
    reason: .userEdit
  )
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .muteAndRestore, appID: app.logicalID)
  )

  _ = await fixture.store.applyAppIntent(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(isMuted: false),
    reason: .userEdit
  )
  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .goFurther, appID: app.logicalID)
  )
}

@MainActor
@Test func failedAppStoreIntentDoesNotAdvanceGuidedTour() async {
  var app = transactionTestApp(desiredVolume: 0.7)
  app.peakLevel = 0.25
  app.rmsLevel = 0.1
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    outcomes: [.failed]
  )

  fixture.store.startGuidedMixerTour()
  fixture.store.advanceGuidedMixerTour()
  _ = await fixture.store.applyAppIntent(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(desiredVolume: 0.4),
    reason: .userEdit
  )

  #expect(
    fixture.store.guidedMixerTourCoordinator.state
      == .active(moment: .setLevel, appID: app.logicalID)
  )
}

@MainActor
@Test func silentMaintenancePublishesOnlySemanticSessionAndDiagnosticsChanges() async throws {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    refreshApps: [app]
  )

  await fixture.store.performSilentSessionRefresh()
  await fixture.store.drainPersistenceTasks()
  #expect(await fixture.backend.refreshCallCount() == 1)
  #expect(await fixture.backend.diagnosticsCallCount() == 1)
  let unchangedSession = fixture.store.session
  let unchangedDiagnostics = fixture.store.diagnostics
  let unchangedDiagnosticID = try #require(unchangedDiagnostics?.checks.first?.id)
  let unchangedAuthorization = fixture.store.onboarding.captureAuthorization
  let unchangedDevices = fixture.store.availableDevices
  let unchangedSaveCount = fixture.sessionStore.saveCount

  await fixture.store.performSilentSessionRefresh()
  await fixture.store.drainPersistenceTasks()

  #expect(await fixture.backend.refreshCallCount() == 2)
  #expect(await fixture.backend.diagnosticsCallCount() == 2)
  #expect(fixture.store.session == unchangedSession)
  #expect(fixture.store.diagnostics == unchangedDiagnostics)
  #expect(fixture.store.diagnostics?.checks.first?.id == unchangedDiagnosticID)
  #expect(fixture.store.onboarding.captureAuthorization == unchangedAuthorization)
  #expect(fixture.store.availableDevices == unchangedDevices)
  #expect(fixture.sessionStore.saveCount == unchangedSaveCount)

  var changedApp = app
  changedApp.desiredVolume = 0.7
  let changedDevice = AudioDevice(id: "device.changed", name: "Changed Device", kind: .bluetooth)
  var changedSnapshot = transactionSnapshot(apps: [changedApp], device: changedDevice)
  changedSnapshot.backendStatus.isRouteRecoveryHealthy = false
  changedSnapshot.backendStatus.lastError = "Injected maintenance change"
  await fixture.backend.setRefreshSnapshot(changedSnapshot)

  await fixture.store.performSilentSessionRefresh()
  await fixture.store.drainPersistenceTasks()

  #expect(await fixture.backend.refreshCallCount() == 3)
  #expect(await fixture.backend.diagnosticsCallCount() == 3)
  #expect(await fixture.backend.diagnosticsReprobeRequests() == [false, false, false])
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.7)
  #expect(fixture.store.session.currentDevice == changedDevice)
  #expect(fixture.store.session.backendStatus == changedSnapshot.backendStatus)
  #expect(fixture.sessionStore.saveCount == unchangedSaveCount + 1)
}

@MainActor
@Test(arguments: ["title", "status", "detail"])
func silentMaintenancePublishesDiagnosticSemanticChanges(field: String) async throws {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let fixture = makeTransactionFixture(apps: [app], device: device, refreshApps: [app])

  await fixture.store.performSilentSessionRefresh()
  let initialDiagnostics = try #require(fixture.store.diagnostics)
  let initialCheck = try #require(initialDiagnostics.checks.first)

  var title = initialCheck.title
  var status = initialCheck.status
  var detail = initialCheck.detail
  switch field {
  case "title": title = "Changed audio component"
  case "status": status = .warning
  case "detail": detail = "Injected diagnostic content change."
  default: Issue.record("Unexpected diagnostic field: \(field)")
  }
  await fixture.backend.setDiagnosticsTemplate(
    DiagnosticsReport(
      summary: initialDiagnostics.summary,
      checks: [DiagnosticsCheck(title: title, status: status, detail: detail)]
    )
  )

  await fixture.store.performSilentSessionRefresh()

  let changedDiagnostics = try #require(fixture.store.diagnostics)
  let changedCheck = try #require(changedDiagnostics.checks.first)
  #expect(changedDiagnostics != initialDiagnostics)
  #expect(changedCheck.title == title)
  #expect(changedCheck.status == status)
  #expect(changedCheck.detail == detail)
}

@MainActor
@Test func failedDirectControlsPreserveDurableIntentAndDevicePreset() async {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let baselineEQ = EqualizerSettings(isEnabled: false, adaptiveRole: .media)
  let baselineIntent = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost,
    equalizerSettings: baselineEQ,
    targetDeviceUID: app.targetDeviceUID
  )
  let baselinePreset = AppVolumeSettings(
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baselineIntent,
    preset: baselinePreset,
    outcomes: Array(repeating: .failed, count: 5)
  )

  fixture.store.setDesiredVolume(0.15, for: app)
  fixture.store.commitDesiredVolume(for: app)
  await fixture.store.drainAppIntentTransactions()
  assertBaselineState(fixture.store, app: app, intent: baselineIntent, preset: baselinePreset, device: device)

  fixture.store.setMuted(true, for: app)
  await fixture.store.drainAppIntentTransactions()
  assertBaselineState(fixture.store, app: app, intent: baselineIntent, preset: baselinePreset, device: device)

  fixture.store.setVolumeBoost(3.5, for: app)
  await fixture.store.drainAppIntentTransactions()
  assertBaselineState(fixture.store, app: app, intent: baselineIntent, preset: baselinePreset, device: device)

  fixture.store.setEqualizerEnabled(true, for: app)
  await fixture.store.drainAppIntentTransactions()
  assertBaselineState(fixture.store, app: app, intent: baselineIntent, preset: baselinePreset, device: device)
  #expect(fixture.store.equalizerSettings(for: app) == baselineEQ)

  let alternateDevice = AudioDevice(id: "device.alternate", name: "Alternate", kind: .bluetooth)
  fixture.store.setOutputDevice(alternateDevice, for: app)
  await fixture.store.drainAppIntentTransactions()
  assertBaselineState(fixture.store, app: app, intent: baselineIntent, preset: baselinePreset, device: device)

  #expect(await fixture.backend.recordedIntents().count == 5)
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.presetsStore.saveCount == 0)
  #expect(fixture.store.trackedAppIntentTaskCount == 0)
}

@MainActor
@Test func supersededFailureCannotRollbackNewerRuntimeOrDurableState() async {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baseline,
    preset: AppVolumeSettings(
      desiredVolume: app.desiredVolume,
      isMuted: false,
      volumeBoost: app.volumeBoost
    ),
    outcomes: [.failed, .applied],
    suspendFirstIntent: true
  )

  fixture.store.setMuted(true, for: app)
  await fixture.backend.waitUntilFirstIntentIsSuspended()
  fixture.store.setVolumeBoost(3, for: app)
  let drain = Task { @MainActor in await fixture.store.drainAppIntentTransactions() }
  await Task.yield()
  #expect(fixture.store.trackedAppIntentTaskCount == 2)
  await fixture.backend.resumeFirstIntent()
  await drain.value
  await waitUntil { await fixture.backend.completedIntentCount() == 2 }

  let current = fixture.store.session.apps.first
  #expect(current?.isMuted == true)
  #expect(current?.volumeBoost == 3)
  #expect(current?.routingState == .managed)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.isMuted == true)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.volumeBoost == 3)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id)?.isMuted == true
  )
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id)?.volumeBoost == 3
  )
  #expect(!fixture.store.toasts.contains { $0.title == "Mute toggle failed" })
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(fixture.presetsStore.saveCount == 1)
}

@MainActor
@Test func shutdownWaitsForCancellationInsensitiveSupersededIntent() async {
  let app = transactionTestApp(id: "shutdown.retained")
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    outcomes: [.failed, .applied],
    suspendFirstIntent: true
  )

  fixture.store.setMuted(true, for: app)
  await fixture.backend.waitUntilFirstIntentIsSuspended()
  fixture.store.setVolumeBoost(2, for: app)
  #expect(fixture.store.trackedAppIntentTaskCount == 2)

  let shutdown = Task { @MainActor in await fixture.store.shutdown() }
  await Task.yield()
  await Task.yield()
  #expect(fixture.store.startupState == .shuttingDown)
  #expect(fixture.store.shutdownResult == nil)
  #expect(fixture.store.trackedAppIntentTaskCount > 0)

  await fixture.backend.resumeFirstIntent()
  _ = await shutdown.value
  #expect(fixture.store.trackedAppIntentTaskCount == 0)
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func concurrentPersistenceFailuresRestoreLastActuallySavedIntent() async {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baseline,
    preset: AppVolumeSettings(
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost
    )
  )
  fixture.preferencesStore.configureFailingSaves(count: 2, suspendFirst: true)

  fixture.store.setMuted(true, for: app)
  await fixture.preferencesStore.waitUntilFirstSaveIsSuspended()
  fixture.store.setVolumeBoost(3, for: app)
  let drain = Task { @MainActor in await fixture.store.drainAppIntentTransactions() }
  await Task.yield()
  #expect(fixture.store.trackedAppIntentTaskCount == 2)
  fixture.preferencesStore.resumeFirstSave()
  await drain.value
  await waitUntil { fixture.store.persistenceFailureCount == 2 }

  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == baseline)
  #expect(fixture.preferencesStore.value.appAudioIntents[app.logicalID] == baseline)
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.volumeBoost == 3)
}

@MainActor
@Test func mismatchedBackendGenerationClearsProjectionAndTrackedTask() async {
  let app = transactionTestApp()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: baseline,
    resultGenerationOffset: 1
  )

  fixture.store.setMuted(true, for: app)
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.trackedAppIntentTaskCount == 0)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == baseline)
}

@MainActor
@Test func sliderTicksStayTransientUntilCommit() async {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baseline,
    preset: AppVolumeSettings(
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost
    )
  )

  fixture.store.setDesiredVolume(0.2, for: app)
  fixture.store.setDesiredVolume(0.3, for: app)

  #expect(fixture.store.session.apps.first?.desiredVolume == 0.3)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == baseline)
  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.presetsStore.saveCount == 0)

  fixture.store.commitDesiredVolume(for: app)
  await fixture.store.drainAppIntentTransactions()

  #expect(await fixture.backend.recordedIntents().count == 1)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.desiredVolume == 0.3)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id)?.desiredVolume == 0.3
  )
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(fixture.presetsStore.saveCount == 1)
}

@MainActor
@Test func ordinaryRefreshPreservesAutoConferencingProvenanceWithoutDurableProjection() async {
  var cachedApp = transactionTestApp(desiredVolume: 0.25, isMuted: true)
  cachedApp.muteSource = .autoConferencing
  var liveApp = transactionTestApp(desiredVolume: 0.72, isMuted: true)
  liveApp.muteSource = .user
  let durable = PersistedAppAudioIntent(
    appID: cachedApp.logicalID,
    desiredVolume: 0.95,
    isMuted: false,
    volumeBoost: 1,
    targetDeviceUID: "device.durable"
  )
  let fixture = makeTransactionFixture(
    apps: [cachedApp],
    device: transactionTestDevice(),
    intent: durable,
    refreshApps: [liveApp]
  )

  fixture.store.refresh(announce: false)
  await waitForRefresh(fixture.store)

  let refreshed = fixture.store.session.apps.first
  #expect(refreshed?.desiredVolume == 0.72)
  #expect(refreshed?.isMuted == true)
  #expect(refreshed?.muteSource == .autoConferencing)
  #expect(refreshed?.targetDeviceUID == liveApp.targetDeviceUID)
  #expect(await fixture.backend.recordedIntents().isEmpty)
}

@MainActor
@Test func ordinaryRefreshKeepsLiveDevicePresetStateAuthoritative() async {
  let device = transactionTestDevice()
  let cached = transactionTestApp(desiredVolume: 0.8, isMuted: false, volumeBoost: 2)
  let livePresetState = transactionTestApp(desiredVolume: 0.22, isMuted: true, volumeBoost: 3)
  let durable = PersistedAppAudioIntent(
    appID: cached.logicalID,
    desiredVolume: 0.8,
    isMuted: false,
    volumeBoost: 2
  )
  let fixture = makeTransactionFixture(
    apps: [cached],
    device: device,
    intent: durable,
    preset: AppVolumeSettings(desiredVolume: 0.22, isMuted: true, volumeBoost: 3),
    refreshApps: [livePresetState]
  )

  fixture.store.refresh(announce: false)
  await waitForRefresh(fixture.store)

  let refreshed = fixture.store.session.apps.first
  #expect(refreshed?.desiredVolume == 0.22)
  #expect(refreshed?.isMuted == true)
  #expect(refreshed?.volumeBoost == 3)
  #expect(await fixture.backend.recordedIntents().isEmpty)
}

@MainActor
@Test func excludedAppSkipsStartupAndRefreshRestoreThenReincludeRestoresRetainedIntent() async {
  let app = transactionTestApp(desiredVolume: 0.4, isMuted: false, volumeBoost: 2)
  let device = transactionTestDevice()
  let equalizer = EqualizerSettings(isEnabled: true, adaptiveRole: .voice)
  let durable = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: 0.6,
    isMuted: false,
    volumeBoost: 2.5,
    equalizerSettings: equalizer,
    targetDeviceUID: "device.routed"
  )
  let preset = AppVolumeSettings(desiredVolume: 0.18, isMuted: true, volumeBoost: 3.25)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: durable,
    preset: preset,
    excluded: true,
    refreshApps: [app],
    initialStartupState: .idle
  )

  fixture.store.start()
  await waitUntil { await fixture.backend.diagnosticsCallCount() > 0 }
  #expect(await fixture.backend.recordedIntents().isEmpty)

  fixture.store.refresh(announce: false)
  await waitForRefresh(fixture.store)
  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(fixture.store.session.apps.first?.routingState == .monitorOnly)
  #expect(fixture.store.session.apps.first?.desiredVolume == 1)
  #expect(fixture.store.session.apps.first?.isMuted == false)

  fixture.store.setExcluded(false, for: app)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  let restored = intents.last
  #expect(intents.count == 1)
  #expect(restored?.reason == .routeRecovery)
  #expect(restored?.desiredVolume == preset.desiredVolume)
  #expect(restored?.isMuted == preset.isMuted)
  #expect(restored?.volumeBoost == preset.volumeBoost)
  #expect(restored?.equalizerSettings == equalizer)
  #expect(restored?.targetDeviceUID == durable.targetDeviceUID)
  #expect(restored?.isExcluded == false)
  #expect(fixture.store.session.apps.first?.routingState == .managed)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == durable)
  _ = await fixture.store.shutdown()
}

@MainActor
@Test func newlyAppearingConfiguredAppRestoresDurableIntentWithCurrentDeviceOverlay() async {
  let device = transactionTestDevice()
  let newApp = transactionTestApp(
    id: "new.app",
    desiredVolume: 1,
    isMuted: false,
    volumeBoost: 1,
    targetDeviceUID: nil
  )
  let equalizer = EqualizerSettings(isEnabled: true, adaptiveRole: .media)
  let durable = PersistedAppAudioIntent(
    appID: newApp.logicalID,
    desiredVolume: 0.74,
    isMuted: false,
    volumeBoost: 1.5,
    equalizerSettings: equalizer,
    targetDeviceUID: "device.per-app"
  )
  let preset = AppVolumeSettings(desiredVolume: 0.31, isMuted: true, volumeBoost: 3)
  let fixture = makeTransactionFixture(
    apps: [],
    device: device,
    extraIntents: [newApp.logicalID: durable],
    extraPresets: [newApp.logicalID: preset],
    refreshApps: [newApp]
  )

  fixture.store.refresh(announce: false)
  await waitForRefresh(fixture.store)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  let restored = intents.first
  #expect(intents.count == 1)
  #expect(restored?.reason == .devicePresetRestore)
  #expect(restored?.desiredVolume == preset.desiredVolume)
  #expect(restored?.isMuted == preset.isMuted)
  #expect(restored?.volumeBoost == preset.volumeBoost)
  #expect(restored?.equalizerSettings == equalizer)
  #expect(restored?.targetDeviceUID == durable.targetDeviceUID)
  #expect(fixture.store.session.apps.first?.routingState == .managed)
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.presetsStore.saveCount == 0)
}

@MainActor
@Test func preferencePersistenceFailureKeepsRuntimeSuccessButRestoresPriorDurableState() async {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baseline,
    preset: AppVolumeSettings(
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost
    )
  )
  fixture.preferencesStore.saveError = TransactionTestError.writeFailed

  fixture.store.setDesiredVolume(0.19, for: app)
  fixture.store.commitDesiredVolume(for: app)
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.session.apps.first?.desiredVolume == 0.19)
  #expect(fixture.store.session.apps.first?.routingState == .managed)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == baseline)
  #expect(fixture.preferencesStore.value.appAudioIntents[app.logicalID] == baseline)
  #expect(fixture.presetsStore.saveCount == 0)
  #expect(fixture.store.persistenceFailureCount == 1)
  #expect(fixture.store.lastPersistenceError?.contains("settings") == true)
  #expect(fixture.store.toasts.contains { $0.title == "Applied, but could not save" })
}

@MainActor
@Test func devicePresetPersistenceFailureKeepsSavedGenericIntentAndReportsPartialSave() async {
  let app = transactionTestApp()
  let device = transactionTestDevice()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let baselinePreset = AppVolumeSettings(
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baseline,
    preset: baselinePreset
  )
  fixture.presetsStore.saveError = TransactionTestError.writeFailed

  fixture.store.setMuted(true, for: app)
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.isMuted == true)
  #expect(fixture.preferencesStore.value.appAudioIntents[app.logicalID]?.isMuted == true)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id) == baselinePreset
  )
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(fixture.store.persistenceFailureCount == 1)
  #expect(fixture.store.lastPersistenceError?.contains("device presets") == true)
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Applied, but device preset was not saved"
    }
  )
}

@MainActor
@Test func orderedMixedProfileReconcilesRowsPersistsEligibleIntentAndReportsTruthfully() async {
  let device = transactionTestDevice()
  let live = transactionTestApp(id: "profile.live", desiredVolume: 0.4, volumeBoost: 2)
  let excluded = transactionTestApp(id: "profile.excluded", desiredVolume: 0.6, volumeBoost: 1.5)
  let failed = transactionTestApp(id: "profile.failed", desiredVolume: 0.7, volumeBoost: 2.5)
  let membership = transactionTestApp(id: "profile.member", desiredVolume: 0.8, volumeBoost: 1.25)
  let liveIntent = PersistedAppAudioIntent(
    appID: live.logicalID,
    desiredVolume: live.desiredVolume,
    isMuted: live.isMuted,
    volumeBoost: live.volumeBoost
  )
  let excludedIntent = PersistedAppAudioIntent(
    appID: excluded.logicalID,
    desiredVolume: excluded.desiredVolume,
    isMuted: excluded.isMuted,
    volumeBoost: excluded.volumeBoost
  )
  let failedIntent = PersistedAppAudioIntent(
    appID: failed.logicalID,
    desiredVolume: failed.desiredVolume,
    isMuted: failed.isMuted,
    volumeBoost: failed.volumeBoost
  )
  let profile = Profile(
    name: "Mixed truth",
    entries: [
      ProfileEntry(appID: live.logicalID, desiredVolume: 0.21),
      ProfileEntry(appID: "profile.offline", desiredVolume: 0.33, isMuted: true),
      ProfileEntry(appID: excluded.logicalID, volumeBoost: 3),
      ProfileEntry(appID: failed.logicalID, isMuted: true),
      ProfileEntry(appID: membership.logicalID),
    ]
  )
  let fixture = makeTransactionFixture(
    apps: [live, excluded, failed, membership],
    device: device,
    intent: liveIntent,
    preset: AppVolumeSettings(
      desiredVolume: live.desiredVolume,
      isMuted: live.isMuted,
      volumeBoost: live.volumeBoost
    ),
    extraIntents: [
      excluded.logicalID: excludedIntent,
      failed.logicalID: failedIntent,
    ],
    extraPresets: [
      excluded.logicalID: AppVolumeSettings(
        desiredVolume: excluded.desiredVolume,
        isMuted: excluded.isMuted,
        volumeBoost: excluded.volumeBoost
      ),
      failed.logicalID: AppVolumeSettings(
        desiredVolume: failed.desiredVolume,
        isMuted: failed.isMuted,
        volumeBoost: failed.volumeBoost
      ),
    ],
    excludedAppIDs: [excluded.logicalID],
    profileOutcomes: [.applied, .unavailable, .failed]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  let calls = await fixture.backend.recordedProfileCalls()
  #expect(calls.count == 1)
  #expect(calls.first?.profile.entries.map(\.appID) == profile.entries.map(\.appID))
  #expect(calls.first?.profile.entries[2].hasLevels == false)
  let result = try? #require(fixture.store.lastProfileApplyResult)
  #expect(result?.rows.map(\.entryIndex) == [0, 1, 2, 3, 4])
  #expect(result?.rows.map(\.appID) == profile.entries.map(\.appID))
  #expect(
    result?.rows.map(\.outcome) == [
      .applied,
      .unavailable,
      .excluded,
      .failed,
      .membershipOnly,
    ])
  #expect(result?.rows.allSatisfy { $0.generation == calls.first?.generation } == true)

  #expect(fixture.store.session.apps.first { $0.logicalID == live.logicalID }?.desiredVolume == 0.21)
  #expect(fixture.store.preferences.appAudioIntents[live.logicalID]?.desiredVolume == 0.21)
  #expect(fixture.store.preferences.appAudioIntents[live.logicalID]?.volumeBoost == live.volumeBoost)
  #expect(
    fixture.store.preferences.appAudioIntents["profile.offline"]
      == PersistedAppAudioIntent(
        appID: "profile.offline",
        desiredVolume: 0.33,
        isMuted: true,
        volumeBoost: 1
      ))
  #expect(fixture.store.preferences.appAudioIntents[excluded.logicalID] == excludedIntent)
  #expect(fixture.store.preferences.appAudioIntents[failed.logicalID] == failedIntent)
  #expect(fixture.store.preferences.appAudioIntents[membership.logicalID] == nil)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: "profile.offline", deviceID: device.id)
      == AppVolumeSettings(
        desiredVolume: 0.33,
        isMuted: true,
        volumeBoost: 1
      )
  )
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: membership.logicalID, deviceID: device.id) == nil
  )
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(fixture.presetsStore.saveCount == 1)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile applied with errors"
        && $0.detail?.contains("1 saved for later") == true
        && $0.detail?.contains("1 excluded") == true
        && $0.detail?.contains("1 failed") == true
    })
}

@MainActor
@Test func offlineProfileRowWithoutPriorIntentCreatesDurableIntentFromExplicitFields() async {
  let device = transactionTestDevice()
  let fixture = makeTransactionFixture(
    apps: [],
    device: device,
    profileOutcomes: [.unavailable]
  )
  let profile = Profile(
    name: "Later",
    entries: [
      ProfileEntry(appID: "offline.new", desiredVolume: 0.46, volumeBoost: 2.75)
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  #expect(
    fixture.store.preferences.appAudioIntents["offline.new"]
      == PersistedAppAudioIntent(
        appID: "offline.new",
        desiredVolume: 0.46,
        isMuted: false,
        volumeBoost: 2.75
      ))
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: "offline.new", deviceID: device.id)
      == AppVolumeSettings(
        desiredVolume: 0.46,
        isMuted: false,
        volumeBoost: 2.75
      )
  )
  #expect(fixture.preferencesStore.saveCount == 1)
  #expect(fixture.presetsStore.saveCount == 1)
  #expect(fixture.store.toasts.contains { $0.title == "Profile saved for later" })
}

@MainActor
@Test func failedExcludedAndSupersededProfileRowsDoNotPersist() async {
  let device = transactionTestDevice()
  let failed = transactionTestApp(id: "outcome.failed")
  let excluded = transactionTestApp(id: "outcome.excluded", desiredVolume: 0.5)
  let superseded = transactionTestApp(id: "outcome.superseded", desiredVolume: 0.6)
  let failedIntent = PersistedAppAudioIntent(
    appID: failed.logicalID,
    desiredVolume: failed.desiredVolume,
    volumeBoost: failed.volumeBoost
  )
  let excludedIntent = PersistedAppAudioIntent(
    appID: excluded.logicalID,
    desiredVolume: excluded.desiredVolume,
    volumeBoost: excluded.volumeBoost
  )
  let supersededIntent = PersistedAppAudioIntent(
    appID: superseded.logicalID,
    desiredVolume: superseded.desiredVolume,
    volumeBoost: superseded.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [failed, excluded, superseded],
    device: device,
    intent: failedIntent,
    preset: AppVolumeSettings(
      desiredVolume: failed.desiredVolume,
      isMuted: failed.isMuted,
      volumeBoost: failed.volumeBoost
    ),
    extraIntents: [
      excluded.logicalID: excludedIntent,
      superseded.logicalID: supersededIntent,
    ],
    extraPresets: [
      excluded.logicalID: AppVolumeSettings(
        desiredVolume: excluded.desiredVolume,
        isMuted: excluded.isMuted,
        volumeBoost: excluded.volumeBoost
      ),
      superseded.logicalID: AppVolumeSettings(
        desiredVolume: superseded.desiredVolume,
        isMuted: superseded.isMuted,
        volumeBoost: superseded.volumeBoost
      ),
    ],
    excludedAppIDs: [excluded.logicalID],
    profileOutcomes: [.failed, .superseded]
  )
  let beforePreferences = fixture.store.preferences.appAudioIntents
  let beforePresets = fixture.store.deviceVolumePresets.deviceVolumes
  let profile = Profile(
    name: "Rejected",
    entries: [
      ProfileEntry(appID: failed.logicalID, desiredVolume: 0.1),
      ProfileEntry(appID: excluded.logicalID, desiredVolume: 0.2),
      ProfileEntry(appID: superseded.logicalID, desiredVolume: 0.3),
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  #expect(
    fixture.store.lastProfileApplyResult?.rows.map(\.outcome) == [
      .failed,
      .excluded,
      .superseded,
    ])
  #expect(fixture.store.preferences.appAudioIntents == beforePreferences)
  #expect(fixture.store.deviceVolumePresets.deviceVolumes == beforePresets)
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.presetsStore.saveCount == 0)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
}

@MainActor
@Test func unavailableProfilePartialResultNeverShowsFullSuccessToast() async {
  let live = transactionTestApp(id: "partial.live")
  let fixture = makeTransactionFixture(
    apps: [live],
    device: transactionTestDevice(),
    profileOutcomes: [.applied, .unavailable]
  )
  let profile = Profile(
    name: "Partial",
    entries: [
      ProfileEntry(appID: live.logicalID, desiredVolume: 0.2),
      ProfileEntry(appID: "partial.offline", isMuted: true),
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile partly applied"
        && $0.detail?.contains("1 applied") == true
        && $0.detail?.contains("1 saved for later") == true
    })
}

@MainActor
@Test func successfulProfileUsesConfirmedCompleteStateForOmittedFields() async {
  let app = transactionTestApp(
    id: "profile.confirmed",
    desiredVolume: 0.4,
    isMuted: false,
    volumeBoost: 2,
    targetDeviceUID: "device.runtime"
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: 0.9,
      isMuted: false,
      volumeBoost: 4,
      targetDeviceUID: "device.stale"
    ),
    profileOutcomes: [.applied]
  )

  fixture.store.applyProfile(
    Profile(
      name: "Confirmed",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2, isMuted: true)]
    ))
  await fixture.store.drainAppIntentTransactions()

  let durable = fixture.store.preferences.appAudioIntents[app.logicalID]
  #expect(durable?.desiredVolume == 0.2)
  #expect(durable?.isMuted == true)
  #expect(durable?.volumeBoost == app.volumeBoost)
  #expect(durable?.targetDeviceUID == app.targetDeviceUID)
  #expect(fixture.store.session.apps.first?.muteSource == .user)
}

@MainActor
@Test func profileWhileAutoMutedDoesNotPersistAutomaticMute() async {
  let app = transactionTestApp(id: "profile.auto-muted")
  let device = transactionTestDevice()
  let durable = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let preset = AppVolumeSettings(
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: durable,
    preset: preset,
    profileOutcomes: [.applied]
  )

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  fixture.store.applyProfile(
    Profile(
      name: "Volume only",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.24)]
    ))
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.desiredVolume == 0.24)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.isMuted == false)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id)?.isMuted == false
  )

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)
  #expect(fixture.store.session.apps.first?.isMuted == false)
}

@MainActor
@Test func aProfileUnmuteThatFailsLeavesACallMuteForTheCallsEndToRelease() async {
  let app = transactionTestApp(id: "profile.failed-unmute")
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: false,
      volumeBoost: app.volumeBoost
    ),
    profileOutcomes: [.failed]
  )

  // A call mutes the app; a profile asks to unmute it, and its row fails.
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  fixture.store.applyProfile(
    Profile(name: "Unmute", entries: [ProfileEntry(appID: app.logicalID, isMuted: false)])
  )
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.lastProfileApplyResult?.rows.map(\.outcome) == [.failed])
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)
  #expect(fixture.store.appIntentCoordinator.ownsAutomaticMute(for: app.logicalID))

  // The call ends: the mute the call made is released.
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)
  #expect(fixture.store.session.apps.first?.isMuted == false)
}

@MainActor
@Test func olderDirectTransactionCannotOverwriteLaterProfile() async {
  let app = transactionTestApp(id: "race.old-direct")
  let device = transactionTestDevice()
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: baseline,
    preset: AppVolumeSettings(
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost
    ),
    outcomes: [.applied],
    profileOutcomes: [.applied],
    suspendFirstIntent: true
  )

  fixture.store.setDesiredVolume(0.1, for: app)
  fixture.store.commitDesiredVolume(for: app)
  await fixture.backend.waitUntilFirstIntentIsSuspended()
  fixture.store.applyProfile(
    Profile(
      name: "Newer profile",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.72)]
    ))
  await waitUntil { fixture.store.lastProfileApplyResult != nil }
  await fixture.backend.resumeFirstIntent()
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  let profiles = await fixture.backend.recordedProfileCalls()
  #expect(intents.first?.generation ?? 0 < profiles.first?.generation ?? 0)
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.72)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.desiredVolume == 0.72)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id)?.desiredVolume == 0.72
  )
}

@MainActor
@Test func laterDirectEditSupersedesInFlightProfileForThatApp() async {
  let app = transactionTestApp(id: "race.new-direct")
  let baseline = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: baseline,
    profileOutcomes: [.applied],
    suspendFirstProfile: true
  )

  fixture.store.applyProfile(
    Profile(
      name: "Older profile",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2)]
    ))
  await fixture.backend.waitUntilFirstProfileIsSuspended()
  fixture.store.setVolumeBoost(3, for: app)
  await waitUntil {
    fixture.store.preferences.appAudioIntents[app.logicalID]?.volumeBoost == 3
  }
  await fixture.backend.resumeFirstProfile()
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  let profiles = await fixture.backend.recordedProfileCalls()
  #expect(profiles.first?.generation ?? 0 < intents.first?.generation ?? 0)
  #expect(fixture.store.lastProfileApplyResult?.rows.map(\.outcome) == [.superseded])
  #expect(fixture.store.session.apps.first?.desiredVolume == app.desiredVolume)
  #expect(fixture.store.session.apps.first?.volumeBoost == 3)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.desiredVolume == app.desiredVolume)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.volumeBoost == 3)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
}

@MainActor
@Test func profileSuccessFeedbackWaitsForDurableSaves() async {
  let app = transactionTestApp(id: "profile.await-save")
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost
    ),
    profileOutcomes: [.applied]
  )
  fixture.preferencesStore.configureFailingSaves(count: 0, suspendFirst: true)

  fixture.store.applyProfile(
    Profile(
      name: "Await save",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.27)]
    ))
  await fixture.preferencesStore.waitUntilFirstSaveIsSuspended()

  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  fixture.preferencesStore.resumeFirstSave()
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.toasts.contains { $0.title == "Profile applied" })
}

@MainActor
@Test func profilePersistenceFailuresRollbackOnlyDurableSnapshots() async {
  let app = transactionTestApp(id: "profile.save-failure")
  let device = transactionTestDevice()
  let durable = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let preset = AppVolumeSettings(
    desiredVolume: app.desiredVolume,
    isMuted: app.isMuted,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: durable,
    preset: preset,
    profileOutcomes: [.applied]
  )
  fixture.preferencesStore.saveError = TransactionTestError.writeFailed
  fixture.presetsStore.saveError = TransactionTestError.writeFailed

  fixture.store.applyProfile(
    Profile(
      name: "Save failure",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.19, isMuted: true)]
    ))
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.session.apps.first?.desiredVolume == 0.19)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == durable)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id) == preset
  )
  #expect(fixture.store.persistenceFailureCount == 2)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile applied with errors"
        && $0.detail?.contains("settings not saved") == true
        && $0.detail?.contains("device preset not saved") == true
    })
}

@MainActor
@Test func capturingLevelsDuringAnAutomaticMuteSavesTheUsersOwnMuteState() async {
  let app = transactionTestApp(id: "automation.capture", desiredVolume: 0.38)
  let device = transactionTestDevice()
  let durable = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(apps: [app], device: device, intent: durable)

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)

  // "Capture current levels" while the call has the app muted.
  let saveResult = fixture.store.saveProfile(named: "During call", appIDs: [app.logicalID], captureLevels: true)
  guard case .saved(let savedID) = saveResult else {
    Issue.record("expected the profile to save, got \(saveResult)")
    return
  }
  let captured = fixture.store.profiles.first { $0.id == savedID }?.entries.first
  #expect(captured?.desiredVolume == 0.38)
  #expect(captured?.isMuted == false)

  // Applying a level-carrying profile takes the Reset Mix restore point.
  fixture.store.applyProfile(
    Profile(name: "Quiet", entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2)])
  )
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.mixRestorePoint?.entries.first?.isMuted == false)

  // Reset Mix while the call is still on: the level comes back, the automatic
  // mute stays and is still owned by call automation, and nothing durable
  // records a mute.
  fixture.store.resetMix()
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.38)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.isMuted == false)

  // The call ends and automation resumes the app.
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)
  #expect(fixture.store.session.apps.first?.isMuted == false)
  #expect(fixture.store.session.apps.first?.muteSource == .user)
}

@MainActor
@Test func automaticMuteSurvivesRefreshNeverPersistsAndResumes() async {
  let app = transactionTestApp(id: "automation.refresh", desiredVolume: 0.38)
  let device = transactionTestDevice()
  let durable = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let preset = AppVolumeSettings(
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: durable,
    preset: preset
  )

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == durable)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id) == preset
  )

  fixture.store.refresh(announce: false, reevaluateAutomation: false)
  await waitForRefresh(fixture.store)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == durable)

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)
  #expect(fixture.store.session.apps.first?.isMuted == false)
  #expect(fixture.store.session.apps.first?.muteSource == .user)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == durable)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id) == preset
  )
  let intents = await fixture.backend.recordedIntents()
  #expect(intents.map(\.reason) == [.automation, .automation])
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.presetsStore.saveCount == 0)
}

@MainActor
@Test func userUnmuteAfterAutomaticMutePreventsAnotherAutoResume() async {
  let app = transactionTestApp(id: "automation.user")
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: false,
      volumeBoost: app.volumeBoost
    )
  )

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  let autoMutedApp = try? #require(fixture.store.session.apps.first)
  if let autoMutedApp {
    fixture.store.setMuted(false, for: autoMutedApp)
  }
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.map(\.reason) == [.automation, .userEdit])
  #expect(fixture.store.session.apps.first?.isMuted == false)
  #expect(fixture.store.session.apps.first?.muteSource == .user)
}

@MainActor
@Test(arguments: [true, false])
func rejectedURLMutePreservesAutomaticResume(isMuted: Bool) async {
  let app = transactionTestApp(id: "automation.rejected-url")
  let fixture = makeTransactionFixture(
    apps: [app], device: transactionTestDevice(), outcomes: [.applied, .failed, .applied]
  )
  fixture.store.preferences.enableURLScheme = true
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  #expect(fixture.store.appIntentCoordinator.ownsAutomaticMute(for: app.logicalID))

  fixture.store.handleURLScheme(URL(string: "waves://mute?app=\(app.logicalID)&muted=\(isMuted)")!)
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)
  #expect(fixture.store.appIntentCoordinator.ownsAutomaticMute(for: app.logicalID))

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)
  #expect(fixture.store.session.apps.first?.isMuted == false)
  #expect(await fixture.backend.recordedIntents().count == 3)
  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test(arguments: [true, false])
func acceptedURLMuteReplacesAutomaticMuteOwnership(isMuted: Bool) async {
  let app = transactionTestApp(id: "automation.accepted-url")
  let fixture = makeTransactionFixture(apps: [app], device: transactionTestDevice())
  fixture.store.preferences.enableURLScheme = true
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  #expect(fixture.store.appIntentCoordinator.ownsAutomaticMute(for: app.logicalID))

  fixture.store.handleURLScheme(URL(string: "waves://mute?app=\(app.logicalID)&muted=\(isMuted)")!)
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.session.apps.first?.isMuted == isMuted)
  #expect(fixture.store.session.apps.first?.muteSource == .user)
  #expect(!fixture.store.appIntentCoordinator.ownsAutomaticMute(for: app.logicalID))
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.isMuted == isMuted)

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: false)
  #expect(fixture.store.session.apps.first?.isMuted == isMuted)
  #expect(await fixture.backend.recordedIntents().count == 2)
  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func failedAutomaticMuteLeavesBackendAndUITruthful() async {
  let app = transactionTestApp(id: "automation.failed")
  let device = transactionTestDevice()
  let durable = PersistedAppAudioIntent(
    appID: app.logicalID,
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let preset = AppVolumeSettings(
    desiredVolume: app.desiredVolume,
    isMuted: false,
    volumeBoost: app.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: device,
    intent: durable,
    preset: preset,
    outcomes: [.failed]
  )

  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)

  #expect(fixture.store.session.apps.first?.isMuted == false)
  #expect(fixture.store.session.apps.first?.muteSource == .user)
  #expect(fixture.store.session.apps.first?.routingState == .error)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == durable)
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: app.logicalID, deviceID: device.id) == preset
  )
  #expect(fixture.preferencesStore.saveCount == 0)
  #expect(fixture.presetsStore.saveCount == 0)
  #expect(!fixture.store.toasts.contains { $0.title == "Muted for your call" })
}

@MainActor
@Test func supersededAutomaticMuteCannotClaimOwnershipOrResumeUserMute() async {
  let app = transactionTestApp(id: "automation.superseded")
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: false,
      volumeBoost: app.volumeBoost
    ),
    suspendFirstIntent: true
  )

  let automatic = Task { @MainActor in
    await fixture.store.applyAutomaticConferencingTransition(
      isConferencingActive: true
    )
  }
  await fixture.backend.waitUntilFirstIntentIsSuspended()
  fixture.store.setMuted(true, for: app)
  let drain = Task { @MainActor in await fixture.store.drainAppIntentTransactions() }
  await Task.yield()
  #expect(fixture.store.trackedAppIntentTaskCount == 2)
  await fixture.backend.resumeFirstIntent()
  await drain.value
  await automatic.value

  await fixture.store.applyAutomaticConferencingTransition(
    isConferencingActive: false
  )
  #expect(await fixture.backend.recordedIntents().map(\.reason) == [.automation, .userEdit])
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.session.apps.first?.muteSource == .user)

  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func relaunchDoesNotResurrectAutomaticMuteOwnershipOrDurableMute() async {
  let appID = "automation.relaunch"
  var cachedApp = transactionTestApp(id: appID, isMuted: true)
  cachedApp.muteSource = .autoConferencing
  let durable = PersistedAppAudioIntent(
    appID: appID,
    desiredVolume: cachedApp.desiredVolume,
    isMuted: false,
    volumeBoost: cachedApp.volumeBoost
  )
  let fixture = makeTransactionFixture(
    apps: [cachedApp],
    device: transactionTestDevice(),
    intent: durable
  )

  await fixture.store.applyAutomaticConferencingTransition(
    isConferencingActive: false
  )

  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(fixture.store.preferences.appAudioIntents[appID]?.isMuted == false)
  #expect(fixture.store.session.apps.first?.muteSource == .autoConferencing)

  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

// MARK: - Microphone call detection

/// Stands in for Core Audio: the test decides which processes run input.
@MainActor
private final class FakeMicrophoneActivityMonitor: MicrophoneActivityMonitoring {
  private var onChange: (@MainActor () -> Void)?
  private(set) var startCount = 0
  var captures: [MicrophoneCaptureProcess] = []

  var isRunning: Bool { onChange != nil }

  func start(onChange: @escaping @MainActor () -> Void) {
    guard self.onChange == nil else { return }
    startCount += 1
    self.onChange = onChange
  }

  func stop() { onChange = nil }

  func capturingProcesses() -> [MicrophoneCaptureProcess] {
    isRunning ? captures : []
  }

  func emit(_ captures: [MicrophoneCaptureProcess]) {
    self.captures = captures
    onChange?()
  }
}

/// The call-end hold, released only when the test says so.
@MainActor
private final class ManualHoldClock {
  private(set) var requested: [Duration] = []
  private var liveWaiters = 0
  private var generation = 0

  nonisolated var sleep: @Sendable (Duration) async throws -> Void {
    { [self] duration in try await self.wait(duration) }
  }

  private func wait(_ duration: Duration) async throws {
    requested.append(duration)
    let started = generation
    liveWaiters += 1
    defer { liveWaiters -= 1 }
    while generation == started {
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  /// Waits (up to about two seconds) for a hold to be waiting, then lets it
  /// expire. Records an issue instead of hanging when no hold ever starts.
  func expire() async {
    for _ in 0..<1_000 where liveWaiters == 0 {
      try? await Task.sleep(for: .milliseconds(2))
    }
    guard liveWaiters > 0 else {
      Issue.record("No call-end hold was waiting")
      return
    }
    generation += 1
  }
}

private func callTestApp(
  id: String,
  pid: Int32,
  category: AppCategory,
  displayName: String,
  isMuted: Bool = false,
  runtimeIdentity: AppRuntimeIdentity? = nil
) -> AudioApp {
  AudioApp(
    id: "\(id).runtime",
    logicalID: id,
    pid: pid,
    bundleID: id,
    displayName: displayName,
    category: category,
    isActive: true,
    desiredVolume: 0.5,
    appliedVolume: isMuted ? 0 : 0.5,
    isMuted: isMuted,
    routingState: .managed,
    compatibility: .supported,
    targetDeviceUID: "device.original",
    runtimeIdentity: runtimeIdentity
  )
}

/// A helper process inside the call app's bundle, as a browser or Electron app
/// captures the microphone from.
private let callHelperCapture = MicrophoneCaptureProcess(
  pid: 9_001,
  reportedBundleID: "com.example.call.helper",
  owningAppBundlePath: "/Applications/Call.app",
  owningAppBundleID: "com.example.call"
)

@MainActor
private func makeMicrophoneCallFixture(
  apps: [AudioApp]? = nil,
  chosenAppIDs: [String] = ["com.example.call"]
) -> (fixture: TransactionFixture, monitor: FakeMicrophoneActivityMonitor, clock: ManualHoldClock) {
  let monitor = FakeMicrophoneActivityMonitor()
  let clock = ManualHoldClock()
  let fixture = makeTransactionFixture(
    apps: apps ?? [
      callTestApp(id: "com.example.music", pid: 10, category: .media, displayName: "Music Player"),
      // A call app Waves happens to class as media must still never be muted.
      callTestApp(id: "com.example.call", pid: 20, category: .media, displayName: "Call"),
    ],
    device: transactionTestDevice(),
    microphoneActivityMonitor: monitor,
    callEndHoldSleep: clock.sleep
  )
  fixture.store.preferences.autoPauseMusicForConferencing = true
  fixture.store.preferences.callDetectionMode = .microphoneInUse
  fixture.store.preferences.callDetectionAppIDs = chosenAppIDs
  return (fixture, monitor, clock)
}

@MainActor
private func settleCallDetection(_ store: AppStore) async {
  await store.drainOwnedOperations()
  await store.drainAppIntentTransactions()
}

@MainActor
private func muteState(_ store: AppStore, _ appID: String) -> (isMuted: Bool, source: MuteSource)? {
  store.session.apps.first { $0.logicalID == appID }.map { ($0.isMuted, $0.muteSource) }
}

@MainActor
@Test func microphoneModeDoesNothingUntilChosenAndNeverRunsWhileOff() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  store.preferences.callDetectionMode = .frontmostCallApp
  store.checkAutoPauseMusic()
  #expect(monitor.startCount == 0)
  store.preferences.callDetectionMode = .microphoneInUse
  store.preferences.autoPauseMusicForConferencing = false
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(monitor.startCount == 0)
  #expect(!monitor.isRunning)
  _ = await store.shutdown()
}

@MainActor
@Test func microphoneCallMutesMediaButNeverTheCallApp() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)

  #expect(monitor.isRunning)
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  #expect(muteState(store, "com.example.music")?.source == .autoConferencing)
  #expect(muteState(store, "com.example.call")?.isMuted == false)
  // Not muted and then unmuted again: the call app is never touched.
  #expect(await fixture.backend.recordedIntents().count == 1)
  #expect(store.toasts.contains { $0.title == "Muted for your call" })
  #expect(!store.toasts.contains { $0.title.contains("paused") })
  // Automation is never saved as the user's own mute.
  #expect(store.preferences.appAudioIntents["com.example.music"]?.isMuted != true)
  _ = await store.shutdown()
}

@MainActor
@Test func aCallAppMutedEarlierByAutomationIsUnmutedWhenItsCallStarts() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  // An automatic mute from the other mode caught the media-category call app.
  await store.applyAutomaticConferencingTransition(isConferencingActive: true)
  #expect(muteState(store, "com.example.call")?.isMuted == true)

  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.call")?.isMuted == false)
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  #expect(muteState(store, "com.example.music")?.source == .autoConferencing)
  _ = await store.shutdown()
}

@MainActor
@Test func addingAMutedAppToTheCallAppsDuringACallUnmutesOnlyThatApp() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  // The user takes calls in this app too. It must not stay muted until the
  // call that is already running ends.
  store.setCallDetectionApp("com.example.music", isChosen: true)
  await settleCallDetection(store)

  #expect(muteState(store, "com.example.music")?.isMuted == false)
  #expect(muteState(store, "com.example.music")?.source == .user)
  #expect(muteState(store, "com.example.call")?.isMuted == false)
  _ = await store.shutdown()
}

@MainActor
@Test func aCallMuteThatLandedWithoutConfirmationIsStillReleasedWhenTheCallEnds() async {
  let (fixture, monitor, clock) = makeMicrophoneCallFixture()
  let store = fixture.store
  // The router mutes the app but does not confirm the rest of the request.
  await fixture.backend.failIntentsButApplyMute(for: ["com.example.music"])
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  #expect(muteState(store, "com.example.music")?.source == .autoConferencing)

  // It is Waves's mute, not the user's, so it is not captured as theirs.
  let music = store.session.apps.first { $0.logicalID == "com.example.music" }
  #expect(music.map(store.userMute(for:)) == false)

  await fixture.backend.failIntentsButApplyMute(for: [])
  monitor.emit([])
  let hold = store.microphoneCall.endHoldTask
  await clock.expire()
  await hold?.value
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == false)
  _ = await store.shutdown()
}

@MainActor
@Test func aBoostChangeDuringACallDoesNotSaveTheAutomaticMute() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.source == .autoConferencing)

  // A boost change (from the mixer, the socket or a link) during the call.
  let music = store.session.apps.first { $0.logicalID == "com.example.music" }!
  _ = await store.setVolumeBoost(2, for: music, reason: .automation)?.value
  await settleCallDetection(store)
  await store.drainPersistenceTasks()

  let durable = store.preferences.appAudioIntents["com.example.music"]
  #expect(durable?.volumeBoost == 2)
  #expect(durable?.isMuted == false)
  let preset = store.deviceVolumePresets.getVolumeSettings(
    for: "com.example.music", deviceID: transactionTestDevice().id)
  #expect(preset?.isMuted != true)
  // The call's mute itself is untouched.
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  _ = await store.shutdown()
}

@MainActor
@Test func aMediaAppThatAppearsDuringACallIsMutedWithoutRemutingAManualUnmute() async {
  let music = callTestApp(id: "com.example.music", pid: 10, category: .media, displayName: "Music Player")
  let call = callTestApp(id: "com.example.call", pid: 20, category: .conferencing, displayName: "Call")
  let video = callTestApp(id: "com.example.video", pid: 30, category: .media, displayName: "Video")
  let monitor = FakeMicrophoneActivityMonitor()
  let clock = ManualHoldClock()
  let fixture = makeTransactionFixture(
    apps: [music, call],
    device: transactionTestDevice(),
    refreshApps: [music, call, video],
    microphoneActivityMonitor: monitor,
    callEndHoldSleep: clock.sleep
  )
  let store = fixture.store
  store.preferences.autoPauseMusicForConferencing = true
  store.preferences.callDetectionMode = .microphoneInUse
  store.preferences.callDetectionAppIDs = ["com.example.call"]

  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  // The user unmutes the music by hand, then another media app starts.
  store.setMuted(false, for: store.session.apps.first { $0.logicalID == "com.example.music" }!)
  await settleCallDetection(store)
  store.refresh()
  await settleCallDetection(store)
  store.checkAutoPauseMusic()
  await settleCallDetection(store)

  #expect(muteState(store, "com.example.video")?.isMuted == true)
  #expect(muteState(store, "com.example.video")?.source == .autoConferencing)
  #expect(muteState(store, "com.example.music")?.isMuted == false)
  _ = await store.shutdown()
}

@MainActor
@Test func microphoneCallIgnoresAppsThatWereNotChosen() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture(chosenAppIDs: ["com.example.other"])
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == false)
  #expect(await fixture.backend.recordedIntents().isEmpty)
  _ = await store.shutdown()
}

@MainActor
@Test func microphoneHelperResolvesToItsAppThroughTheOuterBundle() {
  var identity = AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(pid: 30, startTimeSeconds: 1, startTimeMicroseconds: 0),
    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
    outerBundlePath: "/Applications/Browser.app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.browser",
      teamIdentifier: "TEAM",
      designatedRequirement: "identifier \"com.example.browser\"",
      codeDirectoryHash: Data([1])
    )
  )
  let browser = callTestApp(
    id: "name-browser", pid: 30, category: .browser, displayName: "Browser", runtimeIdentity: identity)
  // A helper with no bundle ID of its own, matched only by its outer `.app`.
  let helper = MicrophoneCaptureProcess(
    pid: 31, reportedBundleID: nil, owningAppBundlePath: "/Applications/Browser.app", owningAppBundleID: nil)
  #expect(
    CallDetectionPolicy.callingAppIDs(captures: [helper], chosenAppIDs: ["name-browser"], apps: [browser])
      == ["name-browser"])
  identity = AppRuntimeIdentity(
    lifetime: identity.lifetime,
    executablePath: "/Applications/Other.app/Contents/MacOS/Other",
    outerBundlePath: "/Applications/Other.app",
    signingIdentity: identity.signingIdentity
  )
  let other = callTestApp(
    id: "name-browser", pid: 30, category: .browser, displayName: "Browser", runtimeIdentity: identity)
  #expect(
    CallDetectionPolicy.callingAppIDs(captures: [helper], chosenAppIDs: ["name-browser"], apps: [other])
      .isEmpty)
  // The app's own process, by PID.
  let own = MicrophoneCaptureProcess(pid: 30, reportedBundleID: nil, owningAppBundlePath: nil, owningAppBundleID: nil)
  #expect(
    CallDetectionPolicy.callingAppIDs(captures: [own], chosenAppIDs: ["name-browser"], apps: [browser])
      == ["name-browser"])
}

@MainActor
@Test func microphoneCallRidesOverABriefReleaseThenUnmutesAfterTheHold() async {
  let (fixture, monitor, clock) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  // The mic closes for a moment and comes back: no unmute.
  monitor.emit([])
  await settleCallDetection(store)
  #expect(store.microphoneCall.endHoldTask != nil)
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  monitor.emit([callHelperCapture])
  await settleCallDetection(store)
  #expect(store.microphoneCall.endHoldTask == nil)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  // The call ends: still muted until the hold expires.
  monitor.emit([])
  let hold = store.microphoneCall.endHoldTask
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  await clock.expire()
  await hold?.value
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == false)
  #expect(muteState(store, "com.example.music")?.source == .user)
  #expect(store.toasts.contains { $0.title == "Unmuted after your call" })
  #expect(clock.requested == [CallDetectionPolicy.callEndHold, CallDetectionPolicy.callEndHold])
  #expect(CallDetectionPolicy.callEndHold == .seconds(2))
  #expect(await fixture.backend.recordedIntents().map(\.reason) == [.automation, .automation])
  _ = await store.shutdown()
}

@MainActor
@Test func userChoicesDuringAMicrophoneCallWin() async {
  let apps = [
    callTestApp(id: "com.example.music", pid: 10, category: .media, displayName: "Music Player"),
    callTestApp(id: "com.example.video", pid: 11, category: .media, displayName: "Video", isMuted: true),
    callTestApp(id: "com.example.call", pid: 20, category: .conferencing, displayName: "Call"),
  ]
  let (fixture, monitor, clock) = makeMicrophoneCallFixture(apps: apps)
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  // The user unmutes the music mid-call; more capture changes in the same call
  // must not mute it again.
  if let music = store.session.apps.first(where: { $0.logicalID == "com.example.music" }) {
    store.setMuted(false, for: music)
  }
  await settleCallDetection(store)
  monitor.emit([callHelperCapture, MicrophoneCaptureProcess(pid: 20)])
  // Refreshes and app switches re-run the automatic pass during a call.
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == false)

  monitor.emit([])
  let hold = store.microphoneCall.endHoldTask
  await clock.expire()
  await hold?.value
  await settleCallDetection(store)
  // The user's own mute from before the call is kept after it.
  #expect(muteState(store, "com.example.video")?.isMuted == true)
  #expect(muteState(store, "com.example.video")?.source == .user)
  #expect(muteState(store, "com.example.music")?.isMuted == false)
  #expect(await fixture.backend.recordedIntents().map(\.reason) == [.automation, .userEdit])
  _ = await store.shutdown()
}

@MainActor
@Test func turningCallMutingOffReleasesMicrophoneMutesAndStopsTheMonitor() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  store.setAutoPauseMusicEnabled(false)
  await settleCallDetection(store)
  #expect(!monitor.isRunning)
  #expect(!store.microphoneCall.isActive)
  #expect(muteState(store, "com.example.music")?.isMuted == false)
  #expect(store.callDetectionDiagnostics == nil)
  _ = await store.shutdown()
}

@MainActor
@Test func changingDetectionModeStopsTheMonitorAndReleasesMutesTheNewModeDoesNotSee() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == true)

  store.setCallDetectionMode(.frontmostCallApp)
  await settleCallDetection(store)
  #expect(!monitor.isRunning)
  #expect(store.preferences.callDetectionMode == .frontmostCallApp)
  // The new mode reads the real frontmost app. Unless a call app happens to be
  // in front on the test machine, it sees no call and releases the mute.
  let front = NSWorkspace.shared.frontmostApplication
  let callAppInFront =
    front.map {
      AppDiscoveryPolicy.inferCategory(bundleID: $0.bundleIdentifier, displayName: $0.localizedName ?? "")
    } == .conferencing
  if !callAppInFront {
    #expect(muteState(store, "com.example.music")?.isMuted == false)
  }
  _ = await store.shutdown()
}

@MainActor
@Test func addingACapturingAppStartsTheCallAtOnce() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture(chosenAppIDs: [])
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  #expect(muteState(store, "com.example.music")?.isMuted == false)

  store.setCallDetectionApp("com.example.call", isChosen: true)
  await settleCallDetection(store)
  #expect(store.preferences.callDetectionAppIDs == ["com.example.call"])
  #expect(muteState(store, "com.example.music")?.isMuted == true)
  #expect(store.callDetectionDiagnostics == CallDetectionDiagnostics(isDetected: true, appNames: ["Call"]))
  _ = await store.shutdown()
}

@MainActor
@Test func shutdownStopsTheMicrophoneMonitorAndTheHold() async {
  let (fixture, monitor, _) = makeMicrophoneCallFixture()
  let store = fixture.store
  monitor.captures = [callHelperCapture]
  store.checkAutoPauseMusic()
  await settleCallDetection(store)
  monitor.emit([])
  #expect(store.microphoneCall.endHoldTask != nil)

  _ = await store.shutdown()
  #expect(!monitor.isRunning)
  #expect(store.microphoneCall.endHoldTask == nil)
  #expect(store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func choosingMicrophoneModeFillsInKnownCallAppsOnce() async {
  let apps = [
    callTestApp(id: "com.example.music", pid: 10, category: .media, displayName: "Music Player"),
    callTestApp(id: "com.example.zoomish", pid: 12, category: .conferencing, displayName: "Zoom"),
    callTestApp(id: "com.example.chat", pid: 13, category: .communication, displayName: "Discord"),
  ]
  let (fixture, _, _) = makeMicrophoneCallFixture(apps: apps)
  let store = fixture.store
  store.preferences.callDetectionMode = .frontmostCallApp
  store.preferences.callDetectionAppIDs = nil
  store.setCallDetectionMode(.microphoneInUse)
  let filled = store.preferences.callDetectionAppIDs ?? []
  #expect(Array(filled.prefix(2)) == ["com.example.zoomish", "com.example.chat"])
  #expect(!filled.contains("com.example.music"))

  // A list the user emptied stays empty when they come back to the mode.
  store.preferences.callDetectionAppIDs = []
  store.setCallDetectionMode(.frontmostCallApp)
  store.setCallDetectionMode(.microphoneInUse)
  #expect(store.preferences.callDetectionAppIDs == [])
  _ = await store.shutdown()
}

@Test func suggestedCallAppsAreSeenCallAppsThenInstalledKnownOnes() {
  let seen = [
    AudioApp(id: "a", logicalID: "us.zoom.xos", displayName: "zoom.us", category: .conferencing),
    AudioApp(id: "b", logicalID: "com.example.music", displayName: "Music", category: .media),
    AudioApp(id: "c", logicalID: "com.example.chat", displayName: "Chat", category: .communication),
  ]
  let suggested = CallDetectionPolicy.suggestedCallAppIDs(
    seenApps: seen,
    isInstalled: { ["us.zoom.xos", "com.hnc.Discord"].contains($0) }
  )
  #expect(suggested == ["us.zoom.xos", "com.example.chat", "com.hnc.Discord"])
  for bundleID in CallDetectionPolicy.knownCallAppBundleIDs {
    let category = AppDiscoveryPolicy.inferCategory(bundleID: bundleID, displayName: "")
    #expect(category == .conferencing || category == .communication, "\(bundleID) is \(category)")
  }
}

@Test func callDetectionPreferencesDefaultToTheFrontmostModeAndRoundTrip() throws {
  let legacy = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
  #expect(legacy.callDetectionMode == .frontmostCallApp)
  #expect(legacy.callDetectionAppIDs == nil)
  #expect(legacy.autoPauseMusicForConferencing)

  var preferences = UserPreferences()
  preferences.callDetectionMode = .microphoneInUse
  preferences.callDetectionAppIDs = ["com.google.Chrome"]
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
  #expect(decoded.callDetectionMode == .microphoneInUse)
  #expect(decoded.callDetectionAppIDs == ["com.google.Chrome"])
}

@MainActor
@Test func disabledURLAutomationNeverInvokesTheAppStoreParser() async {
  let fixture = makeTransactionFixture(
    apps: [transactionTestApp(id: "automation.disabled")],
    device: transactionTestDevice()
  )
  fixture.store.preferences.enableURLScheme = false
  let initialToastCount = fixture.store.toasts.count

  fixture.store.handleURLScheme(URL(string: "waves://refresh")!)

  #expect(fixture.store.automationParserInvocationCount == 0)
  #expect(fixture.store.toasts.count == initialToastCount)
  #expect(await fixture.backend.recordedIntents().isEmpty)

  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func URLProfileAppliesLevelsWithoutGrantingUserRouteAuthority() async {
  let app = transactionTestApp(
    id: "automation.profile",
    desiredVolume: 0.8,
    isMuted: false,
    targetDeviceUID: "device.pinned-output"
  )
  let profile = Profile(
    name: "URL mix",
    entries: [
      ProfileEntry(appID: app.logicalID, desiredVolume: 0.24, isMuted: true)
    ]
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice()
  )
  fixture.store.preferences.enableURLScheme = true
  fixture.store.profiles = [profile]

  fixture.store.handleURLScheme(URL(string: "waves://apply-profile?name=URL%20mix")!)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count == 1)
  #expect(intents.first?.reason == .automation)
  #expect(intents.first?.desiredVolume == 0.24)
  #expect(intents.first?.isMuted == true)
  #expect(intents.first?.targetDeviceUID == "device.pinned-output")
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.24)
  #expect(fixture.store.session.apps.first?.isMuted == true)
  #expect(fixture.store.mixRestorePoint == nil)
  #expect(fixture.store.activeProfileID == nil)

  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func URLProfileUsesWaveLinkWithoutRelocatingSharedApps() async {
  let dedicated = transactionTestApp(
    id: "automation.dedicated",
    desiredVolume: 0.8,
    isMuted: false
  )
  let shared = transactionTestApp(
    id: "automation.shared",
    desiredVolume: 0.7,
    isMuted: false
  )
  let device = transactionTestDevice()
  let snapshot = transactionSnapshot(apps: [dedicated, shared], device: device)
  let waveLink = URLProfileWaveLinkController(sharedAppID: shared.logicalID)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: waveLink
  )
  let profile = Profile(
    name: "Wave Link URL mix",
    entries: [
      ProfileEntry(appID: dedicated.logicalID, desiredVolume: 0.24, isMuted: true),
      ProfileEntry(appID: shared.logicalID, desiredVolume: 0.31, isMuted: true),
    ]
  )
  let preferencesStore = TransactionPreferencesStore()
  preferencesStore.value.hasCompletedPrivacySetup = true
  preferencesStore.value.urlSchemeAutomationAcknowledged = true
  preferencesStore.value.enableURLScheme = true
  preferencesStore.value.appAudioIntentMigrationVersion = 1
  let profilesStore = TransactionProfilesStore()
  profilesStore.value = [profile]
  let sessionStore = TransactionSessionStore()
  sessionStore.value = snapshot
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: profilesStore,
    sessionStore: sessionStore,
    loginItemService: TransactionLoginItemService(),
    deviceVolumePresetsStore: TransactionDevicePresetsStore(),
    initialStartupState: .running
  )

  store.handleURLScheme(URL(string: "waves://apply-profile?name=Wave%20Link%20URL%20mix")!)
  await store.drainAppIntentTransactions()

  let current = store.session.apps
  #expect(current.first { $0.logicalID == dedicated.logicalID }?.desiredVolume == 0.24)
  #expect(current.first { $0.logicalID == dedicated.logicalID }?.isMuted == true)
  #expect(current.first { $0.logicalID == shared.logicalID }?.desiredVolume == 0.7)
  #expect(current.first { $0.logicalID == shared.logicalID }?.isMuted == false)
  #expect(store.lastProfileApplyResult?.rows.map(\.outcome) == [.applied, .failed])
  #expect(await waveLink.requests.map(\.allowsChannelRelocation) == [false, false])
  #expect(await waveLink.moveRequests.isEmpty)

  _ = await store.shutdown()
  #expect(store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test(arguments: ["set-volume", "mute", "unmute"])
func URLLevelCommandsUseWaveLinkWithoutRelocatingSharedApps(command: String) async {
  let initiallyMuted = command == "unmute"
  let dedicated = transactionTestApp(
    id: "automation.dedicated", desiredVolume: 0.8, isMuted: initiallyMuted
  )
  let shared = transactionTestApp(
    id: "automation.shared", desiredVolume: 0.7, isMuted: initiallyMuted
  )
  let device = transactionTestDevice()
  let snapshot = transactionSnapshot(apps: [dedicated, shared], device: device)
  let waveLink = URLProfileWaveLinkController(sharedAppID: shared.logicalID)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    verifiedRouterConflictProvider: { _ in
      VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .unattributableTapFallback,
        detail: "Wave Link owns active Core Audio output.",
        supportsBridgeControl: true
      )
    },
    waveLinkController: waveLink
  )
  let preferencesStore = TransactionPreferencesStore()
  preferencesStore.value.hasCompletedPrivacySetup = true
  preferencesStore.value.urlSchemeAutomationAcknowledged = true
  preferencesStore.value.enableURLScheme = true
  preferencesStore.value.appAudioIntentMigrationVersion = 1
  let sessionStore = TransactionSessionStore()
  sessionStore.value = snapshot
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: TransactionProfilesStore(),
    sessionStore: sessionStore,
    loginItemService: TransactionLoginItemService(),
    deviceVolumePresetsStore: TransactionDevicePresetsStore(),
    initialStartupState: .running
  )

  for app in [dedicated, shared] {
    let url =
      command == "set-volume"
      ? "waves://set-volume?app=\(app.logicalID)&volume=0.24"
      : "waves://mute?app=\(app.logicalID)&muted=\(command == "mute")"
    store.handleURLScheme(URL(string: url)!)
    #expect(!store.appIntentCoordinator.hasPendingVolumeTargets())
    await store.drainAppIntentTransactions()
  }

  let current = store.session.apps
  #expect(current.first { $0.logicalID == dedicated.logicalID }?.desiredVolume == (command == "set-volume" ? 0.24 : 0.8))
  #expect(current.first { $0.logicalID == dedicated.logicalID }?.isMuted == (command == "mute"))
  #expect(current.first { $0.logicalID == shared.logicalID }?.desiredVolume == 0.7)
  #expect(current.first { $0.logicalID == shared.logicalID }?.isMuted == initiallyMuted)
  #expect(await waveLink.requests.map(\.allowsChannelRelocation) == [false, false])
  #expect(await waveLink.moveRequests.isEmpty)

  let dedicatedIntent = store.preferences.appAudioIntents[dedicated.logicalID]
  #expect(dedicatedIntent?.desiredVolume == (command == "set-volume" ? 0.24 : 0.8))
  #expect(dedicatedIntent?.isMuted == (command == "mute"))
  let dedicatedPreset = store.deviceVolumePresets.getVolumeSettings(for: dedicated.logicalID, deviceID: device.id)
  #expect(dedicatedPreset?.desiredVolume == (command == "set-volume" ? 0.24 : 0.8))
  #expect(dedicatedPreset?.isMuted == (command == "mute"))
  #expect(!store.appIntentCoordinator.hasPendingVolumeTargets())

  if command == "set-volume" {
    store.setDesiredVolume(0.24, for: shared)
    store.commitDesiredVolume(for: shared)
  } else {
    store.setMuted(command == "mute", for: shared)
  }
  await store.drainAppIntentTransactions()
  let manuallyControlled = store.session.apps.first { $0.logicalID == shared.logicalID }
  #expect(manuallyControlled?.desiredVolume == (command == "set-volume" ? 0.24 : 0.7))
  #expect(manuallyControlled?.isMuted == (command == "mute"))
  #expect(await waveLink.requests.last?.allowsChannelRelocation == true)
  #expect(await waveLink.moveRequests == [shared.logicalID])

  _ = await store.shutdown()
  #expect(store.lifecycleSnapshot.isIdle)
}

@MainActor
private func assertBaselineState(
  _ store: AppStore,
  app: AudioApp,
  intent: PersistedAppAudioIntent,
  preset: AppVolumeSettings,
  device: AudioDevice
) {
  let current = store.session.apps.first
  #expect(current?.desiredVolume == app.desiredVolume)
  #expect(current?.isMuted == app.isMuted)
  #expect(current?.volumeBoost == app.volumeBoost)
  #expect(current?.targetDeviceUID == app.targetDeviceUID)
  #expect(current?.routingState == .error)
  #expect(store.preferences.appAudioIntents[app.logicalID] == intent)
  #expect(
    store.deviceVolumePresets.getVolumeSettings(for: app.logicalID, deviceID: device.id) == preset
  )
}

@MainActor
private func waitForRefresh(_ store: AppStore) async {
  for _ in 0..<10_000 {
    if !store.isRefreshing { return }
    await Task.yield()
  }
  Issue.record("Timed out waiting for AppStore refresh")
}

@MainActor
@Test func applyingLevelProfileCapturesRestorePointAndResetMixRestoresIt() async {
  let device = transactionTestDevice()
  let app = transactionTestApp(id: "reset.app", desiredVolume: 0.8, volumeBoost: 1)
  let profile = Profile(
    name: "Meeting",
    entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2, isMuted: false)]
  )
  let fixture = makeTransactionFixture(apps: [app], device: device)

  #expect(fixture.store.mixRestorePoint == nil)
  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  // The restore point holds the pre-profile mix for every visible app.
  let restorePoint = try? #require(fixture.store.mixRestorePoint)
  #expect(restorePoint?.profileName == "Meeting")
  #expect(restorePoint?.entries.first?.desiredVolume == 0.8)
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.2)

  // Applying a second level profile keeps the ORIGINAL restore point.
  let second = Profile(
    name: "Focus",
    entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.5)]
  )
  fixture.store.applyProfile(second)
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.mixRestorePoint?.profileName == "Meeting")
  #expect(fixture.store.mixRestorePoint?.entries.first?.desiredVolume == 0.8)

  // Reset returns to the pre-Meeting mix, clears the point and active profile.
  fixture.store.resetMix()
  #expect(!fixture.store.toasts.contains { $0.title == "Mix reset" })
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.toasts.contains { $0.title == "Mix reset" })
  #expect(fixture.store.mixRestorePoint == nil)
  #expect(fixture.store.activeProfileID == nil)
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.8)
  // The synthesized restore profile never lands in the saved profiles list.
  #expect(!fixture.store.profiles.contains { $0.name == "Meeting" && $0.id != profile.id })
}

@MainActor
@Test func failedResetKeepsRestorePointAndActiveProfileForRetry() async {
  let app = transactionTestApp(id: "reset.retry", desiredVolume: 0.8)
  let profile = Profile(
    name: "Meeting",
    entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2)]
  )
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    profileOutcomes: [.applied, .failed]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  fixture.store.resetMix()
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.mixRestorePoint?.profileName == "Meeting")
  #expect(fixture.store.activeProfileID == profile.id)
  #expect(!fixture.store.toasts.contains { $0.title == "Mix reset" })
  #expect(fixture.store.toasts.contains { $0.title == "Some levels didn't reset" })
}

@MainActor
@Test func profileSaveFeedbackWaitsForDiskAndDropsStaleSuccess() async {
  let app = transactionTestApp(id: "profile.durable-save")
  let profilesStore = TransactionProfilesStore()
  profilesStore.suspendFirstSave = true
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    profileStore: profilesStore
  )

  _ = fixture.store.saveProfile(named: "First", appIDs: [app.logicalID], captureLevels: false)
  await profilesStore.waitUntilFirstSaveIsSuspended()
  #expect(!fixture.store.toasts.contains { $0.title == "Profile saved" })

  _ = fixture.store.saveProfile(named: "Second", appIDs: [app.logicalID], captureLevels: false)
  profilesStore.resumeFirstSave()
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }

  #expect(profilesStore.value.map(\.name).contains("Second"))
  #expect(!fixture.store.toasts.contains { $0.title == "Profile saved" && $0.detail == "First" })
  #expect(fixture.store.toasts.contains { $0.title == "Profile saved" && $0.detail == "Second" })
}

@MainActor
@Test func backgroundProfileSaveSupersedesSuspendedDurableSave() async {
  let app = transactionTestApp(id: "profile.background-newer")
  let profilesStore = TransactionProfilesStore()
  profilesStore.suspendFirstSave = true
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    profileStore: profilesStore
  )

  _ = fixture.store.saveProfile(named: "Older", appIDs: [app.logicalID], captureLevels: false)
  await profilesStore.waitUntilFirstSaveIsSuspended()
  fixture.store.profiles.append(Profile(name: "Background", entries: []))
  fixture.store.enqueueProfilesPersistence(fixture.store.profiles)
  profilesStore.resumeFirstSave()
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }
  await fixture.store.drainPersistenceTasks()

  #expect(profilesStore.value.map(\.name).contains("Background"))
  #expect(!fixture.store.toasts.contains { $0.title == "Profile saved" && $0.detail == "Older" })
}

@MainActor
@Test func durableProfileSaveSupersedesSuspendedBackgroundSave() async {
  let app = transactionTestApp(id: "profile.durable-newer")
  let profilesStore = TransactionProfilesStore()
  profilesStore.suspendFirstSave = true
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    profileStore: profilesStore
  )

  fixture.store.profiles = [Profile(name: "Background", entries: [])]
  fixture.store.enqueueProfilesPersistence(fixture.store.profiles)
  await profilesStore.waitUntilFirstSaveIsSuspended()
  _ = fixture.store.saveProfile(named: "Newer", appIDs: [app.logicalID], captureLevels: false)
  profilesStore.resumeFirstSave()
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }
  await fixture.store.drainPersistenceTasks()

  #expect(profilesStore.value.map(\.name).contains("Newer"))
  #expect(fixture.store.toasts.contains { $0.title == "Profile saved" && $0.detail == "Newer" })
}

@MainActor
@Test func failedProfileSaveRemainsPendingAndCanBeRetried() async {
  let app = transactionTestApp(id: "profile.retry-save")
  let profilesStore = TransactionProfilesStore()
  profilesStore.saveError = TransactionTestError.writeFailed
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    profileStore: profilesStore
  )

  let result = fixture.store.saveProfile(
    named: "Retry me",
    appIDs: [app.logicalID],
    captureLevels: false
  )
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }

  #expect(!fixture.store.toasts.contains { $0.title == "Profile saved" })
  #expect(fixture.store.toasts.contains { $0.title == "Profile not saved" })
  #expect(fixture.store.toasts.first { $0.title == "Profile not saved" }?.action == .retryProfiles)
  #expect(fixture.store.lifecycleSnapshot.toastDismissalCount == 0)
  #expect(fixture.store.lifecycleSnapshot.persistence.pendingSnapshotCount == 1)

  profilesStore.saveError = nil
  guard let id = result.savedProfileID else {
    Issue.record("Expected the profile mutation to remain available for retry")
    return
  }
  fixture.store.retrySavingProfiles()
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }

  #expect(fixture.store.lifecycleSnapshot.persistence.pendingSnapshotCount == 0)
  #expect(profilesStore.value.contains { $0.id == id })
  #expect(fixture.store.toasts.contains { $0.title == "Profiles saved" })
  #expect(!fixture.store.toasts.contains { $0.action == .retryProfiles })
}

@MainActor
@Test func importedProfileNamesPreserveExistingProfiles() {
  let existing = [
    Profile(name: "Meeting", entries: []),
    Profile(name: "Meeting (Imported)", entries: []),
  ]

  #expect(AppStore.uniqueImportedProfileName("Focus", among: existing) == "Focus")
  #expect(AppStore.uniqueImportedProfileName("meeting", among: existing) == "meeting (Imported 2)")

  let longName = String(repeating: "x", count: Profile.maxNameLength)
  let firstLongImport = AppStore.uniqueImportedProfileName(
    longName,
    among: [Profile(name: longName, entries: [])]
  )
  let secondLongImport = AppStore.uniqueImportedProfileName(
    longName,
    among: [
      Profile(name: longName, entries: []),
      Profile(name: firstLongImport, entries: []),
    ]
  )
  #expect(firstLongImport.count <= Profile.maxNameLength)
  #expect(secondLongImport.count <= Profile.maxNameLength)
  #expect(firstLongImport != secondLongImport)
}

@MainActor
@Test func membershipOnlyProfileDoesNotCaptureRestorePoint() async {
  let device = transactionTestDevice()
  let app = transactionTestApp(id: "group.app")
  let grouping = Profile(name: "Grouping", entries: [ProfileEntry(appID: app.logicalID)])
  let fixture = makeTransactionFixture(apps: [app], device: device)

  fixture.store.applyProfile(grouping)
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.mixRestorePoint == nil)
}

@MainActor
@Test func deletingDefaultProfileClearsTheDefault() async {
  let device = transactionTestDevice()
  let app = transactionTestApp(id: "default.app")
  let fixture = makeTransactionFixture(apps: [app], device: device)
  let profile = Profile(
    name: "Baseline",
    entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.6)]
  )
  fixture.store.profiles = [profile]

  fixture.store.setDefaultProfile(profile)
  #expect(fixture.store.preferences.defaultProfileID == profile.id)
  #expect(fixture.store.defaultProfile?.id == profile.id)

  fixture.store.deleteProfiles(at: IndexSet(integer: 0))
  #expect(fixture.store.preferences.defaultProfileID == nil)
  #expect(fixture.store.defaultProfile == nil)
}

@MainActor
@Test func matchingManualDeviceEventConsumesDuplicateToastSuppression() async {
  let clock = CoordinatorTestClock()
  let fixture = makeTransactionFixture(
    apps: [transactionTestApp()],
    device: transactionTestDevice(),
    deviceChangeSuppressionSleep: clock.sleep
  )
  let selected = AudioDevice(id: "device.selected", name: "Selected", kind: .virtual)

  fixture.store.selectOutputDevice(selected)
  await waitUntil { await fixture.backend.currentDeviceID() == selected.id }
  await clock.waitForSleeper()
  fixture.store.handleDeviceChange()
  await waitUntil {
    fixture.store.currentDeviceID == selected.id
      && fixture.store.lifecycleSnapshot.ownedOperationCount == 0
  }
  clock.resumeAll()
  await waitUntil { fixture.store.lifecycleSnapshot.deviceSuppression == .idle }

  #expect(fixture.store.toasts.count { $0.title == "Output device changed" } == 0)
  #expect(fixture.store.lifecycleSnapshot.deviceSuppression == .idle)

  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func missingManualDeviceEventExpiresBeforeLaterLegitimateChange() async {
  let clock = CoordinatorTestClock()
  let fixture = makeTransactionFixture(
    apps: [transactionTestApp()],
    device: transactionTestDevice(),
    deviceChangeSuppressionSleep: clock.sleep
  )
  let selected = AudioDevice(id: "device.selected", name: "Selected", kind: .virtual)
  let external = AudioDevice(id: "device.external", name: "External", kind: .bluetooth)

  fixture.store.selectOutputDevice(selected)
  await waitUntil { await fixture.backend.currentDeviceID() == selected.id }
  await clock.waitForSleeper()
  clock.resumeAll()
  await waitUntil { fixture.store.lifecycleSnapshot.deviceSuppression == .idle }

  await fixture.backend.replaceCurrentDevice(external)
  fixture.store.handleDeviceChange()
  await waitUntil {
    fixture.store.currentDeviceID == external.id
      && fixture.store.lifecycleSnapshot.ownedOperationCount == 0
  }

  #expect(fixture.store.toasts.count { $0.title == "Output device changed" } == 1)
  #expect(fixture.store.toasts.first { $0.title == "Output device changed" }?.detail == external.name)

  _ = await fixture.store.shutdown()
  #expect(fixture.store.lifecycleSnapshot.isIdle)
}

@MainActor
private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async {
  for _ in 0..<10_000 {
    if await predicate() { return }
    await Task.yield()
  }
  Issue.record("Timed out waiting for asynchronous test condition")
}

@MainActor
@Test func appTerminationReleasesAndDemotesOnlyTheExactStoredRuntimeIdentity() async throws {
  let identity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 100)
  let app = transactionTestApp(runtimeIdentity: identity)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice()
  )

  fixture.store.handleAppTermination(pid: 42)
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }

  #expect(await fixture.backend.releasedRuntimeIdentities() == [identity])
  let released = try #require(fixture.store.session.apps.first)
  #expect(!released.isActive)
  #expect(released.routingState == .monitorOnly)
  #expect(released.appliedVolume == nil)
}

@MainActor
@Test(arguments: [false, true])
func appTerminationImmediatelyClearsWaveLinkOutputActivity(isActive: Bool) async throws {
  let identity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 100)
  var app = transactionTestApp(runtimeIdentity: identity)
  app.routingState = .monitorOnly
  app.routeHealthContext = .waveLinkBridge
  app.isActive = isActive
  app.isProducingOutput = true
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice()
  )

  #expect(fixture.store.isLive(app))

  fixture.store.handleAppTermination(pid: 42)

  let terminated = try #require(fixture.store.session.apps.first)
  #expect(!terminated.isProducingOutput)
  #expect(!fixture.store.isLive(terminated))
  #expect(terminated.routingState == .monitorOnly)
}

@MainActor
@Test func appTerminationDoesNotUseASharedOrSpoofedBundleIdentifierAsAuthority() async throws {
  let terminatedIdentity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 100)
  let unrelatedIdentity = transactionRuntimeIdentity(pid: 84, startTimeSeconds: 100)
  let terminated = transactionTestApp(
    id: "terminated",
    pid: 42,
    bundleID: "com.example.shared",
    runtimeIdentity: terminatedIdentity
  )
  let unrelated = transactionTestApp(
    id: "unrelated",
    pid: 84,
    bundleID: "com.example.shared",
    runtimeIdentity: unrelatedIdentity
  )
  let fixture = makeTransactionFixture(
    apps: [terminated, unrelated],
    device: transactionTestDevice()
  )

  fixture.store.handleAppTermination(pid: 42)
  await waitUntil { fixture.store.lifecycleSnapshot.ownedOperationCount == 0 }

  #expect(await fixture.backend.releasedRuntimeIdentities() == [terminatedIdentity])
  #expect(fixture.store.session.apps.first { $0.id == terminated.id }?.routingState == .monitorOnly)
  #expect(fixture.store.session.apps.first { $0.id == unrelated.id }?.routingState == .managed)
  #expect(fixture.store.session.apps.first { $0.id == unrelated.id }?.isActive == true)
}

@MainActor
@Test func delayedTerminationCannotReleaseAReplacementThatReusedThePID() async {
  let terminatedIdentity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 100)
  let replacementIdentity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 200)
  let app = transactionTestApp(runtimeIdentity: terminatedIdentity)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    runtimeProcessProbe: { pid in
      pid == 42 ? transactionRuntimeProbe(identity: replacementIdentity) : nil
    }
  )

  fixture.store.handleAppTermination(pid: 42)
  await Task.yield()

  #expect(await fixture.backend.releasedRuntimeIdentities().isEmpty)
  #expect(fixture.store.session.apps.first?.routingState == .managed)
  #expect(fixture.store.session.apps.first?.isActive == true)
}

@MainActor
@Test func delayedTerminationAfterRefreshCannotReleaseTheLiveReplacementController() async throws {
  let replacementIdentity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 200)
  let replacement = transactionTestApp(
    id: "replacement",
    runtimeIdentity: replacementIdentity
  )
  let device = transactionTestDevice()
  let snapshot = transactionSnapshot(apps: [replacement], device: device)
  let controller = try PerAppTapController.testingController(
    appID: replacement.id,
    logicalID: replacement.logicalID,
    teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
      makeOriginalAudioAudible: { noErr },
      stopIOProc: { noErr },
      destroyIOProc: { _, _ in noErr },
      destroyAggregateDevice: { _ in noErr },
      destroyProcessTap: { _ in noErr }
    )
  )
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    captureAuthorization: .authorized,
    testingControllers: [controller]
  )
  let preferencesStore = TransactionPreferencesStore()
  preferencesStore.value.appAudioIntentMigrationVersion = 1
  preferencesStore.value.hasCompletedPrivacySetup = true
  let sessionStore = TransactionSessionStore()
  sessionStore.value = snapshot
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: TransactionProfilesStore(),
    sessionStore: sessionStore,
    loginItemService: TransactionLoginItemService(),
    deviceVolumePresetsStore: TransactionDevicePresetsStore(),
    initialStartupState: .running,
    runtimeProcessProbe: { pid in
      pid == 42 ? transactionRuntimeProbe(identity: replacementIdentity) : nil
    }
  )

  store.handleAppTermination(pid: 42)
  await waitUntil { store.lifecycleSnapshot.ownedOperationCount == 0 }

  let backendLifecycle = await backend.lifecycleDebugSnapshot()
  let backendReplacement = await backend.currentSnapshot().apps.first
  #expect(backendLifecycle.liveControllers == 1)
  #expect(controller.isActive)
  #expect(backendReplacement?.routingState == .managed)
  #expect(backendReplacement?.isActive == true)
  #expect(store.session.apps.first?.routingState == .managed)
  #expect(store.session.apps.first?.isActive == true)

  _ = await store.shutdown()
}

@MainActor
@Test func liveProcessWithoutAVerifiableIdentityDefersTerminationToMaintenance() async {
  let storedIdentity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 100)
  let replacementIdentity = transactionRuntimeIdentity(pid: 42, startTimeSeconds: 200)
  let app = transactionTestApp(runtimeIdentity: storedIdentity)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    runtimeProcessProbe: { pid in
      pid == 42 ? transactionRuntimeProbe(identity: replacementIdentity) : nil
    }
  )

  fixture.store.handleAppTermination(pid: 42)
  await Task.yield()

  #expect(await fixture.backend.releasedRuntimeIdentities().isEmpty)
  #expect(fixture.store.session.apps.first?.routingState == .managed)
  #expect(fixture.store.session.apps.first?.isActive == true)
}

@MainActor
@Test func terminationWithoutAnImmutableStoredIdentityDefersToMaintenance() async {
  let legacy = transactionTestApp(runtimeIdentity: nil)
  let fixture = makeTransactionFixture(
    apps: [legacy],
    device: transactionTestDevice()
  )

  fixture.store.handleAppTermination(pid: 42)
  await Task.yield()

  #expect(await fixture.backend.releasedRuntimeIdentities().isEmpty)
  #expect(fixture.store.session.apps.first?.routingState == .managed)
  #expect(fixture.store.session.apps.first?.isActive == true)
}

@MainActor
@Test func ambiguousStoredTerminationIdentityDefersToMaintenance() async {
  let first = transactionTestApp(
    id: "first",
    runtimeIdentity: transactionRuntimeIdentity(pid: 42, startTimeSeconds: 100)
  )
  let second = transactionTestApp(
    id: "second",
    runtimeIdentity: transactionRuntimeIdentity(pid: 42, startTimeSeconds: 200)
  )
  let fixture = makeTransactionFixture(
    apps: [first, second],
    device: transactionTestDevice()
  )

  fixture.store.handleAppTermination(pid: 42)
  await Task.yield()

  #expect(await fixture.backend.releasedRuntimeIdentities().isEmpty)
  #expect(fixture.store.session.apps.allSatisfy { $0.routingState == .managed })
  #expect(fixture.store.session.apps.allSatisfy { $0.isActive })
}

// MARK: - Profiles that restore EQ and output (1.8)

private func profileTestEqualizer(gain: Float, role: AdaptiveAppRole = .auto) -> EqualizerSettings {
  var settings = EqualizerSettings(isEnabled: true, adaptiveRole: role)
  settings.setGain(gain, at: 0)
  return settings
}

private let profileTestHeadphones = AudioDevice(
  id: "device.headphones",
  name: "Studio Headphones",
  kind: .display
)

@MainActor
@Test func capturingAMixIncludesEqualizerAndOutputOnlyWhenAsked() async {
  let app = transactionTestApp(id: "capture.sound", desiredVolume: 0.5, targetDeviceUID: profileTestHeadphones.id)
  let equalizer = profileTestEqualizer(gain: 4)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: 0.5,
      equalizerSettings: equalizer,
      targetDeviceUID: profileTestHeadphones.id
    ),
    extraOutputDevices: [profileTestHeadphones]
  )
  fixture.store.availableDevices = [transactionTestDevice(), profileTestHeadphones]

  let levelsOnly = fixture.store.saveProfile(named: "Levels", appIDs: [app.logicalID], captureLevels: true)
  let full = fixture.store.saveProfile(
    named: "Everything",
    appIDs: [app.logicalID],
    captureLevels: true,
    includeEqualizer: true,
    includeOutput: true
  )

  let levelsEntry = fixture.store.profiles.first { $0.id == levelsOnly.savedProfileID }?.entries.first
  #expect(levelsEntry?.desiredVolume == 0.5)
  #expect(levelsEntry?.equalizer == nil)
  #expect(levelsEntry?.output == nil)

  let fullEntry = fixture.store.profiles.first { $0.id == full.savedProfileID }?.entries.first
  #expect(fullEntry?.equalizer == equalizer)
  #expect(
    fullEntry?.output == ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: "Studio Headphones"))
}

@MainActor
@Test func saveCurrentMixCapturesOnlyAppsWavesManagesAndTheUsersOwnMute() async {
  let managed = transactionTestApp(id: "mix.managed", desiredVolume: 0.3)
  // Not media, so call automation leaves it alone and it stays untouched.
  let untouched = AudioApp(
    id: "mix.untouched.runtime",
    logicalID: "mix.untouched",
    pid: 43,
    bundleID: "mix.untouched",
    displayName: "Untouched",
    category: .system,
    isActive: true,
    desiredVolume: 1,
    routingState: .monitorOnly,
    compatibility: .supported
  )
  let fixture = makeTransactionFixture(
    apps: [managed, untouched],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(appID: managed.logicalID, desiredVolume: 0.3, isMuted: false)
  )

  #expect(fixture.store.currentMixAppIDs == [managed.logicalID])

  // A call has the managed app muted right now; the saved mix keeps the
  // user's own (unmuted) state, never the automatic mute.
  await fixture.store.applyAutomaticConferencingTransition(isConferencingActive: true)
  #expect(fixture.store.session.apps.first { $0.logicalID == managed.logicalID }?.muteSource == .autoConferencing)

  let result = fixture.store.saveCurrentMix(named: "Evening", includeEqualizer: true, includeOutput: false)
  let profile = fixture.store.profiles.first { $0.id == result.savedProfileID }
  #expect(profile?.entries.map(\.appID) == [managed.logicalID])
  #expect(profile?.entries.first?.desiredVolume == 0.3)
  #expect(profile?.entries.first?.isMuted == false)
  #expect(profile?.entries.first?.equalizer != nil)
  #expect(profile?.entries.first?.output == nil)
  #expect(fixture.store.activeProfileID == profile?.id)
}

@MainActor
@Test func saveCurrentMixWithNothingManagedExplainsWhatToDo() async {
  var untouched = transactionTestApp(id: "mix.none", desiredVolume: 1)
  untouched.routingState = .monitorOnly
  let fixture = makeTransactionFixture(apps: [untouched], device: transactionTestDevice())
  let profilesBefore = fixture.store.profiles

  #expect(fixture.store.saveCurrentMix(named: "Empty", includeEqualizer: true, includeOutput: false) == .noMixToSave)
  #expect(fixture.store.saveCurrentMix(named: " ", includeEqualizer: true, includeOutput: false) == .blankName)
  #expect(fixture.store.profiles == profilesBefore)
  #expect(ProfileSaveResult.noMixToSave.message?.contains("Change an app's volume") == true)
}

@MainActor
@Test func soundProfileSendsOneCompleteIntentPerAppAndPersistsEqualizerAndOutput() async {
  let app = transactionTestApp(id: "apply.sound", desiredVolume: 0.8, targetDeviceUID: nil)
  let currentRole = AdaptiveAppRole.media
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: 0.8,
      equalizerSettings: EqualizerSettings(adaptiveRole: currentRole)
    ),
    extraOutputDevices: [profileTestHeadphones]
  )
  let savedEqualizer = profileTestEqualizer(gain: -6, role: .auto)
  let profile = Profile(
    name: "Movie",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.4,
        isMuted: false,
        volumeBoost: 1,
        equalizer: savedEqualizer,
        output: ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: profileTestHeadphones.name)
      )
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  // Level, EQ, and route travel together in a single intent, so the app never
  // plays at the new level through the old EQ or the reverse.
  let intents = await fixture.backend.recordedIntents()
  #expect(await fixture.backend.recordedProfileCalls().isEmpty)
  #expect(intents.count == 1)
  var expectedEqualizer = savedEqualizer
  expectedEqualizer.adaptiveRole = currentRole
  #expect(intents.first?.desiredVolume == 0.4)
  #expect(intents.first?.equalizerSettings == expectedEqualizer)
  #expect(intents.first?.targetDeviceUID == profileTestHeadphones.id)

  let durable = fixture.store.preferences.appAudioIntents[app.logicalID]
  #expect(durable?.equalizerSettings == expectedEqualizer)
  #expect(durable?.targetDeviceUID == profileTestHeadphones.id)
  #expect(fixture.store.preferences.appEqualizerSettings[app.logicalID] == expectedEqualizer)
  #expect(fixture.store.toasts.contains { $0.title == "Profile applied" })

  // The next direct volume change is built from the restored EQ, not the old one.
  _ = await fixture.store.applyAppIntent(
    forAppID: app.logicalID,
    overrides: AppIntentOverrides(desiredVolume: 0.5),
    reason: .userEdit
  )
  #expect(await fixture.backend.recordedIntents().last?.equalizerSettings == expectedEqualizer)
}

@MainActor
@Test func editDuringASoundProfileKeepsTheEqualizerAlreadyRestoredForThatApp() async {
  let first = transactionTestApp(id: "apply.sound.first", desiredVolume: 0.8, targetDeviceUID: nil)
  let second = transactionTestApp(id: "apply.sound.second", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [first, second],
    device: transactionTestDevice(),
    extraOutputDevices: [profileTestHeadphones]
  )
  await fixture.backend.suspendIntent(callNumber: 2)
  let savedEqualizer = profileTestEqualizer(gain: -6)
  let headphones = ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: profileTestHeadphones.name)
  let profile = Profile(
    name: "Movie",
    entries: [
      ProfileEntry(appID: first.logicalID, desiredVolume: 0.4, equalizer: savedEqualizer, output: headphones),
      ProfileEntry(appID: second.logicalID, desiredVolume: 0.4, equalizer: savedEqualizer),
    ]
  )

  fixture.store.applyProfile(profile)
  // The first app's row has landed; the second app's is still in flight.
  await fixture.backend.waitUntilFirstIntentIsSuspended()
  let restored = await fixture.backend.recordedIntents().first?.equalizerSettings
  #expect(restored?.isEnabled == true)

  let edit = Task { @MainActor in
    await fixture.store.applyAppIntent(
      forAppID: first.logicalID,
      overrides: AppIntentOverrides(desiredVolume: 0.5),
      reason: .userEdit
    )
  }
  await waitUntil { await fixture.backend.recordedIntents().count == 3 }
  await fixture.backend.resumeFirstIntent()
  _ = await edit.value
  await fixture.store.drainAppIntentTransactions()

  // The volume change carries the EQ and output the profile just restored,
  // not the old ones.
  let edited = await fixture.backend.recordedIntents().last { $0.appID == first.logicalID }
  #expect(edited?.desiredVolume == 0.5)
  #expect(edited?.equalizerSettings == restored)
  #expect(edited?.targetDeviceUID == profileTestHeadphones.id)
}

@MainActor
@Test func saveCurrentMixWaitsForAProfileThatIsStillApplying() async {
  let app = transactionTestApp(id: "capture.mid-apply", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(appID: app.logicalID, desiredVolume: 0.8),
    suspendFirstProfile: true
  )
  let profile = Profile(name: "Quiet", entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2)])

  fixture.store.applyProfile(profile)
  await fixture.backend.waitUntilFirstProfileIsSuspended()
  // Mid-apply, rows and confirmed EQ can disagree, so nothing is captured.
  #expect(
    fixture.store.saveCurrentMix(named: "Now", includeEqualizer: true, includeOutput: false)
      == .profileStillApplying)

  await fixture.backend.resumeFirstProfile()
  await fixture.store.drainAppIntentTransactions()
  #expect(
    fixture.store.saveCurrentMix(named: "Now", includeEqualizer: true, includeOutput: false)
      .savedProfileID != nil)
}

@MainActor
@Test func levelOnlyProfileLeavesEqualizerAndOutputAlone() async {
  let app = transactionTestApp(id: "apply.legacy", desiredVolume: 0.8, targetDeviceUID: profileTestHeadphones.id)
  let equalizer = profileTestEqualizer(gain: 5)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: 0.8,
      equalizerSettings: equalizer,
      targetDeviceUID: profileTestHeadphones.id
    ),
    extraOutputDevices: [profileTestHeadphones]
  )

  fixture.store.applyProfile(
    Profile(name: "Quiet", entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.2)]))
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  #expect(await fixture.backend.recordedProfileCalls().count == 1)
  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.desiredVolume == 0.2)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.equalizerSettings == equalizer)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.targetDeviceUID == profileTestHeadphones.id)
}

@MainActor
@Test func disconnectedSavedOutputIsSkippedAndNamedWhileTheRestApplies() async {
  let app = transactionTestApp(id: "apply.absent", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(appID: app.logicalID, desiredVolume: 0.8)
  )
  let equalizer = profileTestEqualizer(gain: 3)
  let profile = Profile(
    name: "Desk",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.5,
        equalizer: equalizer,
        output: ProfileOutput(deviceUID: "device.airpods", deviceName: "AirPods Pro")
      )
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count == 1)
  #expect(!intents.contains { $0.targetDeviceUID == "device.airpods" })
  #expect(intents.first?.targetDeviceUID == nil)
  #expect(intents.first?.desiredVolume == 0.5)
  #expect(intents.first?.equalizerSettings.activeGainsDB == equalizer.activeGainsDB)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.targetDeviceUID == nil)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile partly applied" && $0.kind == .info
        && $0.detail == "AirPods Pro isn't connected, so Test App kept its output."
    })
}

@MainActor
@Test func linkAppliedProfileSetsLevelsAndEqualizerButNeverMovesTheOutput() async {
  let app = transactionTestApp(id: "apply.link", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    extraOutputDevices: [profileTestHeadphones]
  )
  let equalizer = profileTestEqualizer(gain: -6)
  let profile = Profile(
    name: "Speakers",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.4,
        equalizer: equalizer,
        output: ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: profileTestHeadphones.name)
      )
    ]
  )
  fixture.store.preferences.enableURLScheme = true
  fixture.store.profiles = [profile]

  // Anything that can open a URL can send this, so it must not be able to
  // move a call or music onto another device.
  fixture.store.handleURLScheme(URL(string: "waves://apply-profile?name=Speakers")!)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count == 1)
  #expect(intents.first?.desiredVolume == 0.4)
  #expect(intents.first?.equalizerSettings.activeGainsDB == equalizer.activeGainsDB)
  #expect(intents.first?.targetDeviceUID == nil)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.targetDeviceUID == nil)
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile partly applied"
        && $0.detail == "Links can't move apps to another output, so Test App kept its output."
    })

  // The same profile applied by the user does move it.
  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  #expect(await fixture.backend.recordedIntents().last?.targetDeviceUID == profileTestHeadphones.id)
}

@MainActor
@Test func outputOnlyProfileStillNamesTheDevicesThatAreNotConnected() async {
  let app = transactionTestApp(id: "apply.output-only", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(apps: [app], device: transactionTestDevice())
  let profile = Profile(
    name: "Desk",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        output: ProfileOutput(deviceUID: "device.airpods", deviceName: "AirPods Pro")
      )
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  // With its only setting skipped the row has nothing left to apply, which
  // used to read as a plain "Profile selected".
  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile selected" })
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile partly applied"
        && $0.detail == "AirPods Pro isn't connected, so Test App kept its output."
    })
}

@MainActor
@Test func excludedAppNeverReceivesAProfilesEqualizerOrOutput() async {
  let app = transactionTestApp(id: "apply.excluded", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    excludedAppIDs: [app.logicalID],
    extraOutputDevices: [profileTestHeadphones]
  )
  let profile = Profile(
    name: "Loud",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.5,
        equalizer: profileTestEqualizer(gain: 6),
        output: ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: profileTestHeadphones.name)
      )
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.allSatisfy { $0.isExcluded })
  #expect(!intents.contains { $0.targetDeviceUID == profileTestHeadphones.id })
  #expect(fixture.store.lastProfileApplyResult?.rows.first?.outcome == .excluded)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID] == nil)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  #expect(fixture.store.toasts.contains { $0.detail?.contains("1 excluded") == true })
}

@MainActor
@Test func waveLinkAppGetsTheLevelButIsToldItsEqualizerAndOutputStayInWaveLink() async {
  let app = transactionTestApp(id: "apply.wavelink", desiredVolume: 0.8, targetDeviceUID: nil)
  let originalEqualizer = profileTestEqualizer(gain: 1)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: 0.8,
      equalizerSettings: originalEqualizer
    ),
    extraOutputDevices: [profileTestHeadphones],
    waveLinkAppIDs: [app.logicalID]
  )
  let profile = Profile(
    name: "Stream",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.5,
        equalizer: profileTestEqualizer(gain: 8),
        output: ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: profileTestHeadphones.name)
      )
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  #expect(fixture.store.session.apps.first?.desiredVolume == 0.5)
  let durable = fixture.store.preferences.appAudioIntents[app.logicalID]
  #expect(durable?.desiredVolume == 0.5)
  #expect(durable?.equalizerSettings == originalEqualizer)
  #expect(durable?.targetDeviceUID == nil)
  #expect(!fixture.store.toasts.contains { $0.title == "Profile applied" })
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Profile partly applied" && $0.kind == .warning
        && $0.detail == "Wave Link controls Test App, so its EQ and output weren't changed."
    })
}

@MainActor
@Test func waveLinkAppKeepsItsEqualizerWhenAProfileOnlyRestoresEqualizer() async {
  let app = transactionTestApp(id: "apply.wavelink-eq", desiredVolume: 0.8, targetDeviceUID: nil)
  let originalEqualizer = profileTestEqualizer(gain: 1)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(
      appID: app.logicalID,
      desiredVolume: 0.8,
      equalizerSettings: originalEqualizer
    ),
    waveLinkAppIDs: [app.logicalID]
  )

  fixture.store.applyProfile(
    Profile(
      name: "Bright",
      entries: [
        ProfileEntry(appID: app.logicalID, desiredVolume: 0.5, equalizer: profileTestEqualizer(gain: 8))
      ]
    ))
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.desiredVolume == 0.5)
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.equalizerSettings == originalEqualizer)
  #expect(
    fixture.store.toasts.contains {
      $0.detail == "Wave Link controls Test App, so its EQ wasn't changed."
    })
}

@MainActor
@Test func refusedRowForARunningAppIsNotReportedAsSavedForLater() async {
  let app = transactionTestApp(id: "apply.refused", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(appID: app.logicalID, desiredVolume: 0.8),
    extraOutputDevices: [profileTestHeadphones],
    waveLinkAppIDs: [app.logicalID]
  )
  // Same level, new output: Wave Link refuses the whole row.
  let profile = Profile(
    name: "Route only",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.8,
        output: ProfileOutput(deviceUID: profileTestHeadphones.id, deviceName: profileTestHeadphones.name)
      )
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  #expect(fixture.store.lastProfileApplyResult?.rows.first?.outcome == .unsupported)
  #expect(fixture.store.session.apps.contains { $0.logicalID == app.logicalID })
  #expect(fixture.store.preferences.appAudioIntents[app.logicalID]?.targetDeviceUID == nil)
  #expect(!fixture.store.toasts.contains { $0.detail?.contains("saved for later") == true })
  #expect(fixture.store.toasts.contains { $0.detail?.contains("Wave Link controls Test App") == true })
}

@MainActor
@Test func resetMixAfterASoundProfileRestoresLevelsButNotEqualizer() async {
  let app = transactionTestApp(id: "reset.sound", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(appID: app.logicalID, desiredVolume: 0.8)
  )
  let equalizer = profileTestEqualizer(gain: -4)
  fixture.store.applyProfile(
    Profile(
      name: "Night",
      entries: [ProfileEntry(appID: app.logicalID, desiredVolume: 0.3, equalizer: equalizer)]
    ))
  await fixture.store.drainAppIntentTransactions()
  #expect(fixture.store.mixRestorePoint?.entries.first?.equalizer == nil)
  #expect(fixture.store.mixRestorePoint?.entries.first?.output == nil)

  fixture.store.resetMix()
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  #expect(fixture.store.session.apps.first?.desiredVolume == 0.8)
  #expect(
    fixture.store.preferences.appAudioIntents[app.logicalID]?.equalizerSettings.activeGainsDB
      == equalizer.activeGainsDB)
  #expect(fixture.store.toasts.contains { $0.title == "Mix reset" })
}

@MainActor
@Test func defaultProfileAtStartupNamesASkippedOutput() async {
  let app = transactionTestApp(id: "startup.absent", desiredVolume: 0.8, targetDeviceUID: nil)
  let fixture = makeTransactionFixture(
    apps: [app],
    device: transactionTestDevice(),
    intent: PersistedAppAudioIntent(appID: app.logicalID, desiredVolume: 0.8)
  )
  let profile = Profile(
    name: "Baseline",
    entries: [
      ProfileEntry(
        appID: app.logicalID,
        desiredVolume: 0.6,
        output: ProfileOutput(deviceUID: "device.gone", deviceName: "Desk Speakers")
      )
    ]
  )

  fixture.store.applyProfile(profile, purpose: .defaultAtStartup)
  await fixture.store.drainAppIntentTransactions()
  await fixture.store.drainPersistenceTasks()

  #expect(!(await fixture.backend.recordedIntents()).contains { $0.targetDeviceUID == "device.gone" })
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.6)
  #expect(
    fixture.store.toasts.contains {
      $0.title == "Default profile partly applied" && $0.kind == .info
        && $0.detail == "Desk Speakers isn't connected, so Test App kept its output."
    })
}

@MainActor
@Test func saveCurrentMixRequestIsConsumedOnce() async {
  let fixture = makeTransactionFixture(apps: [], device: transactionTestDevice())
  #expect(!fixture.store.consumeSaveCurrentMixRequest())
  let token = fixture.store.saveCurrentMixToken
  fixture.store.requestSaveCurrentMix()
  #expect(fixture.store.saveCurrentMixToken != token)
  #expect(fixture.store.consumeSaveCurrentMixRequest())
  #expect(!fixture.store.consumeSaveCurrentMixRequest())
}

private func transactionTestApp(
  id: String = "test.app",
  pid: Int32 = 42,
  bundleID: String? = nil,
  desiredVolume: Float = 0.4,
  isMuted: Bool = false,
  volumeBoost: Float = 2,
  targetDeviceUID: String? = "device.original",
  runtimeIdentity: AppRuntimeIdentity? = nil
) -> AudioApp {
  AudioApp(
    id: "\(id).runtime",
    logicalID: id,
    pid: pid,
    bundleID: bundleID ?? id,
    displayName: "Test App",
    category: .media,
    isActive: true,
    desiredVolume: desiredVolume,
    appliedVolume: isMuted ? 0 : desiredVolume,
    isMuted: isMuted,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: volumeBoost,
    targetDeviceUID: targetDeviceUID,
    runtimeIdentity: runtimeIdentity
  )
}

private func transactionRuntimeIdentity(
  pid: Int32,
  startTimeSeconds: UInt64
) -> AppRuntimeIdentity {
  AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(
      pid: pid,
      startTimeSeconds: startTimeSeconds,
      startTimeMicroseconds: 0
    ),
    executablePath: "/Applications/Test App.app/Contents/MacOS/Test App",
    outerBundlePath: "/Applications/Test App.app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.test-app",
      teamIdentifier: "TEAM123",
      designatedRequirement: "identifier \"com.example.test-app\"",
      codeDirectoryHash: Data([1, 2, 3])
    )
  )
}

private func transactionRuntimeProbe(identity: AppRuntimeIdentity) -> RuntimeProcessProbe {
  RuntimeProcessProbe(
    lifetime: identity.lifetime,
    executablePath: identity.executablePath,
    outerBundlePath: identity.outerBundlePath
  )
}

private func transactionTestDevice() -> AudioDevice {
  AudioDevice(id: "device.current", name: "Current Device", kind: .builtInOutput)
}

@MainActor
private func makeTransactionFixture(
  apps: [AudioApp],
  device: AudioDevice,
  intent: PersistedAppAudioIntent? = nil,
  preset: AppVolumeSettings? = nil,
  extraIntents: [String: PersistedAppAudioIntent] = [:],
  extraPresets: [String: AppVolumeSettings] = [:],
  excluded: Bool = false,
  excludedAppIDs: Set<String> = [],
  outcomes: [AppIntentApplyOutcome] = [],
  profileOutcomes: [ProfileRowApplyOutcome] = [],
  suspendFirstIntent: Bool = false,
  suspendFirstProfile: Bool = false,
  resultGenerationOffset: UInt64 = 0,
  refreshApps: [AudioApp]? = nil,
  initialStartupState: AppStartupState = .running,
  runtimeProcessProbe: @escaping @Sendable (Int32) -> RuntimeProcessProbe? = { _ in nil },
  deviceChangeSuppressionSleep: @escaping DeviceChangeSuppressionCoordinator.Sleep = {
    duration in try await Task.sleep(for: duration)
  },
  profileStore: TransactionProfilesStore = TransactionProfilesStore(),
  extraOutputDevices: [AudioDevice] = [],
  waveLinkAppIDs: Set<String> = [],
  microphoneActivityMonitor: (any MicrophoneActivityMonitoring)? = nil,
  callEndHoldSleep: @escaping @Sendable (Duration) async throws -> Void = {
    duration in try await Task.sleep(for: duration)
  }
) -> TransactionFixture {
  let snapshot = transactionSnapshot(apps: apps, device: device)
  let refreshSnapshot = refreshApps.map { transactionSnapshot(apps: $0, device: device) }
  let backend = TransactionBackend(
    snapshot: snapshot,
    refreshSnapshot: refreshSnapshot,
    outcomes: outcomes,
    profileOutcomes: profileOutcomes,
    suspendFirstIntent: suspendFirstIntent,
    suspendFirstProfile: suspendFirstProfile,
    resultGenerationOffset: resultGenerationOffset,
    extraOutputDevices: extraOutputDevices,
    waveLinkAppIDs: waveLinkAppIDs
  )
  let preferencesStore = TransactionPreferencesStore()
  // Transaction tests must not react to conferencing apps on the test desktop.
  // Automatic behavior tests drive their transitions explicitly.
  preferencesStore.value.autoPauseMusicForConferencing = false
  preferencesStore.value.urlSchemeAutomationAcknowledged = true
  preferencesStore.value.appAudioIntentMigrationVersion = 1
  preferencesStore.value.hasCompletedPrivacySetup = true
  if let intent {
    preferencesStore.value.appAudioIntents[intent.appID] = intent
    preferencesStore.value.appEqualizerSettings[intent.appID] = intent.equalizerSettings
  }
  for (appID, intent) in extraIntents {
    preferencesStore.value.appAudioIntents[appID] = intent
    preferencesStore.value.appEqualizerSettings[appID] = intent.equalizerSettings
  }
  var allExcludedAppIDs = excludedAppIDs
  if excluded, let appID = apps.first?.logicalID {
    allExcludedAppIDs.insert(appID)
  }
  preferencesStore.value.excludedAppIDs = allExcludedAppIDs.sorted()

  let presetsStore = TransactionDevicePresetsStore()
  if let preset, let appID = apps.first?.logicalID {
    presetsStore.value.saveVolumeSettings(for: appID, deviceID: device.id, settings: preset)
  }
  for (appID, preset) in extraPresets {
    presetsStore.value.saveVolumeSettings(for: appID, deviceID: device.id, settings: preset)
  }
  let sessionStore = TransactionSessionStore()
  sessionStore.value = snapshot
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: profileStore,
    sessionStore: sessionStore,
    loginItemService: TransactionLoginItemService(),
    deviceVolumePresetsStore: presetsStore,
    initialStartupState: initialStartupState,
    runtimeProcessProbe: runtimeProcessProbe,
    deviceChangeSuppressionSleep: deviceChangeSuppressionSleep,
    microphoneActivityMonitor: microphoneActivityMonitor,
    callEndHoldSleep: callEndHoldSleep
  )
  return TransactionFixture(
    store: store,
    backend: backend,
    preferencesStore: preferencesStore,
    presetsStore: presetsStore,
    sessionStore: sessionStore
  )
}

private struct TransactionFixture {
  let store: AppStore
  let backend: TransactionBackend
  let preferencesStore: TransactionPreferencesStore
  let presetsStore: TransactionDevicePresetsStore
  let sessionStore: TransactionSessionStore
}

private func transactionSnapshot(apps: [AudioApp], device: AudioDevice) -> AudioSessionSnapshot {
  AudioSessionSnapshot(
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
      }
    ),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

private actor TransactionBackend: AudioControlBackend {
  nonisolated let deviceChangeEvents: AsyncStream<Void> = AsyncStream { $0.finish() }

  private var snapshot: AudioSessionSnapshot
  private var refreshSnapshot: AudioSessionSnapshot?
  private var outcomes: [AppIntentApplyOutcome]
  private var profileOutcomes: [ProfileRowApplyOutcome]
  private var suspendedIntentCallNumber: Int?
  private let suspendFirstProfile: Bool
  private let resultGenerationOffset: UInt64
  private let extraOutputDevices: [AudioDevice]
  /// Apps Wave Link mixes: like the real bridge, only volume and mute reach
  /// them, and a change that is purely boost or output is refused.
  private let waveLinkAppIDs: Set<String>
  /// Apps for which a router applies the mute but does not confirm the rest of
  /// the request, so the intent comes back failed with the mute in place.
  private var muteLandsButIntentFailsAppIDs: Set<String> = []
  private var intents: [AppRouteIntent] = []
  private var profileCalls: [(profile: Profile, generation: UInt64)] = []
  private var latestGenerationByAppID: [String: UInt64] = [:]
  private var completedIntents = 0
  private var refreshCalls = 0
  private var diagnosticsCalls = 0
  private var diagnosticsReprobeValues: [Bool] = []
  private var releasedIdentities: [AppRuntimeIdentity] = []
  private var diagnosticsTemplate = DiagnosticsReport(
    summary: "Transaction test",
    checks: [
      DiagnosticsCheck(
        title: "Audio component",
        status: .passed,
        detail: "Process tap routing is supported on this system."
      )
    ]
  )
  private var firstIntentIsSuspended = false
  private var firstIntentResume: CheckedContinuation<Void, Never>?
  private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstProfileIsSuspended = false
  private var firstProfileResume: CheckedContinuation<Void, Never>?
  private var profileSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    snapshot: AudioSessionSnapshot,
    refreshSnapshot: AudioSessionSnapshot?,
    outcomes: [AppIntentApplyOutcome],
    profileOutcomes: [ProfileRowApplyOutcome],
    suspendFirstIntent: Bool,
    suspendFirstProfile: Bool,
    resultGenerationOffset: UInt64,
    extraOutputDevices: [AudioDevice] = [],
    waveLinkAppIDs: Set<String> = []
  ) {
    self.snapshot = snapshot
    self.refreshSnapshot = refreshSnapshot
    self.outcomes = outcomes
    self.profileOutcomes = profileOutcomes
    self.suspendedIntentCallNumber = suspendFirstIntent ? 1 : nil
    self.suspendFirstProfile = suspendFirstProfile
    self.resultGenerationOffset = resultGenerationOffset
    self.extraOutputDevices = extraOutputDevices
    self.waveLinkAppIDs = waveLinkAppIDs
  }

  func recordedIntents() -> [AppRouteIntent] { intents }
  func recordedProfileCalls() -> [(profile: Profile, generation: UInt64)] { profileCalls }
  func completedIntentCount() -> Int { completedIntents }
  func refreshCallCount() -> Int { refreshCalls }
  func diagnosticsCallCount() -> Int { diagnosticsCalls }
  func diagnosticsReprobeRequests() -> [Bool] { diagnosticsReprobeValues }
  func releasedRuntimeIdentities() -> [AppRuntimeIdentity] { releasedIdentities }
  func setDiagnosticsTemplate(_ replacement: DiagnosticsReport) {
    diagnosticsTemplate = replacement
  }
  func currentDeviceID() -> String? { snapshot.currentDevice?.id }
  func setRefreshSnapshot(_ replacement: AudioSessionSnapshot) {
    refreshSnapshot = replacement
  }
  func replaceCurrentDevice(_ device: AudioDevice) {
    snapshot.currentDevice = device
  }

  func waitUntilFirstIntentIsSuspended() async {
    if firstIntentIsSuspended { return }
    await withCheckedContinuation { continuation in
      suspensionWaiters.append(continuation)
    }
  }

  func failIntentsButApplyMute(for appIDs: Set<String>) {
    muteLandsButIntentFailsAppIDs = appIDs
  }

  /// Suspends the intent with this call number instead of the first.
  func suspendIntent(callNumber: Int) {
    suspendedIntentCallNumber = callNumber
  }

  func resumeFirstIntent() {
    firstIntentResume?.resume()
    firstIntentResume = nil
  }

  func waitUntilFirstProfileIsSuspended() async {
    if firstProfileIsSuspended { return }
    await withCheckedContinuation { continuation in
      profileSuspensionWaiters.append(continuation)
    }
  }

  func resumeFirstProfile() {
    firstProfileResume?.resume()
    firstProfileResume = nil
  }

  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    intents.append(intent)
    let callNumber = intents.count
    let baseApp = snapshot.apps.first { $0.logicalID == intent.appID }
    let outcome =
      outcomes.isEmpty
      ? (intent.isExcluded ? AppIntentApplyOutcome.excluded : .applied)
      : outcomes.removeFirst()
    let latestGeneration = latestGenerationByAppID[intent.appID] ?? 0
    if intent.generation >= latestGeneration {
      latestGenerationByAppID[intent.appID] = intent.generation
    }

    if callNumber == suspendedIntentCallNumber {
      firstIntentIsSuspended = true
      let waiters = suspensionWaiters
      suspensionWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        firstIntentResume = continuation
      }
      firstIntentIsSuspended = false
    }

    if latestGenerationByAppID[intent.appID].map({ $0 > intent.generation }) == true {
      completedIntents += 1
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .superseded,
        resultingApp: snapshot.apps.first { $0.logicalID == intent.appID },
        backendStatus: snapshot.backendStatus,
        detail: "A newer deterministic transaction superseded this intent."
      )
    }

    if waveLinkAppIDs.contains(intent.appID),
      let index = snapshot.apps.firstIndex(where: { $0.logicalID == intent.appID })
    {
      completedIntents += 1
      let previous = snapshot.apps[index]
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].routeHealthContext = .waveLinkBridge
      let levelChanged =
        intent.desiredVolume != previous.desiredVolume || intent.isMuted != previous.isMuted
      let otherChanged =
        intent.volumeBoost != previous.volumeBoost || intent.targetDeviceUID != previous.targetDeviceUID
      if otherChanged, !levelChanged {
        return AppIntentApplyResult(
          appID: intent.appID,
          generation: intent.generation,
          outcome: .unavailable,
          resultingApp: snapshot.apps[index],
          backendStatus: snapshot.backendStatus,
          detail: "Boost, EQ, and output routing stay in Wave Link."
        )
      }
      snapshot.apps[index].desiredVolume = intent.desiredVolume
      snapshot.apps[index].isMuted = intent.isMuted
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .applied,
        resultingApp: snapshot.apps[index],
        backendStatus: snapshot.backendStatus
      )
    }

    if muteLandsButIntentFailsAppIDs.contains(intent.appID),
      let index = snapshot.apps.firstIndex(where: { $0.logicalID == intent.appID })
    {
      completedIntents += 1
      snapshot.apps[index].isMuted = intent.isMuted
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: snapshot.apps[index],
        backendStatus: snapshot.backendStatus,
        detail: "The router did not confirm the requested level."
      )
    }

    var resultingApp = baseApp
    var status = snapshot.backendStatus
    switch outcome {
    case .applied, .noChange:
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == intent.appID }) {
        snapshot.apps[index].desiredVolume = intent.desiredVolume
        snapshot.apps[index].isMuted = intent.isMuted
        snapshot.apps[index].volumeBoost = intent.volumeBoost
        snapshot.apps[index].targetDeviceUID = intent.targetDeviceUID
        snapshot.apps[index].appliedVolume = intent.isMuted ? 0 : intent.desiredVolume
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].notes = nil
        resultingApp = snapshot.apps[index]
      }
    case .excluded:
      if var app = resultingApp {
        app.routingState = .monitorOnly
        app.appliedVolume = nil
        app.peakLevel = 0
        app.rmsLevel = 0
        resultingApp = app
      }
    case .failed:
      if var app = resultingApp {
        app.routingState = .error
        app.notes = "Deterministic transaction failure"
        resultingApp = app
      }
      status.isRouteRecoveryHealthy = false
      status.lastError = "Deterministic transaction failure"
    case .unsupported:
      if var app = resultingApp {
        app.routingState = .monitorOnly
        app.appliedVolume = nil
        resultingApp = app
      }
    case .unavailable:
      resultingApp = nil
    case .superseded:
      break
    }
    completedIntents += 1
    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation &+ resultGenerationOffset,
      outcome: outcome,
      resultingApp: resultingApp,
      backendStatus: status,
      detail: outcome == .failed ? "Deterministic transaction failure" : nil
    )
  }

  func start() async throws {}
  func stop() async {}
  func currentSnapshot() async -> AudioSessionSnapshot { snapshot }
  func refresh() async throws -> AudioSessionSnapshot {
    refreshCalls += 1
    if var refreshSnapshot {
      refreshSnapshot.updatedAt = .now
      snapshot = refreshSnapshot
      self.refreshSnapshot = refreshSnapshot
    }
    return snapshot
  }
  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {}
  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {}
  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {}
  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {}
  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] { [:] }
  func setAdaptiveGains(_ gainsDB: [String: Float]) async {}
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {}
  func pinApp(_ isPinned: Bool, appID: String) async throws {}
  func applyProfileWithResults(
    _ profile: Profile,
    generation: UInt64
  ) async -> ProfileApplyResult {
    profileCalls.append((profile, generation))
    for entry in profile.entries where entry.hasLevels {
      guard snapshot.apps.contains(where: { $0.logicalID == entry.appID }) else { continue }
      let latest = latestGenerationByAppID[entry.appID] ?? 0
      if generation >= latest {
        latestGenerationByAppID[entry.appID] = generation
      }
    }

    if profileCalls.count == 1, suspendFirstProfile {
      firstProfileIsSuspended = true
      let waiters = profileSuspensionWaiters
      profileSuspensionWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        firstProfileResume = continuation
      }
      firstProfileIsSuspended = false
    }

    var rows: [ProfileRowApplyResult] = []
    for (entryIndex, entry) in profile.entries.enumerated() {
      guard entry.hasLevels else {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .membershipOnly,
            resultingApp: nil
          ))
        continue
      }

      if latestGenerationByAppID[entry.appID].map({ $0 > generation }) == true {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .superseded,
            resultingApp: snapshot.apps.first { $0.logicalID == entry.appID },
            detail: "A newer deterministic transaction superseded this profile row."
          ))
        continue
      }

      let outcome: ProfileRowApplyOutcome
      if profileOutcomes.isEmpty {
        outcome =
          snapshot.apps.contains(where: { $0.logicalID == entry.appID })
          ? .applied
          : .unavailable
      } else {
        outcome = profileOutcomes.removeFirst()
      }
      var resultingApp = snapshot.apps.first { $0.logicalID == entry.appID }
      switch outcome {
      case .applied, .noChange:
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) {
          if let desiredVolume = entry.desiredVolume {
            snapshot.apps[index].desiredVolume = desiredVolume
          }
          if let isMuted = entry.isMuted {
            snapshot.apps[index].isMuted = isMuted
          }
          if let volumeBoost = entry.volumeBoost {
            snapshot.apps[index].volumeBoost = volumeBoost
          }
          snapshot.apps[index].appliedVolume =
            snapshot.apps[index].isMuted
            ? 0
            : snapshot.apps[index].desiredVolume
          snapshot.apps[index].routingState = .managed
          snapshot.apps[index].notes = nil
          resultingApp = snapshot.apps[index]
        } else {
          resultingApp = nil
        }
      case .excluded:
        if var app = resultingApp {
          app.routingState = .monitorOnly
          app.appliedVolume = nil
          resultingApp = app
        }
      case .failed:
        if var app = resultingApp {
          app.routingState = .error
          app.notes = "Deterministic profile failure"
          resultingApp = app
        }
        snapshot.backendStatus.isRouteRecoveryHealthy = false
        snapshot.backendStatus.lastError = "Deterministic profile failure"
      case .unavailable:
        resultingApp = nil
      case .membershipOnly, .superseded, .unsupported:
        break
      }
      rows.append(
        ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: outcome,
          resultingApp: resultingApp,
          detail: outcome == .failed ? "Deterministic profile failure" : nil
        ))
    }
    return ProfileApplyResult(rows: rows, backendStatus: snapshot.backendStatus)
  }
  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot {
    _ = await applyProfileWithResults(profile, generation: 1)
    return snapshot
  }
  func saveCurrentProfile(named name: String) async throws -> Profile {
    Profile(name: name, entries: [])
  }
  func recoverRoutes() async throws -> AudioSessionSnapshot { snapshot }
  func autoRestoreDevice() async throws -> AudioSessionSnapshot { snapshot }
  func diagnosticsReport() async -> DiagnosticsReport {
    diagnosticsCalls += 1
    return DiagnosticsReport(
      summary: diagnosticsTemplate.summary,
      checks: diagnosticsTemplate.checks.map { check in
        DiagnosticsCheck(title: check.title, status: check.status, detail: check.detail)
      }
    )
  }
  func diagnosticsReport(reprobeCaptureAuthorization: Bool) async -> DiagnosticsReport {
    diagnosticsReprobeValues.append(reprobeCaptureAuthorization)
    return await diagnosticsReport()
  }
  func availableOutputDevices() async -> [AudioDevice] {
    (snapshot.currentDevice.map { [$0] } ?? []) + extraOutputDevices
  }
  func setDefaultOutputDevice(uid: String) async throws {
    snapshot.currentDevice = AudioDevice(id: uid, name: "Selected", kind: .virtual)
  }
  func setOutputDevice(uid: String?, forAppID appID: String) async throws {}
  func releaseControllers(
    forRuntimeIdentity runtimeIdentity: AppRuntimeIdentity,
    clearMuteState: Bool
  ) async {
    releasedIdentities.append(runtimeIdentity)
  }
  func audioLevels() async -> [String: AudioLevels] { [:] }
}

private enum TransactionTestError: LocalizedError {
  case writeFailed

  var errorDescription: String? { "Injected write failure" }
}

private actor URLProfileWaveLinkController: WaveLinkControlling {
  struct Request: Equatable, Sendable {
    let bundleIdentifier: String
    let volume: Float
    let isMuted: Bool
    let allowsChannelRelocation: Bool
  }

  private(set) var requests: [Request] = []
  private(set) var moveRequests: [String] = []
  private let sharedAppID: String

  init(sharedAppID: String) {
    self.sharedAppID = sharedAppID
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) throws -> WaveLinkControlConfirmation {
    try apply(
      bundleIdentifier: bundleIdentifier,
      volume: volume,
      isMuted: isMuted,
      allowsChannelRelocation: true
    )
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool,
    allowsChannelRelocation: Bool
  ) throws -> WaveLinkControlConfirmation {
    requests.append(
      Request(
        bundleIdentifier: bundleIdentifier,
        volume: volume,
        isMuted: isMuted,
        allowsChannelRelocation: allowsChannelRelocation
      )
    )
    if bundleIdentifier == sharedAppID {
      guard allowsChannelRelocation else {
        throw WaveLinkControlBridgeError.relocationNotPermitted(bundleIdentifier)
      }
      moveRequests.append(bundleIdentifier)
    }
    return WaveLinkControlConfirmation(
      channelID: bundleIdentifier == sharedAppID ? "relocated" : "dedicated",
      channelName: bundleIdentifier == sharedAppID ? "Relocated" : "Dedicated",
      appliedVolume: volume,
      isMuted: isMuted,
      relocated: bundleIdentifier == sharedAppID
    )
  }
}

private final class TransactionPreferencesStore: PreferencesPersisting, @unchecked Sendable {
  var value = UserPreferences()
  var saveError: Error?

  private let lock = NSLock()
  private var saveErrors: [Error?] = []
  private var saveAttempts = 0
  private var successfulSaves = 0
  private var shouldSuspendFirstSave = false
  private var firstSaveIsSuspended = false
  private var firstSaveResume: CheckedContinuation<Void, Never>?
  private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []

  var saveCount: Int { lock.withLock { successfulSaves } }

  func configureFailingSaves(count: Int, suspendFirst: Bool) {
    lock.withLock {
      saveErrors = Array(repeating: TransactionTestError.writeFailed, count: count)
      shouldSuspendFirstSave = suspendFirst
    }
  }

  func waitUntilFirstSaveIsSuspended() async {
    if lock.withLock({ firstSaveIsSuspended }) { return }
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock { () -> Bool in
        if firstSaveIsSuspended { return true }
        firstSaveWaiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func resumeFirstSave() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { firstSaveResume = nil }
      return firstSaveResume
    }
    continuation?.resume()
  }

  func load() -> UserPreferences { value }
  func save(_ preferences: UserPreferences) async throws {
    let state = lock.withLock { () -> (attempt: Int, suspend: Bool, error: Error?) in
      saveAttempts += 1
      let attempt = saveAttempts
      let error =
        saveErrors.indices.contains(attempt - 1)
        ? saveErrors[attempt - 1]
        : saveError
      return (attempt, shouldSuspendFirstSave && attempt == 1, error)
    }

    if state.suspend {
      await withCheckedContinuation { continuation in
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
          firstSaveIsSuspended = true
          firstSaveResume = continuation
          defer { firstSaveWaiters.removeAll() }
          return firstSaveWaiters
        }
        for waiter in waiters { waiter.resume() }
      }
    }
    if let error = state.error { throw error }
    lock.withLock {
      value = preferences
      successfulSaves += 1
    }
  }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class TransactionProfilesStore: ProfilesPersisting, @unchecked Sendable {
  var value = Profile.defaults
  var saveError: Error?
  var suspendFirstSave = false
  private let lock = NSLock()
  private var saveAttempts = 0
  private var firstSaveSuspended = false
  private var firstSaveResume: CheckedContinuation<Void, Never>?
  private var firstSaveWaiters: [CheckedContinuation<Void, Never>] = []

  func load(defaults: [Profile]) -> [Profile] { value }
  func save(_ profiles: [Profile]) async throws {
    let shouldSuspend = lock.withLock { () -> Bool in
      saveAttempts += 1
      return suspendFirstSave && saveAttempts == 1
    }
    if shouldSuspend {
      await withCheckedContinuation { continuation in
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
          firstSaveSuspended = true
          firstSaveResume = continuation
          defer { firstSaveWaiters.removeAll() }
          return firstSaveWaiters
        }
        for waiter in waiters { waiter.resume() }
      }
    }
    if let saveError { throw saveError }
    value = profiles
  }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }

  func waitUntilFirstSaveIsSuspended() async {
    if lock.withLock({ firstSaveSuspended }) { return }
    await withCheckedContinuation { continuation in
      let resumeImmediately = lock.withLock { () -> Bool in
        if firstSaveSuspended { return true }
        firstSaveWaiters.append(continuation)
        return false
      }
      if resumeImmediately { continuation.resume() }
    }
  }

  func resumeFirstSave() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { firstSaveResume = nil }
      return firstSaveResume
    }
    continuation?.resume()
  }
}

private final class TransactionSessionStore: SessionPersisting, @unchecked Sendable {
  var value: AudioSessionSnapshot?
  private let lock = NSLock()
  private var saves = 0
  var saveCount: Int { lock.withLock { saves } }
  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws {
    lock.withLock {
      value = snapshot
      saves += 1
    }
  }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class TransactionDevicePresetsStore: DeviceVolumePresetsPersisting, @unchecked Sendable {
  var value = DeviceVolumePresets()
  var saveCount = 0
  var saveError: Error?

  func load() -> DeviceVolumePresets { value }
  func save(_ presets: DeviceVolumePresets) async throws {
    if let saveError { throw saveError }
    value = presets
    saveCount += 1
  }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class TransactionLoginItemService: LoginItemServicing {
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

// MARK: - A hold Waves cannot release stays visible on an excluded row

@MainActor
@Test func anExcludedAppWavesCannotLetGoOfShowsItIsHeldSilentAtOnceAndThroughARefresh() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.4)])
  try await fixture.installInitialRoutes()
  let snapshot = await fixture.backend.currentSnapshot()
  let preferencesStore = TransactionPreferencesStore()
  preferencesStore.value.hasCompletedPrivacySetup = true
  preferencesStore.value.appAudioIntentMigrationVersion = 1
  let sessionStore = TransactionSessionStore()
  sessionStore.value = snapshot
  let store = AppStore(
    backend: fixture.backend,
    preferencesStore: preferencesStore,
    profileStore: TransactionProfilesStore(),
    sessionStore: sessionStore,
    loginItemService: TransactionLoginItemService(),
    deviceVolumePresetsStore: TransactionDevicePresetsStore(),
    initialStartupState: .running
  )

  // Excluding the app releases its route, but its tap will neither un-mute
  // nor go away: the app is silent until Waves quits.
  fixture.events.failNextMuteReleases(1_000)
  fixture.events.failNextStops(1_000)
  let app = try #require(store.session.apps.first)
  store.setExcluded(true, for: app)
  await store.drainAppIntentTransactions()
  #expect(fixture.events.hearing("app.a") == "silent")

  func expectHeldRow(_ moment: String) {
    let row = store.session.apps.first
    #expect(row?.isHeldSilentByWaves == true, "\(moment)")
    #expect(row?.routingState == .error, "\(moment)")
    #expect(row?.notes?.contains("could not release its hold on App app.a's sound") == true, "\(moment)")
  }
  expectHeldRow("right after the exclusion")
  // Diagnostics says so now too, not after the next maintenance pass.
  let report = await fixture.backend.diagnosticsReport(reprobeCaptureAuthorization: false)
  #expect(report.checks.first { $0.title == "Closing audio routes" }?.status == .failed)

  _ = await store.startRefresh(announce: false, reevaluateAutomation: false)?.value
  expectHeldRow("after a refresh")
  _ = await store.shutdown()
}

// MARK: - Slider drag latency (1.4 D1)

@MainActor
@Test func draggingTheVolumeSliderMovesAudioBeforeTheDragEnds() async {
  // Through 1.3.1 setDesiredVolume only moved the on-screen projection; the sole
  // path to the backend was commitDesiredVolume on mouse-up, so the *sound*
  // jumped when the user let go instead of following the handle.
  let device = transactionTestDevice()
  let app = transactionTestApp(desiredVolume: 0.4)
  let fixture = makeTransactionFixture(apps: [app], device: device)

  fixture.store.setDesiredVolume(0.7, for: app)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(!intents.isEmpty, "a drag must reach the backend before it is committed")
  #expect(intents.last?.desiredVolume == 0.7)

  // ...but a drag is not a decision: nothing is persisted until the commit.
  #expect(fixture.preferencesStore.value.appAudioIntents[app.logicalID] == nil)
  #expect(fixture.store.toasts.isEmpty, "a drag must not toast per frame")
}

@MainActor
@Test func onlyTheFinalDragValueSurvivesTheDebounce() async {
  let device = transactionTestDevice()
  let app = transactionTestApp(desiredVolume: 0.4)
  let fixture = makeTransactionFixture(apps: [app], device: device)

  // A sweep across the slider must not submit a transaction per frame.
  for value: Float in [0.5, 0.55, 0.6, 0.65, 0.7] {
    fixture.store.setDesiredVolume(value, for: app)
  }
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count < 5, "the sweep submitted \(intents.count) intents; expected coalescing")
  #expect(intents.last?.desiredVolume == 0.7, "the value the user landed on must win")
}

@MainActor
@Test func committingAfterADragPersistsExactlyOnce() async {
  let device = transactionTestDevice()
  let app = transactionTestApp(desiredVolume: 0.4)
  let fixture = makeTransactionFixture(apps: [app], device: device)

  fixture.store.setDesiredVolume(0.7, for: app)
  fixture.store.commitDesiredVolume(for: app)
  await fixture.store.drainAppIntentTransactions()

  // The commit is still the only boundary that writes the user's intent.
  #expect(fixture.preferencesStore.value.appAudioIntents[app.logicalID]?.desiredVolume == 0.7)
  #expect(
    fixture.store.toasts.count { $0.title == "Managed route active" } == 1,
    "exactly one confirmation for the whole gesture"
  )
}

@MainActor
@Test func unmanagedAppsAreNotRoutedMidDrag() async {
  // Applying to an unmanaged app can build — or rebuild — a tap and aggregate
  // device. Mid-drag that is an audible dropout, so intermediate nudges are
  // restricted to routes that already exist; the commit does that work once.
  let device = transactionTestDevice()
  var app = transactionTestApp(desiredVolume: 0.4)
  app.routingState = .live
  let fixture = makeTransactionFixture(apps: [app], device: device)

  fixture.store.setDesiredVolume(0.7, for: app)
  await fixture.store.drainAppIntentTransactions()

  #expect(await fixture.backend.recordedIntents().isEmpty)

  // The commit still routes it, so nothing is lost.
  fixture.store.commitDesiredVolume(for: app)
  await fixture.store.drainAppIntentTransactions()
  #expect(await fixture.backend.recordedIntents().last?.desiredVolume == 0.7)
}

@MainActor
@Test func volumeDragStopsWhenItsManagedRouteDisappears() async {
  let device = transactionTestDevice()
  let managedApp = transactionTestApp(desiredVolume: 0.4)
  var liveApp = managedApp
  liveApp.routingState = .live
  let fixture = makeTransactionFixture(
    apps: [managedApp],
    device: device,
    refreshApps: [liveApp]
  )

  fixture.store.setDesiredVolume(0.6, for: managedApp)
  fixture.store.refresh(announce: false)
  await waitForRefresh(fixture.store)
  await fixture.store.drainAppIntentTransactions()

  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(fixture.store.trackedAppIntentTaskCount == 0)
}

@MainActor
@Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
func nonFiniteSliderValuesEmitUnityVolume(nonFiniteValue: Float) async throws {
  let app = transactionTestApp(desiredVolume: 0.5)
  let fixture = makeTransactionFixture(apps: [app], device: transactionTestDevice())

  fixture.store.setDesiredVolume(nonFiniteValue, for: app)
  #expect(fixture.store.session.apps.first?.desiredVolume == 1)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count == 1)
  let intent = try #require(intents.first)
  #expect(intent.appID == app.logicalID)
  #expect(intent.desiredVolume == 1)
  #expect(intent.volumeBoost == app.volumeBoost)
  #expect(fixture.store.session.apps.first?.desiredVolume == 1)
}

@MainActor
@Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
func nonFiniteCommitsPreserveTheFreshFixtureVolume(nonFiniteValue: Float) async throws {
  let app = transactionTestApp(desiredVolume: 0.5)
  let fixture = makeTransactionFixture(apps: [app], device: transactionTestDevice())

  // No slider call may sanitize the state before this direct commit.
  fixture.store.commitDesiredVolume(nonFiniteValue, for: app)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count == 1)
  let intent = try #require(intents.first)
  #expect(intent.appID == app.logicalID)
  #expect(intent.desiredVolume == 0.5)
  #expect(intent.volumeBoost == app.volumeBoost)
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.5)
}

@MainActor
@Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
func nonFiniteBoostsEmitUnityBoost(nonFiniteValue: Float) async throws {
  let app = transactionTestApp(desiredVolume: 0.5, volumeBoost: 2)
  let fixture = makeTransactionFixture(apps: [app], device: transactionTestDevice())

  fixture.store.setVolumeBoost(nonFiniteValue, for: app)
  await fixture.store.drainAppIntentTransactions()

  let intents = await fixture.backend.recordedIntents()
  #expect(intents.count == 1)
  let intent = try #require(intents.first)
  #expect(intent.appID == app.logicalID)
  #expect(intent.volumeBoost == 1)
  #expect(intent.desiredVolume == 0.5)
  #expect(fixture.store.session.apps.first?.volumeBoost == 1)
}

@MainActor
@Test func unmanagedVolumeEventCancelsAnEarlierManagedDebounce() async {
  let device = transactionTestDevice()
  let managedApp = transactionTestApp(desiredVolume: 0.4)
  var liveApp = managedApp
  liveApp.routingState = .live
  let fixture = makeTransactionFixture(
    apps: [managedApp],
    device: device,
    refreshApps: [liveApp]
  )

  fixture.store.setDesiredVolume(0.6, for: managedApp)
  fixture.store.refresh(announce: false)
  await waitForRefresh(fixture.store)
  fixture.store.setDesiredVolume(0.7, for: liveApp)
  await fixture.store.drainAppIntentTransactions()

  #expect(await fixture.backend.recordedIntents().isEmpty)
  #expect(fixture.store.trackedAppIntentTaskCount == 0)
}

@Test(arguments: [nil, false, true] as [Bool?])
func diagnosticsMentionTheMicrophoneOnlyWhileThatModeIsOn(detected: Bool?) {
  let text = DiagnosticsExportFormatter.format(
    metadata: DiagnosticsMetadata(bundleInfo: [:], operatingSystemVersion: "Version 27.0"),
    captureAuthorization: nil,
    session: .empty,
    apps: [],
    availableOutputDeviceCount: 0,
    diagnostics: nil,
    persistenceFailureCount: 0,
    lastPersistenceError: nil,
    shutdownResult: nil,
    callDetection: detected.map { CallDetectionDiagnostics(isDetected: $0, appNames: $0 ? ["Zoom"] : []) }
  )
  switch detected {
  case nil:
    #expect(!text.lowercased().contains("microphone"))
    #expect(!text.contains("Call detection"))
  case false?:
    #expect(text.contains("Detected: no"))
    #expect(!text.contains("By [app name]"))
  case true?:
    #expect(text.contains("Detected: yes"))
    #expect(text.contains("By [app name]: Zoom"))
  }
}
