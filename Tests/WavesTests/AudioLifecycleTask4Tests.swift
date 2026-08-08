import AudioToolbox
import Testing
import WavesAudioCore

@testable import Waves

@Test func targetProcessFamilyRetiresDeadHelpersWithoutRebuildingCoveredRoute() {
  let controllerTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11, 12]
  )
  let liveTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11]
  )

  #expect(!controllerTarget.matches(liveTarget))
  #expect(controllerTarget.covers(liveTarget))
}

@Test func targetProcessFamilyRequiresRebuildForReturningHelperOrDifferentLogicalFamily() {
  let controllerTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11]
  )
  let returningHelper = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11, 12]
  )
  let reusedObjectIDFromAnotherFamily = TargetProcessFamily(
    logicalID: "com.example.other-browser",
    processObjectIDs: [11]
  )

  #expect(!controllerTarget.covers(returningHelper))
  #expect(!controllerTarget.matches(reusedObjectIDFromAnotherFamily))
  #expect(!controllerTarget.covers(reusedObjectIDFromAnotherFamily))
}

@Test func callbackRenderStateUsesPreallocatedAtomicValuesAndCoalescesGeometryRecovery() {
  let state = TapRenderStateBox(
    initialState: TapRenderState(
      volume: 0.5,
      volumeBoost: 2,
      isMuted: 0,
      isActive: 1,
      peakLevel: 0,
      rmsLevel: 0,
      analysisRMS: 0,
      voiceBandEnergy: 0,
      renderTick: 0
    )
  )

  state.markRenderTick()
  state.writeLevels(peakLevel: 0.8, rmsLevel: 0.4, analysisRMS: 0.3, voiceBandEnergy: 0.2)
  state.flagGeometryMismatch()
  state.flagGeometryMismatch()
  state.setInactive()

  #expect(state.read().renderTick == 1)
  #expect(state.read().peakLevel == 0.8)
  #expect(state.read().isActive == 0)
  #expect(state.consumeGeometryMismatch())
  #expect(!state.consumeGeometryMismatch())
}

@Test func competingRouterPolicyKeepsMixedOutputExclusionSeparateFromVerifiedOwnership() {
  let waveLink = AudioApp(
    id: "wave-link",
    logicalID: "com.elgato.WaveLink3",
    bundleID: "com.elgato.WaveLink3",
    displayName: "Wave Link",
    category: .media,
    compatibility: .supported
  )
  let ordinary = AudioApp(
    id: "ordinary",
    logicalID: "com.example.ordinary",
    bundleID: "com.example.ordinary",
    displayName: "Ordinary",
    category: .media,
    compatibility: .supported
  )

  #expect(CompetingRouterPolicy.mixedOutputExclusion(for: waveLink) != nil)
  #expect(CompetingRouterPolicy.upstreamOwnershipDetail(for: ordinary, conflict: nil) == nil)
}

@Test func injectedRouteLifecycleCompletesOneHundredCreateReuseRecoveryAndShutdownCycles() throws {
  let harness = RouteLifecycleCycleHarness.testing()

  try harness.run(cycles: 100)

  #expect(harness.counters.createdControllers == 200)
  #expect(harness.counters.reusedControllers == 100)
  #expect(harness.counters.helperExpansionRebuilds == 100)
  #expect(harness.counters.geometryRecoveries == 100)
  #expect(harness.counters.failedDisposals == 100)
  #expect(harness.counters.successfulDisposals == 200)
  #expect(harness.counters.liveControllers == 0)
  #expect(harness.counters.retainedCallbackOwners == 0)
  #expect(harness.counters.listenerRegistrations == 0)
  #expect(harness.counters.pendingRecoveryWork == 0)
}

private struct RouteLifecycleCycleCounters: Equatable {
  var createdControllers = 0
  var reusedControllers = 0
  var helperExpansionRebuilds = 0
  var geometryRecoveries = 0
  var failedDisposals = 0
  var successfulDisposals = 0
  var liveControllers = 0
  var retainedCallbackOwners = 0
  var listenerRegistrations = 0
  var pendingRecoveryWork = 0
}

/// An injected backend lifecycle fixture. It drives the real controller
/// teardown sequence and real listener lifecycle while replacing only native
/// calls that require a physical route.
private final class RouteLifecycleCycleHarness {
  private let listenerRecorder: LifecycleListenerRecorder
  private let listeners: RouterObservationListenerLifecycle
  private(set) var counters = RouteLifecycleCycleCounters()

  private init(
    listeners: RouterObservationListenerLifecycle,
    listenerRecorder: LifecycleListenerRecorder
  ) {
    self.listeners = listeners
    self.listenerRecorder = listenerRecorder
  }

