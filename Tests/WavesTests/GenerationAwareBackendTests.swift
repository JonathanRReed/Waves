import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func previewIntentPrefersLogicalIdentityAndRejectsOlderGenerations() async {
  let collision = AudioApp(
    id: "shared-key",
    logicalID: "other-logical-id",
    displayName: "Collision",
    category: .unknown,
    desiredVolume: 0.9,
    compatibility: .supported
  )
  let intended = AudioApp(
    id: "runtime-id",
    logicalID: "shared-key",
    displayName: "Intended",
    category: .media,
    desiredVolume: 0.3,
    compatibility: .supported
  )
  let backend = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [collision, intended]))

  let accepted = await backend.applyAppIntent(testIntent(
    appID: "shared-key",
    volume: 0.4,
    generation: 20
  ))
  let acceptedSnapshot = await backend.currentSnapshot()
  let rejected = await backend.applyAppIntent(testIntent(
    appID: "shared-key",
    volume: 0.1,
    generation: 19,
    isExcluded: true
  ))
  let rejectedSnapshot = await backend.currentSnapshot()

  #expect(accepted.outcome == .applied)
  #expect(accepted.resultingApp?.logicalID == "shared-key")
  #expect(acceptedSnapshot.apps[0].desiredVolume == 0.9)
  #expect(acceptedSnapshot.apps[1].desiredVolume == 0.4)
  #expect(rejected.outcome == .superseded)
  #expect(rejectedSnapshot == acceptedSnapshot)
}

@Test func previewExclusionReleasesRouteWithoutApplyingControlValues() async {
  let app = AudioApp(
    id: "runtime.app",
    logicalID: "logical.app",
    displayName: "App",
    category: .media,
    isActive: true,
    peakLevel: 0.7,
    rmsLevel: 0.5,
    desiredVolume: 0.6,
    appliedVolume: 0.6,
    isMuted: false,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: 2,
    targetDeviceUID: "device.old"
  )
  let backend = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [app]))
  let exclusion = AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.1,
    isMuted: true,
    volumeBoost: 4,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: "device.new",
    generation: 1,
    reason: .userEdit,
    isExcluded: true
  )

  let result = await backend.applyAppIntent(exclusion)
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .excluded)
  #expect(resultingApp.desiredVolume == 0.6)
  #expect(resultingApp.isMuted == false)
  #expect(resultingApp.volumeBoost == 2)
  #expect(resultingApp.targetDeviceUID == "device.old")
  #expect(resultingApp.routingState == .monitorOnly)
  #expect(resultingApp.appliedVolume == nil)
  #expect(resultingApp.peakLevel == 0)
  #expect(resultingApp.rmsLevel == 0)
}

@Test func workspaceExclusionSkipsRouteApplicationAndPreservesControls() async {
  let app = managedTestApp(
    desiredVolume: 0.6,
    volumeBoost: 2,
    targetDeviceUID: "device.old"
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )

  let result = await backend.applyAppIntent(AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.1,
    isMuted: true,
    volumeBoost: 4,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: "device.new",
    generation: 1,
    reason: .userEdit,
    isExcluded: true
  ))
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .excluded)
  #expect(await recorder.count() == 0)
  #expect(resultingApp.desiredVolume == 0.6)
  #expect(resultingApp.isMuted == false)
  #expect(resultingApp.volumeBoost == 2)
  #expect(resultingApp.targetDeviceUID == "device.old")
  #expect(resultingApp.routingState == .monitorOnly)
  #expect(resultingApp.appliedVolume == nil)
}

@Test func workspaceIntentDoesNotCommitStaleWorkAfterSuspension() async {
  let gate = IntentRouteSuspensionGate()
  let app = managedTestApp(desiredVolume: 0.5)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, _ in
      if stagedApp.desiredVolume == 0.2 {
        await gate.suspend()
      }
    }
  )

  let olderTask = Task {
    await backend.applyAppIntent(testIntent(
      appID: app.logicalID,
      volume: 0.2,
      generation: 1
    ))
  }
  await gate.waitUntilSuspended()

  let newer = await backend.applyAppIntent(testIntent(
    appID: app.logicalID,
    volume: 0.8,
    generation: 2
  ))
  let snapshotAfterNewer = await backend.currentSnapshot()
  await gate.resume()
  let older = await olderTask.value
  let finalSnapshot = await backend.currentSnapshot()

  #expect(newer.outcome == .applied)
  #expect(older.outcome == .superseded)
  #expect(snapshotAfterNewer.apps[0].desiredVolume == 0.8)
  #expect(finalSnapshot == snapshotAfterNewer)
}

