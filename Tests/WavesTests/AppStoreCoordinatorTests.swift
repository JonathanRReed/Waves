import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func automationParserProducesTypedCommandsAndBoundsRate() {
  var now = Date(timeIntervalSince1970: 1_000)
  let parser = AutomationCommandParser(now: { now })

  #expect(
    parser.parse(URL(string: "waves://set-volume?app=com.example.music&volume=0.42")!)
      == .accepted(
        .setVolume(appID: "com.example.music", volume: 0.42)
      ))
  #expect(
    parser.parse(URL(string: "waves://mute?app=com.example.music&muted=true")!)
      == .accepted(
        .setMuted(appID: "com.example.music", isMuted: true)
      ))
  #expect(parser.parse(URL(string: "waves://apply-preset?name=Focus")!) == .accepted(.applyProfile(name: "Focus")))
  #expect(parser.parse(URL(string: "waves://refresh")!) == .accepted(.refresh))

  parser.reset()
  for _ in 0..<10 {
    #expect(parser.parse(URL(string: "waves://refresh")!) == .accepted(.refresh))
  }
  #expect(parser.parse(URL(string: "waves://refresh")!) == .throttled(shouldNotify: true))
  #expect(parser.parse(URL(string: "waves://refresh")!) == .throttled(shouldNotify: false))

  now.addTimeInterval(61)
  #expect(parser.parse(URL(string: "waves://refresh")!) == .accepted(.refresh))
}

@MainActor
@Test func deviceSuppressionExpiresConsumesAndShutsDownDeterministically() async {
  let clock = CoordinatorTestClock()
  let suppression = DeviceChangeSuppressionCoordinator(
    interval: .seconds(5),
    sleep: clock.sleep
  )

  suppression.begin(deviceID: "device.one")
  #expect(suppression.pendingDeviceID == "device.one")
  #expect(suppression.trackedTaskCount == 1)
  #expect(suppression.consumeIfMatching(deviceID: "device.one", didChange: true))
  #expect(suppression.pendingDeviceID == nil)
  #expect(suppression.trackedTaskCount == 0)

  suppression.begin(deviceID: "device.one")
  suppression.begin(deviceID: "device.two")
  #expect(suppression.pendingDeviceID == "device.two")
  await clock.waitForSleeper()
  clock.resumeAll()
  await suppression.drain()
  #expect(suppression.pendingDeviceID == nil)

  suppression.begin(deviceID: "device.three")
  await suppression.shutdown()
  #expect(suppression.lifecycleSnapshot == .idle)
}

@MainActor
@Test func appIntentCoordinatorRejectsStaleWorkAndClearsOwnedTasks() async {
  let coordinator = AppIntentCoordinator()
  let first = coordinator.allocateGeneration()
  coordinator.setCurrentGeneration(first, for: "music")
  let second = coordinator.allocateGeneration()
  coordinator.setCurrentGeneration(second, for: "music")

  #expect(!coordinator.isCurrent(first, for: "music"))
  #expect(coordinator.isCurrent(second, for: "music"))

  let task = Task<AppIntentApplyResult, Never> {
    AppIntentApplyResult(
      appID: "music",
      generation: second,
      outcome: .noChange,
      resultingApp: nil,
      backendStatus: BackendStatus(
        isAudioComponentInstalled: true,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true
      )
    )
  }
  coordinator.registerAppTask(task, for: "music")
  await coordinator.drain()
  #expect(coordinator.lifecycleSnapshot.trackedTaskCount == 0)

  _ = coordinator.shutdown()
  #expect(coordinator.lifecycleSnapshot == .idle)
}

@MainActor
@Test func adaptiveCoordinatorDeduplicatesAndPeriodicallyRepublishes() {
  let coordinator = AdaptiveMixCoordinator(republishPasses: 2)
  let app = AudioApp(
    id: "music.runtime",
    logicalID: "music",
    displayName: "Music",
    category: .media,
    routingState: .managed
  )
  let input = AdaptiveMixPassInput(
    mode: .speechFocus,
    focusMode: .smartHybrid,
    apps: [
      AdaptiveMixAppInput(
        app: app,
        policy: AdaptiveAppPolicy(contentType: .music, priority: .normal),
        levels: AdaptiveAnalysisLevels(rms: 0, voiceBandEnergy: 0),
        isFrontmost: false
      )
    ],
    elapsed: 0.1
  )

  let first = coordinator.evaluate(input)
  #expect(first.didWork)
  #expect(first.backendGains != nil)
  let second = coordinator.evaluate(input)
  #expect(second.backendGains == nil)
  let third = coordinator.evaluate(input)
  #expect(third.backendGains != nil)

  let reset = coordinator.evaluate(
    AdaptiveMixPassInput(mode: .speechFocus, focusMode: .smartHybrid, apps: [], elapsed: 0.1)
  )
  #expect(!reset.didWork)
  #expect(reset.visibleGains.isEmpty)
  #expect(reset.backendGains == [:])
}

private final class CoordinatorTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Error>] = []

  func sleep(for _: Duration) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      continuations.append(continuation)
      lock.unlock()
    }
  }

  func resumeAll() {
    lock.lock()
    let pending = continuations
    continuations.removeAll()
    lock.unlock()
    for continuation in pending {
      continuation.resume()
    }
  }

  func waitForSleeper() async {
    while true {
      let hasSleeper = lock.withLock { !continuations.isEmpty }
      if hasSleeper { return }
      await Task.yield()
    }
  }
}