  static func testing() -> RouteLifecycleCycleHarness {
    let recorder = LifecycleListenerRecorder()
    let listeners = RouterObservationListenerLifecycle(
      nativeCalls: RouterObservationListenerNativeCalls(
        add: { selector, _ in
          recorder.recordInstalled(selector)
          return noErr
        },
        remove: { selector, _ in
          recorder.recordRemoved(selector)
          return noErr
        }
      )
    )
    return RouteLifecycleCycleHarness(listeners: listeners, listenerRecorder: recorder)
  }

  func run(cycles: Int) throws {
    _ = listeners.install {}
    counters.listenerRegistrations = listenerRecorder.activeRegistrations

    for cycle in 0..<cycles {
      let native = LifecycleTeardownNativeCalls()
      let appID = "cycle.\(cycle)"
      let primary = try makeController(appID: appID, native: native)
      counters.createdControllers += 1
      counters.liveControllers += 1
      counters.retainedCallbackOwners += 1

      let originalTarget = TargetProcessFamily(logicalID: appID, processObjectIDs: [1])
      let unchangedTarget = TargetProcessFamily(logicalID: appID, processObjectIDs: [1])
      guard originalTarget.covers(unchangedTarget) else {
        throw LifecycleHarnessError.reuseWasNotCovered
      }
      primary.apply(volume: 0.5, volumeBoost: 1, muted: false)
      counters.reusedControllers += 1

      let expandedTarget = TargetProcessFamily(logicalID: appID, processObjectIDs: [1, 2])
      guard !originalTarget.covers(expandedTarget) else {
        throw LifecycleHarnessError.helperExpansionDidNotRebuild
      }
      let expanded = try makeController(appID: "\(appID).helper", native: LifecycleTeardownNativeCalls())
      counters.createdControllers += 1
      counters.liveControllers += 1
      counters.retainedCallbackOwners += 1
      counters.helperExpansionRebuilds += 1

      expanded.flagGeometryMismatchForTesting()
      guard expanded.consumeGeometryMismatch() else {
        throw LifecycleHarnessError.geometryRecoveryWasNotScheduled
      }
      var recovery = GeometryRecoveryCoordinator(maximumAttempts: 1)
      guard recovery.signalMismatch(at: .zero) == .scheduleRecovery(at: .zero),
        recovery.beginRecovery(at: .zero) == .attempt(number: 1),
        recovery.finishRecovery(succeeded: true, at: .zero) == .recovered
      else {
        throw LifecycleHarnessError.geometryRecoveryDidNotComplete
      }
      counters.geometryRecoveries += 1

      native.shouldFailStop = true
      guard !primary.dispose().isEmpty else {
        throw LifecycleHarnessError.disposeFailureWasNotRetained
      }
      counters.failedDisposals += 1
      native.shouldFailStop = false
      guard primary.retryDispose().isEmpty else {
        throw LifecycleHarnessError.retryDisposeDidNotDrain
      }
      counters.successfulDisposals += 1
      counters.liveControllers -= 1
      counters.retainedCallbackOwners -= 1

      guard expanded.dispose().isEmpty else {
        throw LifecycleHarnessError.disposeDidNotDrain
      }
      counters.successfulDisposals += 1
      counters.liveControllers -= 1
      counters.retainedCallbackOwners -= 1
    }

    guard listeners.remove().isEmpty else {
      throw LifecycleHarnessError.listenerDrainFailed
    }
    counters.listenerRegistrations = listenerRecorder.activeRegistrations
    counters.pendingRecoveryWork = 0
  }

  private func makeController(
    appID: String,
    native: LifecycleTeardownNativeCalls
  ) throws -> PerAppTapController {
    try PerAppTapController.testingController(
      appID: appID,
      teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
        makeOriginalAudioAudible: { noErr },
        stopIOProc: { native.shouldFailStop ? -1 : noErr },
        restoreTapMuting: { noErr }
      )
    )
  }
}

private enum LifecycleHarnessError: Error {
  case reuseWasNotCovered
  case helperExpansionDidNotRebuild
  case geometryRecoveryWasNotScheduled
  case geometryRecoveryDidNotComplete
  case disposeFailureWasNotRetained
  case retryDisposeDidNotDrain
  case disposeDidNotDrain
  case listenerDrainFailed
}

private final class LifecycleTeardownNativeCalls: @unchecked Sendable {
  var shouldFailStop = false
}

private final class LifecycleListenerRecorder: @unchecked Sendable {
  private var activeSelectors = Set<AudioObjectPropertySelector>()

  var activeRegistrations: Int {
    activeSelectors.count
  }

  func recordInstalled(_ selector: AudioObjectPropertySelector) {
    activeSelectors.insert(selector)
  }

  func recordRemoved(_ selector: AudioObjectPropertySelector) {
    activeSelectors.remove(selector)
  }
}