@Test func workspaceIntentFailurePreservesConfirmedControlsAndSurfacesDetail() async {
  let app = managedTestApp(
    desiredVolume: 0.55,
    isMuted: true,
    volumeBoost: 2.5,
    targetDeviceUID: "device.confirmed"
  )
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { _, _ in
      throw BackendError.managedRouteUnavailable("Deterministic route failure")
    }
  )

  let result = await backend.applyAppIntent(AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.1,
    isMuted: false,
    volumeBoost: 4,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: "device.unconfirmed",
    generation: 3,
    reason: .automation
  ))
  let resultingApp = await backend.currentSnapshot().apps[0]

  #expect(result.outcome == .failed)
  #expect(result.detail == "Deterministic route failure")
  #expect(resultingApp.desiredVolume == 0.55)
  #expect(resultingApp.isMuted == true)
  #expect(resultingApp.volumeBoost == 2.5)
  #expect(resultingApp.targetDeviceUID == "device.confirmed")
  #expect(resultingApp.appliedVolume == 0)
  #expect(resultingApp.routingState == .error)
  #expect(resultingApp.notes == "Deterministic route failure")
}

@Test func protocolExistentialsDispatchToWorkspaceAndPreviewIntentOverrides() async {
  let collision = AudioApp(
    id: "dispatch-key",
    logicalID: "other-logical-id",
    displayName: "Collision",
    category: .unknown,
    desiredVolume: 0.9,
    compatibility: .supported
  )
  let intended = AudioApp(
    id: "runtime.dispatch",
    logicalID: "dispatch-key",
    displayName: "Intended",
    category: .media,
    desiredVolume: 0.3,
    compatibility: .supported
  )
  let recorder = AppliedIntentRecorder()
  let workspaceConcrete = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [collision, intended]),
    intentRouteApplyOverride: { app, equalizer in
      await recorder.record(app: app, equalizer: equalizer)
    }
  )
  let workspace: any AudioControlBackend = workspaceConcrete
  let previewConcrete = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [intended]))
  let preview: any AudioControlBackend = previewConcrete
  let intent = testIntent(appID: "dispatch-key", volume: 0.45, generation: 8)

  let workspaceResult = await workspace.applyAppIntent(intent)
  let previewResult = await preview.applyAppIntent(intent)
  let recordedApp = await recorder.lastApp()
  let workspaceSnapshot = await workspaceConcrete.currentSnapshot()

  #expect(workspaceResult.outcome == .applied)
  #expect(previewResult.outcome == .applied)
  #expect(recordedApp?.logicalID == "dispatch-key")
  #expect(workspaceSnapshot.apps[0].desiredVolume == 0.9)
  #expect(workspaceSnapshot.apps[1].desiredVolume == 0.45)
}

@Test func profileResultsStayOrderedAndMapEveryOutcome() async {
  let supported = AudioApp(
    id: "supported.runtime",
    logicalID: "supported.app",
    displayName: "Supported",
    category: .media,
    desiredVolume: 0.4,
    compatibility: .supported
  )
  let unsupported = AudioApp(
    id: "unsupported.runtime",
    logicalID: "unsupported.app",
    displayName: "Unsupported",
    category: .system,
    compatibility: .unsupported
  )
  let backend = PreviewAudioControlBackend(
    snapshot: testSnapshot(apps: [supported, unsupported])
  )
  let profile = Profile(
    name: "Ordered",
    entries: [
      ProfileEntry(appID: supported.logicalID),
      ProfileEntry(appID: "missing.app", desiredVolume: 0.2),
      ProfileEntry(appID: supported.logicalID, desiredVolume: 0.5),
      ProfileEntry(appID: supported.logicalID, desiredVolume: 0.5),
      ProfileEntry(appID: unsupported.logicalID, isMuted: true),
    ]
  )

  let result = await backend.applyProfileWithResults(profile, generation: 7)

  #expect(result.rows.map(\.entryIndex) == [0, 1, 2, 3, 4])
  #expect(result.rows.map(\.appID) == [
    supported.logicalID,
    "missing.app",
    supported.logicalID,
    supported.logicalID,
    unsupported.logicalID,
  ])
  #expect(result.rows.map(\.outcome) == [
    .membershipOnly,
    .unavailable,
    .applied,
    .noChange,
    .unsupported,
  ])
  #expect(result.rows.allSatisfy { $0.generation == 7 })

  _ = await backend.applyAppIntent(testIntent(
    appID: supported.logicalID,
    volume: 0.6,
    generation: 10
  ))
  let superseded = await backend.applyProfileWithResults(
    Profile(
      name: "Old",
      entries: [ProfileEntry(appID: supported.logicalID, desiredVolume: 0.1)]
    ),
    generation: 9
  )
  #expect(superseded.rows.map(\.outcome) == [.superseded])

  await backend.stop()
  let failed = await backend.applyProfileWithResults(
    Profile(
      name: "Stopped",
      entries: [ProfileEntry(appID: supported.logicalID, isMuted: true)]
    ),
    generation: 11
  )
  #expect(failed.rows.map(\.outcome) == [.failed])

  let mapped = [
    AppIntentApplyOutcome.applied,
    .noChange,
    .superseded,
    .excluded,
    .unavailable,
    .unsupported,
    .failed,
  ].map(ProfileRowApplyOutcome.init(appIntentOutcome:))
  #expect(mapped == [
    .applied,
    .noChange,
    .superseded,
    .excluded,
    .unavailable,
    .unsupported,
    .failed,
  ])
}

