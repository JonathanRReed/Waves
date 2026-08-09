import Foundation
import WavesAudioCore

struct AdaptiveMixAppInput: Sendable {
  let app: AudioApp
  let policy: AdaptiveAppPolicy
  let levels: AdaptiveAnalysisLevels?
  let isFrontmost: Bool
}

struct AdaptiveMixPassInput: Sendable {
  let mode: AdaptiveMixMode
  let focusMode: AdaptiveFocusMode
  let apps: [AdaptiveMixAppInput]
  let elapsed: TimeInterval
}

struct AdaptiveMixPassOutput: Equatable, Sendable {
  let didWork: Bool
  let visibleGains: [String: Float]
  let backendGains: [String: Float]?
}

struct AdaptiveMixCoordinatorLifecycleSnapshot: Equatable, Sendable {
  let hasLoop: Bool
  let publishedGainCount: Int

  static let idle = AdaptiveMixCoordinatorLifecycleSnapshot(
    hasLoop: false,
    publishedGainCount: 0
  )
}

/// Owns adaptive policy history, gain-write deduplication, and the one adaptive
/// loop task. AppStore builds each pass input and publishes the typed output.
@MainActor
final class AdaptiveMixCoordinator {
  private var policyEngine = AdaptivePolicyEngine()
  private var lastPublishedGains: [String: Float] = [:]
  private var republishCountdown = 0
  private let republishPasses: Int
  private var loopTask: Task<Void, Never>?
  private var loopToken: UUID?
  private var isShutDown = false

  init(republishPasses: Int = 20) {
    self.republishPasses = max(1, republishPasses)
  }

  var lifecycleSnapshot: AdaptiveMixCoordinatorLifecycleSnapshot {
    AdaptiveMixCoordinatorLifecycleSnapshot(
      hasLoop: loopTask != nil,
      publishedGainCount: lastPublishedGains.count
    )
  }

  func evaluate(_ input: AdaptiveMixPassInput) -> AdaptiveMixPassOutput {
    let hasManagedRoute = input.apps.contains { $0.app.routingState == .managed }
    guard hasManagedRoute else {
      let needsReset = !lastPublishedGains.isEmpty
      lastPublishedGains = [:]
      republishCountdown = 0
      policyEngine.reset()
      return AdaptiveMixPassOutput(
        didWork: false,
        visibleGains: [:],
        backendGains: needsReset ? [:] : nil
      )
    }

    policyEngine.usesLoudnessCorrection = input.mode.usesLoudnessBalance
    policyEngine.focusMode = input.focusMode
    let gains = policyEngine.update(
      inputs: input.apps.map { item in
        AdaptiveMixInput(
          appID: item.app.logicalID,
          policy: item.policy,
          isManaged: item.app.routingState == .managed && item.levels != nil,
          isMuted: item.app.isMuted,
          rms: item.levels?.rms ?? 0,
          voiceBandEnergy: item.levels?.voiceBandEnergy ?? 0,
          isFrontmost: item.isFrontmost
        )
      },
      elapsed: input.elapsed
    )
    let visible = gains.filter { abs($0.value) >= 0.05 }
    republishCountdown -= 1
    let shouldPublish = gains != lastPublishedGains || republishCountdown <= 0
    if shouldPublish {
      lastPublishedGains = gains
      republishCountdown = republishPasses
    }
    return AdaptiveMixPassOutput(
      didWork: true,
      visibleGains: visible,
      backendGains: shouldPublish ? gains : nil
    )
  }

  func restart(
    isEnabled: Bool,
    activeInterval: Duration,
    idleInterval: Duration,
    performPass: @escaping @MainActor @Sendable () async -> Bool,
    reset: @escaping @MainActor @Sendable () async -> Void
  ) {
    loopTask?.cancel()
    loopTask = nil
    let token = UUID()
    loopToken = token
    policyEngine.reset()
    lastPublishedGains = [:]
    republishCountdown = 0
    guard !isShutDown else {
      loopToken = nil
      return
    }
    guard isEnabled else {
      loopTask = Task { @MainActor [weak self] in
        await reset()
        guard let self, self.loopToken == token else { return }
        self.loopTask = nil
        self.loopToken = nil
      }
      return
    }
    loopTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let didWork = await performPass()
        guard !Task.isCancelled else { break }
        try? await Task.sleep(for: didWork ? activeInterval : idleInterval)
      }
      guard self.loopToken == token else { return }
      await reset()
      guard self.loopToken == token else { return }
      self.loopTask = nil
      self.loopToken = nil
    }
  }

  func cancel() -> Task<Void, Never>? {
    let task = loopTask
    task?.cancel()
    loopTask = nil
    loopToken = nil
    return task
  }

  func drain() async {
    await loopTask?.value
  }

  func shutdown() -> Task<Void, Never>? {
    isShutDown = true
    policyEngine.reset()
    lastPublishedGains = [:]
    republishCountdown = 0
    return cancel()
  }
}
