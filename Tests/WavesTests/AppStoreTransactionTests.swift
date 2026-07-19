import Foundation
import Testing
import WavesAudioCore

@testable import Waves

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
  await fixture.store.drainAppIntentTransactions()

  await fixture.backend.resumeFirstIntent()
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
  await fixture.store.drainAppIntentTransactions()
  fixture.preferencesStore.resumeFirstSave()
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
  #expect(result?.rows.map(\.outcome) == [
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
  #expect(fixture.store.preferences.appAudioIntents["profile.offline"] == PersistedAppAudioIntent(
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
      .getVolumeSettings(for: "profile.offline", deviceID: device.id) == AppVolumeSettings(
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
  #expect(fixture.store.toasts.contains {
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
      ProfileEntry(appID: "offline.new", desiredVolume: 0.46, volumeBoost: 2.75),
    ]
  )

  fixture.store.applyProfile(profile)
  await fixture.store.drainAppIntentTransactions()

  #expect(fixture.store.preferences.appAudioIntents["offline.new"] == PersistedAppAudioIntent(
    appID: "offline.new",
    desiredVolume: 0.46,
    isMuted: false,
    volumeBoost: 2.75
  ))
  #expect(
    fixture.store.deviceVolumePresets
      .getVolumeSettings(for: "offline.new", deviceID: device.id) == AppVolumeSettings(
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

  #expect(fixture.store.lastProfileApplyResult?.rows.map(\.outcome) == [
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
  #expect(fixture.store.toasts.contains {
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

  fixture.store.applyProfile(Profile(
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
  fixture.store.applyProfile(Profile(
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
  fixture.store.applyProfile(Profile(
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

  fixture.store.applyProfile(Profile(
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

  fixture.store.applyProfile(Profile(
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

  fixture.store.applyProfile(Profile(
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
  #expect(fixture.store.toasts.contains {
    $0.title == "Profile applied with errors"
      && $0.detail?.contains("settings not saved") == true
      && $0.detail?.contains("device preset not saved") == true
  })
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
  #expect(!fixture.store.toasts.contains { $0.title == "Auto-paused media" })
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
private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async {
  for _ in 0..<10_000 {
    if await predicate() { return }
    await Task.yield()
  }
  Issue.record("Timed out waiting for asynchronous test condition")
}

private func transactionTestApp(
  id: String = "test.app",
  desiredVolume: Float = 0.4,
  isMuted: Bool = false,
  volumeBoost: Float = 2,
  targetDeviceUID: String? = "device.original"
) -> AudioApp {
  AudioApp(
    id: "\(id).runtime",
    logicalID: id,
    pid: 42,
    bundleID: id,
    displayName: "Test App",
    category: .media,
    isActive: true,
    desiredVolume: desiredVolume,
    appliedVolume: isMuted ? 0 : desiredVolume,
    isMuted: isMuted,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: volumeBoost,
    targetDeviceUID: targetDeviceUID
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
  initialStartupState: AppStartupState = .running
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
    resultGenerationOffset: resultGenerationOffset
  )
  let preferencesStore = TransactionPreferencesStore()
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
    profileStore: TransactionProfilesStore(),
    sessionStore: sessionStore,
    loginItemService: TransactionLoginItemService(),
    deviceVolumePresetsStore: presetsStore,
    initialStartupState: initialStartupState
  )
  return TransactionFixture(
    store: store,
    backend: backend,
    preferencesStore: preferencesStore,
    presetsStore: presetsStore
  )
}

private struct TransactionFixture {
  let store: AppStore
  let backend: TransactionBackend
  let preferencesStore: TransactionPreferencesStore
  let presetsStore: TransactionDevicePresetsStore
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
  private let refreshSnapshot: AudioSessionSnapshot?
  private var outcomes: [AppIntentApplyOutcome]
  private var profileOutcomes: [ProfileRowApplyOutcome]
  private let suspendFirstIntent: Bool
  private let suspendFirstProfile: Bool
  private let resultGenerationOffset: UInt64
  private var intents: [AppRouteIntent] = []
  private var profileCalls: [(profile: Profile, generation: UInt64)] = []
  private var latestGenerationByAppID: [String: UInt64] = [:]
  private var completedIntents = 0
  private var diagnosticsCalls = 0
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
    resultGenerationOffset: UInt64
  ) {
    self.snapshot = snapshot
    self.refreshSnapshot = refreshSnapshot
    self.outcomes = outcomes
    self.profileOutcomes = profileOutcomes
    self.suspendFirstIntent = suspendFirstIntent
    self.suspendFirstProfile = suspendFirstProfile
    self.resultGenerationOffset = resultGenerationOffset
  }

  func recordedIntents() -> [AppRouteIntent] { intents }
  func recordedProfileCalls() -> [(profile: Profile, generation: UInt64)] { profileCalls }
  func completedIntentCount() -> Int { completedIntents }
  func diagnosticsCallCount() -> Int { diagnosticsCalls }

  func waitUntilFirstIntentIsSuspended() async {
    if firstIntentIsSuspended { return }
    await withCheckedContinuation { continuation in
      suspensionWaiters.append(continuation)
    }
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
    let outcome = outcomes.isEmpty
      ? (intent.isExcluded ? AppIntentApplyOutcome.excluded : .applied)
      : outcomes.removeFirst()
    let latestGeneration = latestGenerationByAppID[intent.appID] ?? 0
    if intent.generation >= latestGeneration {
      latestGenerationByAppID[intent.appID] = intent.generation
    }

    if callNumber == 1, suspendFirstIntent {
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
    if let refreshSnapshot { snapshot = refreshSnapshot }
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
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .membershipOnly,
          resultingApp: nil
        ))
        continue
      }

      if latestGenerationByAppID[entry.appID].map({ $0 > generation }) == true {
        rows.append(ProfileRowApplyResult(
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
        outcome = snapshot.apps.contains(where: { $0.logicalID == entry.appID })
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
          snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted
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
      rows.append(ProfileRowApplyResult(
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
    return DiagnosticsReport(summary: "Transaction test", checks: [])
  }
  func availableOutputDevices() async -> [AudioDevice] {
    snapshot.currentDevice.map { [$0] } ?? []
  }
  func setDefaultOutputDevice(uid: String) async throws {}
  func setOutputDevice(uid: String?, forAppID appID: String) async throws {}
  func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool) async {}
  func audioLevels() async -> [String: AudioLevels] { [:] }
}

private enum TransactionTestError: LocalizedError {
  case writeFailed

  var errorDescription: String? { "Injected write failure" }
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
      let error = saveErrors.indices.contains(attempt - 1)
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
  func load(defaults: [Profile]) -> [Profile] { value }
  func save(_ profiles: [Profile]) async throws { value = profiles }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class TransactionSessionStore: SessionPersisting, @unchecked Sendable {
  var value: AudioSessionSnapshot?
  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws { value = snapshot }
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