@Test func workspaceProfileResultsAreOrderedAndLegacyProfileSurfacesFailures() async {
  let supported = managedTestApp(desiredVolume: 0.4)
  let unsupported = AudioApp(
    id: "unsupported.runtime",
    logicalID: "unsupported.app",
    displayName: "Unsupported",
    category: .system,
    compatibility: .unsupported
  )
  let recorder = AppliedIntentRecorder()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [supported, unsupported]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )
  let profile = Profile(
    name: "Workspace Ordered",
    entries: [
      ProfileEntry(appID: supported.logicalID),
      ProfileEntry(appID: "missing.app", desiredVolume: 0.2),
      ProfileEntry(appID: supported.logicalID, isMuted: true),
      ProfileEntry(appID: unsupported.logicalID, volumeBoost: 2),
    ]
  )

  let result = await backend.applyProfileWithResults(profile, generation: 42)

  #expect(result.rows.map(\.entryIndex) == [0, 1, 2, 3])
  #expect(result.rows.map(\.outcome) == [
    .membershipOnly,
    .unavailable,
    .applied,
    .unsupported,
  ])
  #expect(result.rows.allSatisfy { $0.generation == 42 })
  #expect(await recorder.count() == 1)

  var legacyThrew = false
  do {
    _ = try await backend.applyProfile(Profile(
      name: "Unavailable",
      entries: [ProfileEntry(appID: "missing.app", desiredVolume: 0.3)]
    ))
  } catch {
    legacyThrew = true
  }
  #expect(legacyThrew)
}

@Test func legacyAdaptersAllocateNewGenerationsAndPreserveCompleteIntentFields() async throws {
  let app = managedTestApp(
    desiredVolume: 0.4,
    isMuted: true,
    volumeBoost: 2,
    targetDeviceUID: "device.old"
  )
  let preview = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [app]))
  _ = await preview.applyAppIntent(AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.5,
    isMuted: true,
    volumeBoost: 2,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: "device.old",
    generation: 100,
    reason: .automation
  ))

  try await preview.setDesiredVolume(0.7, forAppID: app.logicalID)
  try await preview.setOutputDevice(uid: "device.new", forAppID: app.logicalID)
  let afterLegacyCalls = await preview.currentSnapshot().apps[0]
  let stale = await preview.applyAppIntent(AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.1,
    isMuted: false,
    volumeBoost: 4,
    equalizerSettings: EqualizerSettings(isEnabled: true),
    targetDeviceUID: nil,
    generation: 100,
    reason: .automation
  ))

  #expect(afterLegacyCalls.desiredVolume == 0.7)
  #expect(afterLegacyCalls.isMuted == true)
  #expect(afterLegacyCalls.volumeBoost == 2)
  #expect(afterLegacyCalls.targetDeviceUID == "device.new")
  #expect(stale.outcome == .superseded)
  #expect(await preview.currentSnapshot().apps[0] == afterLegacyCalls)

  let recorder = AppliedIntentRecorder()
  let workspace = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
    }
  )
  try await workspace.setDesiredVolume(0.65, forAppID: app.logicalID)
  let stagedApp = await recorder.lastApp()

  #expect(stagedApp?.desiredVolume == 0.65)
  #expect(stagedApp?.isMuted == true)
  #expect(stagedApp?.volumeBoost == 2)
  #expect(stagedApp?.targetDeviceUID == "device.old")

  let profileFailed = await legacyProfileThrows(
    on: preview,
    profile: Profile(
      name: "Unavailable",
      entries: [ProfileEntry(appID: "missing.app", desiredVolume: 0.3)]
    )
  )
  #expect(profileFailed)
}

