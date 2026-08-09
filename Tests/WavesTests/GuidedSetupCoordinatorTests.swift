import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test @MainActor func permissionRequestRunsOnlyAfterExplicitPreflightContinue() async {
  let actions = GuidedSetupActionRecorder(
    facts: GuidedSetupFacts(
      hasAcceptedPrivacy: false,
      captureAuthorization: .undetermined,
      audioComponentInstalled: true,
      outputDeviceVisible: true,
      routeHealthReady: true,
      isAudioRunning: false
    )
  )
  let coordinator = GuidedSetupCoordinator()
  coordinator.update(facts: actions.facts)

  #expect(actions.permissionRequestCount == 0)
  await coordinator.performPrimaryAction(using: actions.actions)
  #expect(coordinator.phase == .permissionPreflight)
  #expect(actions.permissionRequestCount == 0)

  await coordinator.performPrimaryAction(using: actions.actions)
  #expect(actions.permissionRequestCount == 1)
}

@Test @MainActor func failedPrivacyConsentSaveReturnsToActionablePreflight() async {
  let actions = GuidedSetupActionRecorder(
    facts: GuidedSetupFacts(
      hasAcceptedPrivacy: false,
      captureAuthorization: .undetermined,
      audioComponentInstalled: true,
      outputDeviceVisible: true,
      routeHealthReady: true,
      isAudioRunning: false
    )
  )
  actions.acceptsPrivacy = false
  let coordinator = GuidedSetupCoordinator(initialPhase: .permissionPreflight)
  coordinator.update(facts: actions.facts)

  await coordinator.performPrimaryAction(using: actions.actions)

  #expect(actions.permissionRequestCount == 1)
  #expect(coordinator.phase == .permissionPreflight)
}

@Test @MainActor func readinessRecheckRetriesAudioStartupBeforeRefreshingFacts() async {
  let actions = GuidedSetupActionRecorder(
    facts: GuidedSetupFacts(
      hasAcceptedPrivacy: true,
      captureAuthorization: nil,
      audioComponentInstalled: false,
      outputDeviceVisible: false,
      routeHealthReady: false,
      isAudioRunning: false
    )
  )
  actions.acceptsPrivacy = true
  actions.startsAudio = true
  let coordinator = GuidedSetupCoordinator(initialPhase: .readiness)
  coordinator.update(facts: actions.facts)

  await coordinator.performRepair(.recheck, using: actions.actions)

  #expect(actions.permissionRequestCount == 1)
  #expect(actions.diagnosticsRefreshCount == 1)
  #expect(coordinator.facts.isAudioRunning)
}

@Test @MainActor func readinessShowsOnlyProblemsAndLabelsNonblockingRouteWarning() {
  let coordinator = GuidedSetupCoordinator(initialPhase: .readiness)
  coordinator.update(
    facts: GuidedSetupFacts(
      hasAcceptedPrivacy: true,
      captureAuthorization: .authorized,
      audioComponentInstalled: true,
      outputDeviceVisible: false,
      routeHealthReady: false,
      isAudioRunning: true
    )
  )

  #expect(coordinator.issues.map(\.id) == [.outputDevice, .managedRoutes])
  #expect(coordinator.issues.first?.severity == .blocking)
  #expect(coordinator.issues.last?.severity == .warning)
  #expect(coordinator.issues.last?.continuationLabel == "You can continue")
}

@Test @MainActor func stableCoreReadinessAdvancesWithoutRequiringHealthyRoutes() async {
  let clock = GuidedSetupTestClock()
  let coordinator = GuidedSetupCoordinator(
    initialPhase: .readiness,
    readinessStabilityInterval: .milliseconds(350),
    sleep: clock.sleep
  )
  coordinator.update(facts: .readyExceptForRouteRecovery)

  await clock.waitForSleeper()
  #expect(coordinator.phase == .readiness)
  clock.resumeAll()
  await waitUntil { coordinator.phase == .ready }
  #expect(coordinator.issues.map(\.id) == [.managedRoutes])
}

@Test @MainActor func readinessRegressionCancelsPendingAdvance() async {
  let clock = GuidedSetupTestClock()
  let coordinator = GuidedSetupCoordinator(
    initialPhase: .readiness,
    sleep: clock.sleep
  )
  coordinator.update(facts: .readyExceptForRouteRecovery)
  await clock.waitForSleeper()

  var regressed = GuidedSetupFacts.readyExceptForRouteRecovery
  regressed.outputDeviceVisible = false
  coordinator.update(facts: regressed)
  clock.resumeAll()
  await coordinator.drain()

  #expect(coordinator.phase == .readiness)
  #expect(coordinator.issues.map(\.id) == [.outputDevice, .managedRoutes])
}

@Test @MainActor func cancelAndDrainRetainCancellationInsensitiveWorkUntilSettlement() async {
  let clock = GuidedSetupTestClock()
  let coordinator = GuidedSetupCoordinator(
    initialPhase: .readiness,
    sleep: clock.sleep
  )
  coordinator.update(facts: .readyExceptForRouteRecovery)
  await clock.waitForSleeper()

  coordinator.cancel()
  #expect(coordinator.trackedTaskCount == 1)
  clock.resumeAll()
  await coordinator.drain()

  #expect(coordinator.trackedTaskCount == 0)
  #expect(coordinator.phase == .readiness)
}

@MainActor
private final class GuidedSetupActionRecorder {
  var facts: GuidedSetupFacts
  var acceptsPrivacy = true
  var startsAudio = false
  private(set) var permissionRequestCount = 0
  private(set) var diagnosticsRefreshCount = 0

  init(facts: GuidedSetupFacts) {
    self.facts = facts
  }

  var actions: GuidedSetupActions {
    GuidedSetupActions(
      acceptPrivacyAndStart: { [weak self] in
        guard let self else { return }
        self.permissionRequestCount += 1
        self.facts.hasAcceptedPrivacy = self.acceptsPrivacy
        if self.startsAudio {
          self.facts.captureAuthorization = .authorized
          self.facts.audioComponentInstalled = true
          self.facts.outputDeviceVisible = true
          self.facts.isAudioRunning = true
        }
      },
      currentFacts: { [weak self] in
        self?.facts ?? .empty
      },
      refreshDiagnostics: { [weak self] in
        self?.diagnosticsRefreshCount += 1
      }
    )
  }
}

private final class GuidedSetupTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Error>] = []

  func sleep(for _: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { continuations.append(continuation) }
    }
  }

  func waitForSleeper() async {
    while lock.withLock({ continuations.isEmpty }) {
      await Task.yield()
    }
  }

  func resumeAll() {
    let pending = lock.withLock {
      let result = continuations
      continuations.removeAll()
      return result
    }
    for continuation in pending { continuation.resume() }
  }
}

@MainActor
private func waitUntil(
  _ condition: @escaping @MainActor () -> Bool
) async {
  while !condition() { await Task.yield() }
}

private extension GuidedSetupFacts {
  static let empty = GuidedSetupFacts(
    hasAcceptedPrivacy: false,
    captureAuthorization: nil,
    audioComponentInstalled: false,
    outputDeviceVisible: false,
    routeHealthReady: false,
    isAudioRunning: false
  )

  static let readyExceptForRouteRecovery = GuidedSetupFacts(
    hasAcceptedPrivacy: true,
    captureAuthorization: .authorized,
    audioComponentInstalled: true,
    outputDeviceVisible: true,
    routeHealthReady: false,
    isAudioRunning: true
  )
}
