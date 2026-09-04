import Testing
import WavesAudioCore

@testable import Waves

@Suite("LaunchPerformanceRecorderTests", .serialized)
struct LaunchPerformanceRecorderTests {
  @MainActor
  @Test func launchMilestonesAreOrderedAndRecordedOnce() async throws {
    let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)

    recorder.mark(.processInit)
    try await Task.sleep(for: .milliseconds(1))
    recorder.mark(.storeReady)
    recorder.mark(.storeReady)
    try await Task.sleep(for: .milliseconds(1))
    recorder.mark(.backendStarted)

    let samples = recorder.snapshot
    #expect(samples.map(\.milestone) == [.processInit, .storeReady, .backendStarted])
    #expect(samples.map(\.elapsed).allSatisfy { $0 >= .zero })
    #expect(samples[0].elapsed <= samples[1].elapsed)
    #expect(samples[1].elapsed <= samples[2].elapsed)
  }

  @MainActor
  @Test func launchMilestoneOutputContainsOnlyFixedNamesAndDurations() {
    let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)
    let privateValues = ["Jonathan's Browser", "com.example.private", "0.731"]

    for milestone in LaunchMilestone.allCases {
      recorder.mark(milestone)
    }

    let output = recorder.snapshotDescription
    for milestone in LaunchMilestone.allCases {
      #expect(output.contains(milestone.outputName))
    }
    for privateValue in privateValues {
      #expect(!output.contains(privateValue))
    }
  }

  @MainActor
  @Test func controlConfirmationMustMatchTheFirstSubmittedTransaction() async throws {
    let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)

    recorder.controlSubmitted(appID: "private.confirmed", generation: 2)
    try await Task.sleep(for: .milliseconds(1))
    recorder.controlFinished(appID: "private.unrelated", generation: 2, confirmed: true)
    #expect(recorder.snapshot.map(\.milestone) == [.firstControlSubmitted])

    recorder.controlFinished(appID: "private.confirmed", generation: 2, confirmed: true)
    let controls = recorder.snapshot.filter {
      $0.milestone == .firstControlSubmitted || $0.milestone == .firstControlConfirmed
    }
    #expect(controls.map(\.milestone) == [.firstControlSubmitted, .firstControlConfirmed])
    #expect(controls[0].elapsed <= controls[1].elapsed)

    #expect(recorder.snapshot.filter { $0.milestone == .firstControlConfirmed }.count == 1)
    #expect(!recorder.snapshotDescription.contains("private."))
  }

  @MainActor
  @Test func failedOrSupersededFirstControlCannotBeConfirmedByALaterTransaction() {
    let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)

    recorder.controlSubmitted(appID: "private.same-app", generation: 10)
    recorder.controlSubmitted(appID: "private.same-app", generation: 11)
    recorder.controlFinished(appID: "private.same-app", generation: 10, confirmed: false)
    recorder.controlFinished(appID: "private.same-app", generation: 11, confirmed: true)

    #expect(recorder.snapshot.map(\.milestone) == [.firstControlSubmitted])
  }

  @MainActor
  @Test func appStoreHooksExcludeStartupRestoreAndConfirmReturnedBackendState() async {
    let recorder = LaunchPerformanceRecorder(signpostsEnabled: false)
    let store = makeLaunchRecorderStore()
    let app = store.session.apps[0]

    _ = await store.startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(isMuted: false),
      reason: .startupRestore,
      persistencePolicy: .none,
      feedbackPolicy: .none,
      optimistic: false,
      performanceRecorder: recorder
    ).value
    #expect(recorder.snapshot.isEmpty)

    _ = await store.startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(isMuted: true),
      reason: .userEdit,
      persistencePolicy: .none,
      feedbackPolicy: .none,
      optimistic: false,
      performanceRecorder: recorder
    ).value
    #expect(
      recorder.snapshot.map(\.milestone)
        == [.firstControlSubmitted, .firstControlConfirmed]
    )
  }
}

@MainActor
private func makeLaunchRecorderStore() -> AppStore {
  let app = AudioApp(
    id: "runtime.recorder",
    logicalID: "com.example.recorder",
    displayName: "Recorder Fixture",
    category: .media,
    desiredVolume: 0.8,
    appliedVolume: 0.8,
    routingState: .managed
  )
  let snapshot = AudioSessionSnapshot(
    apps: [app],
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.urlSchemeAutomationAcknowledged = true
  preferences.appAudioIntentMigrationVersion = 1
  return AppStore(
    backend: PreviewAudioControlBackend(snapshot: snapshot),
    preferencesStore: LaunchRecorderPreferencesStore(value: preferences),
    profileStore: LaunchRecorderProfilesStore(),
    sessionStore: LaunchRecorderSessionStore(value: snapshot),
    loginItemService: LaunchRecorderLoginItemService(),
    deviceVolumePresetsStore: LaunchRecorderPresetsStore(),
    initialStartupState: .running
  )
}

private struct LaunchRecorderPreferencesStore: PreferencesPersisting {
  let value: UserPreferences
  func load() -> UserPreferences { value }
  func save(_ preferences: UserPreferences) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private struct LaunchRecorderProfilesStore: ProfilesPersisting {
  func load(defaults: [Profile]) -> [Profile] { defaults }
  func save(_ profiles: [Profile]) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private struct LaunchRecorderSessionStore: SessionPersisting {
  let value: AudioSessionSnapshot
  func load() -> AudioSessionSnapshot? { value }
  func save(_ snapshot: AudioSessionSnapshot) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private struct LaunchRecorderPresetsStore: DeviceVolumePresetsPersisting {
  func load() -> DeviceVolumePresets { DeviceVolumePresets() }
  func save(_ presets: DeviceVolumePresets) async throws {}
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class LaunchRecorderLoginItemService: LoginItemServicing {
  var status: LoginItemStatus {
    LoginItemStatus(isEnabled: false, isUserIntentEnabled: false, statusDescription: "Disabled")
  }
  func setEnabled(_ enabled: Bool) throws {}
  func openSystemSettingsLoginItems() {}
}
