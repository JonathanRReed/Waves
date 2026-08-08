import AudioToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func p11UnverifiedWaveLinkIdentityDoesNotBlockReattachment() {
  p1Characterization("P1.1: Task 2 must preserve monitor-only reattachment until router identity is verified.") {
    let unverifiedWaveLink = AudioApp(
      id: "runtime.unverified-wave-link",
      logicalID: "unverified.wave-link",
      pid: 44,
      bundleID: "com.elgato.WaveLink3",
      displayName: "Unverified Wave Link",
      category: .unknown,
      isActive: true,
      routingState: .live,
      compatibility: .supported
    )

    #expect(
      AppDiscoveryPolicy.competingAudioRouterName(
        for: "us.zoom.xos",
        among: [unverifiedWaveLink]
      ) == nil
    )
  }
}

@Test func p12RendererStopFailureRestoresTapMutingBeforeItReturns() {
  p1Characterization("P1.2: Task 2 must roll tap muting back after renderer stop fails.") {
    var events: [String] = []

    let result = MutingTapTeardownPreparation.perform(
      makeOriginalAudioAudible: {
        events.append("unmute-tap")
        return noErr
      },
      stopIOProc: {
        events.append("stop-io")
        return -1
      },
      deactivateRenderer: {
        events.append("deactivate-renderer")
      }
    )

    #expect(!result.originalAudioIsFailOpen)
    #expect(events == ["unmute-tap", "stop-io", "restore-tap-mute"])
  }
}

@Test func p13GeometryMismatchSchedulesARecoveryInsteadOfOnlyLogging() throws {
  try p1Characterization("P1.3: Task 2 must schedule bounded geometry recovery from the callback mismatch signal.") {
    let source = try String(
      contentsOf: workspaceAudioBackendURL(),
      encoding: .utf8
    )
    let mismatchHandling = try #require(
      source.range(of: "if let detail = controller.takeGeometryMismatchDiagnostic()")
    )
    let nextRouteMaintenance = try #require(
      source.range(
        of: "guard controller.isActive else {\n        routeIDsNeedingRebuild.insert(appID)"
      )
    )
    let handlingRegion = source[mismatchHandling.lowerBound..<nextRouteMaintenance.lowerBound]

    #expect(handlingRegion.contains("routeIDsNeedingRebuild.insert(appID)"))
  }
}

@Test func p14RouterReleaseIsNotBoundToTheFiveSecondMaintenancePoll() throws {
  try p1Characterization("P1.4: Task 2 must replace the five-second router maintenance poll with debounced observation.") {
    let source = try String(
      contentsOf: workspaceAudioBackendURL(),
      encoding: .utf8
    )
    let isBoundToFiveSecondMaintenancePoll = source.contains(
      "private let routeMaintenanceTickInterval = 20"
    )

    #expect(!isBoundToFiveSecondMaintenancePoll)
  }
}

/// Set `WAVES_P1_CHARACTERIZATION_MODE=red` to replay a P1 assertion without
/// its planned-failure wrapper and preserve a pre-fix receipt. This is test-only
/// evidence plumbing, not a production behavior switch.
private func p1Characterization(
  _ knownIssue: Comment,
  body: () throws -> Void
) rethrows {
  if ProcessInfo.processInfo.environment["WAVES_P1_CHARACTERIZATION_MODE"] == "red" {
    try body()
  } else {
    withKnownIssue(knownIssue, body)
  }
}

private func workspaceAudioBackendURL(
  filePath: String = #filePath
) -> URL {
  URL(fileURLWithPath: filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Waves/Services/Audio/WorkspaceAudioControlBackend.swift")
}