@Test func concurrentWorkspaceLegacyAdaptersComposeFromLatestAcceptedIntent() async throws {
  let gate = IntentRouteSuspensionGate()
  let recorder = AppliedIntentRecorder()
  let app = managedTestApp(desiredVolume: 0.5)
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: testSnapshot(apps: [app]),
    intentRouteApplyOverride: { stagedApp, equalizer in
      await recorder.record(app: stagedApp, equalizer: equalizer)
      if stagedApp.desiredVolume == 0.2, !stagedApp.isMuted {
        await gate.suspend()
      }
    }
  )

  let olderTask = Task {
    do {
      try await backend.setDesiredVolume(0.2, forAppID: app.logicalID)
      return false
    } catch {
      return true
    }
  }
  await gate.waitUntilSuspended()

  try await backend.setMuted(true, forAppID: app.logicalID)
  let afterNewer = await backend.currentSnapshot().apps[0]
  await gate.resume()
  let olderWasSuperseded = await olderTask.value
  let finalApp = await backend.currentSnapshot().apps[0]
  let lastStagedApp = await recorder.lastApp()

  #expect(olderWasSuperseded)
  #expect(lastStagedApp?.desiredVolume == 0.2)
  #expect(lastStagedApp?.isMuted == true)
  #expect(afterNewer.desiredVolume == 0.2)
  #expect(afterNewer.isMuted == true)
  #expect(finalApp == afterNewer)
}

@Test func stoppedPreviewBackendCanRestart() async throws {
  let app = managedTestApp(desiredVolume: 0.5)
  let backend = PreviewAudioControlBackend(snapshot: testSnapshot(apps: [app]))
  await backend.stop()

  let stoppedResult = await backend.applyAppIntent(testIntent(
    appID: app.logicalID,
    volume: 0.2,
    generation: 1
  ))
  try await backend.start()
  let restartedResult = await backend.applyAppIntent(testIntent(
    appID: app.logicalID,
    volume: 0.8,
    generation: 1
  ))

  #expect(stoppedResult.outcome == .failed)
  #expect(restartedResult.outcome == .applied)
  #expect(await backend.currentSnapshot().apps[0].desiredVolume == 0.8)
}

private func testSnapshot(apps: [AudioApp]) -> AudioSessionSnapshot {
  AudioSessionSnapshot(
    apps: apps,
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

private func managedTestApp(
  desiredVolume: Float,
  isMuted: Bool = false,
  volumeBoost: Float = 1,
  targetDeviceUID: String? = nil
) -> AudioApp {
  AudioApp(
    id: "runtime.app",
    logicalID: "logical.app",
    displayName: "Managed App",
    category: .media,
    desiredVolume: desiredVolume,
    appliedVolume: isMuted ? 0 : desiredVolume,
    isMuted: isMuted,
    routingState: .managed,
    compatibility: .supported,
    volumeBoost: volumeBoost,
    targetDeviceUID: targetDeviceUID
  )
}

private func testIntent(
  appID: String,
  volume: Float,
  generation: UInt64,
  isExcluded: Bool = false
) -> AppRouteIntent {
  AppRouteIntent(
    appID: appID,
    desiredVolume: volume,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: generation,
    reason: .automation,
    isExcluded: isExcluded
  )
}

private func legacyProfileThrows(
  on backend: PreviewAudioControlBackend,
  profile: Profile
) async -> Bool {
  do {
    _ = try await backend.applyProfile(profile)
    return false
  } catch {
    return true
  }
}

private actor IntentRouteSuspensionGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isSuspended = false

  func suspend() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      self.isSuspended = true
    }
  }

  func waitUntilSuspended() async {
    while !isSuspended {
      await Task.yield()
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
    isSuspended = false
  }
}

private actor AppliedIntentRecorder {
  private var apps: [AudioApp] = []
  private var equalizers: [EqualizerSettings] = []

  func record(app: AudioApp, equalizer: EqualizerSettings) {
    apps.append(app)
    equalizers.append(equalizer)
  }

  func lastApp() -> AudioApp? {
    apps.last
  }

  func count() -> Int {
    apps.count
  }
}
