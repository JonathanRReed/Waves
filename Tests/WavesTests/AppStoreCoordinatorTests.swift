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
  #expect(
    parser.parse(URL(string: "waves://set-volume?app=music&volume=nan")!)
      == .rejected(
        AutomationCommandRejection(
          message: "Set-volume command was invalid.",
          shouldPresent: true
        )))

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
@Test func automationParserCountsOnlyAcceptedCommandsTowardQuota() {
  let parser = AutomationCommandParser()
  let invalidCommands = [
    "waves://unknown",
    "waves://set-volume?app=music",
    "waves://set-volume?app=music&volume=nan",
    "waves://set-volume?app=music&volume=inf",
    "waves://set-volume?app=music&volume=-0.1",
    "waves://set-volume?app=music&volume=1.1",
    "waves://mute?app=music",
    "waves://mute?app=music&muted=maybe",
    "waves://apply-profile",
    "waves://apply-preset?name=",
  ]

  for command in invalidCommands {
    guard case .rejected = parser.parse(URL(string: command)!) else {
      Issue.record("expected rejection for \(command)")
      continue
    }
  }
  for _ in 0..<10 {
    #expect(parser.parse(URL(string: "waves://refresh")!) == .accepted(.refresh))
  }
  #expect(parser.parse(URL(string: "waves://refresh")!) == .throttled(shouldNotify: true))
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
  await clock.waitForSleeper()
  #expect(suppression.consumeIfMatching(deviceID: "device.one", didChange: true))
  clock.resumeAll()
  await suppression.drain()
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
@Test func appIntentCoordinatorRetainsCancellationInsensitiveSupersededWorkUntilSettlement() async {
  let coordinator = AppIntentCoordinator()
  let gate = CoordinatorIntentGate()
  let firstGeneration = coordinator.allocateGeneration()
  coordinator.setCurrentGeneration(firstGeneration, for: "music")
  let first = Task<AppIntentApplyResult, Never> {
    await gate.wait()
    return coordinatorIntentResult(generation: firstGeneration)
  }
  coordinator.registerAppTask(first, for: "music")
  await gate.waitUntilStarted()

  let secondGeneration = coordinator.allocateGeneration()
  coordinator.setCurrentGeneration(secondGeneration, for: "music")
  let second = Task<AppIntentApplyResult, Never> {
    coordinatorIntentResult(generation: secondGeneration)
  }
  coordinator.registerAppTask(second, for: "music")

  #expect(coordinator.lifecycleSnapshot.appTransactions == 2)
  let drain = Task { @MainActor in await coordinator.drain() }
  await Task.yield()
  #expect(coordinator.lifecycleSnapshot.appTransactions == 2)

  await gate.release()
  await drain.value
  #expect(coordinator.lifecycleSnapshot.trackedTaskCount == 0)
}

private func coordinatorIntentResult(generation: UInt64) -> AppIntentApplyResult {
  AppIntentApplyResult(
    appID: "music",
    generation: generation,
    outcome: .noChange,
    resultingApp: nil,
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

@MainActor
@Test func adaptiveCoordinatorDeduplicatesAndPeriodicallyRepublishes() {
  let clock = CoordinatorTestMonotonicClock(now: 100)
  let coordinator = AdaptiveMixCoordinator(republishPasses: 2, now: clock.read)
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
    ]
  )

  let first = coordinator.evaluate(input)
  #expect(first.didWork)
  #expect(first.elapsed == 0.1)
  #expect(first.backendGains != nil)
  clock.advance(by: 0.1)
  let second = coordinator.evaluate(input)
  #expect(abs(second.elapsed - 0.1) < 0.000_001)
  #expect(second.backendGains == nil)
  clock.advance(by: 0.1)
  let third = coordinator.evaluate(input)
  #expect(third.backendGains != nil)

  clock.advance(by: 1)
  let reset = coordinator.evaluate(
    AdaptiveMixPassInput(mode: .speechFocus, focusMode: .smartHybrid, apps: [])
  )
  #expect(!reset.didWork)
  #expect(reset.elapsed == 1)
  #expect(reset.visibleGains.isEmpty)
  #expect(reset.backendGains == [:])
}

@MainActor
@Test func adaptiveCoordinatorMeasuresIdleAndDelayedWakeElapsedTime() {
  let clock = CoordinatorTestMonotonicClock(now: 1_000)
  let coordinator = AdaptiveMixCoordinator(now: clock.read)
  let managedApp = AudioApp(
    id: "music.runtime",
    logicalID: "music",
    displayName: "Music",
    category: .media,
    routingState: .managed
  )
  let managedInput = AdaptiveMixPassInput(
    mode: .both,
    focusMode: .smartHybrid,
    apps: [
      AdaptiveMixAppInput(
        app: managedApp,
        policy: AdaptiveAppPolicy(contentType: .music, priority: .normal),
        levels: AdaptiveAnalysisLevels(rms: 0.2, voiceBandEnergy: 0.1),
        isFrontmost: false
      )
    ]
  )
  let idleInput = AdaptiveMixPassInput(mode: .both, focusMode: .smartHybrid, apps: [])

  #expect(coordinator.evaluate(managedInput).elapsed == 0.1)
  clock.advance(by: 1)
  #expect(coordinator.evaluate(idleInput).elapsed == 1)
  clock.advance(by: 1)
  #expect(coordinator.evaluate(managedInput).elapsed == 1)
  clock.advance(by: 2.75)
  #expect(coordinator.evaluate(managedInput).elapsed == 2.75)

  _ = coordinator.cancel()
  clock.advance(by: 30)
  #expect(coordinator.evaluate(managedInput).elapsed == 0.1)

  coordinator.restart(
    isEnabled: false,
    activeInterval: .milliseconds(100),
    idleInterval: .seconds(1),
    performPass: { false },
    reset: {}
  )
  clock.advance(by: 30)
  #expect(coordinator.evaluate(managedInput).elapsed == 0.1)
}

@MainActor
@Test func adaptiveCoordinatorCancellationReturnsItsSettlingLoop() async throws {
  let coordinator = AdaptiveMixCoordinator()
  var passCount = 0
  coordinator.restart(
    isEnabled: true,
    activeInterval: .seconds(60),
    idleInterval: .seconds(60),
    performPass: {
      passCount += 1
      return true
    },
    reset: {}
  )
  while passCount == 0 { await Task.yield() }

  let settlingLoop = try #require(coordinator.cancel())
  await settlingLoop.value

  #expect(coordinator.lifecycleSnapshot == .idle)
}

@MainActor
@Test func managedAdaptiveRouteWithoutAnalysisKeepsTheActiveCadence() {
  let coordinator = AdaptiveMixCoordinator()
  let app = AudioApp(
    id: "music.runtime",
    logicalID: "music",
    displayName: "Music",
    category: .media,
    routingState: .managed
  )
  let output = coordinator.evaluate(
    AdaptiveMixPassInput(
      mode: .both,
      focusMode: .smartHybrid,
      apps: [
        AdaptiveMixAppInput(
          app: app,
          policy: AdaptiveAppPolicy(contentType: .music, priority: .normal),
          levels: nil,
          isFrontmost: false
        )
      ]
    ))

  #expect(output.didWork)
}

@MainActor
@Test func persistenceCoordinatorCoalescesDrainsFinalizesAndStopsAcceptingWork() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-persistence-coordinator-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
  )
  defer { try? FileManager.default.removeItem(at: directory) }

  let preferencesStore = PreferencesStore(directory: directory)
  let profileStore = ProfileStore(directory: directory)
  let sessionStore = SessionStore(directory: directory)
  let presetsStore = DeviceVolumePresetsStore(directory: directory)
  let coordinator = AppStorePersistenceCoordinator(
    preferencesStore: preferencesStore,
    profileStore: profileStore,
    sessionStore: sessionStore,
    devicePresetsStore: presetsStore,
    initialPreferences: UserPreferences(),
    initialDevicePresets: DeviceVolumePresets()
  )
  var first = UserPreferences()
  first.showRecentApps = false
  var latest = first
  latest.showRecentApps = true
  coordinator.enqueuePreferences(first)
  coordinator.enqueuePreferences(latest)
  coordinator.enqueueProfiles(Profile.defaults)
  coordinator.enqueueSession(.preview)
  coordinator.enqueueDevicePresets(DeviceVolumePresets())

  await coordinator.drain()
  #expect(coordinator.trackedTaskCount == 0)
  #expect(coordinator.pendingSnapshotCount == 0)
  #expect(preferencesStore.load().showRecentApps)

  let settling = coordinator.beginShutdown()
  for task in settling { await task.value }
  coordinator.beginFinalization()
  latest.showRecentApps = false
  coordinator.enqueuePreferences(latest)
  await coordinator.flush()
  coordinator.endFinalization()
  coordinator.finishShutdown()

  #expect(preferencesStore.load().showRecentApps == false)
  #expect(coordinator.lifecycleSnapshot == .idle)
}

final class CoordinatorTestClock: @unchecked Sendable {
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

private actor CoordinatorIntentGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false

  func wait() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
final class CoordinatorTestMonotonicClock {
  private var now: TimeInterval

  init(now: TimeInterval) {
    self.now = now
  }

  func read() -> TimeInterval {
    now
  }

  func advance(by interval: TimeInterval) {
    now += interval
  }
}
