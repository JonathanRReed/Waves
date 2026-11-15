import AudioToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

// MARK: - Item 6: backend-wide rebuild budget (pure)

@Test func rebuildBudgetRefusesAutomaticWorkPastCapacityButNeverUserWork() {
  let budget = BudgetBox()
  let now = Duration.seconds(100)
  for _ in 0..<RouteRebuildBudget.minimumCapacity {
    #expect(budget.request(.automatic, liveRouteCount: 1, at: now))
  }
  #expect(!budget.request(.automatic, liveRouteCount: 1, at: now))
  #expect(budget.isCeilingActive(liveRouteCount: 1, at: now))
  // A user action still goes through while the ceiling is active.
  #expect(budget.request(.userInitiated, liveRouteCount: 1, at: now))
  #expect(budget.automaticCount == RouteRebuildBudget.minimumCapacity)
  #expect(budget.userInitiatedCount == 1)
  #expect(budget.refusedCount == 1)
}

@Test func rebuildBudgetCapacityFollowsTheLiveRouteCount() {
  let budget = BudgetBox()
  let capacity = RouteRebuildBudget.capacity(liveRouteCount: 10)
  #expect(capacity == 30)
  for _ in 0..<capacity {
    #expect(budget.request(.automatic, liveRouteCount: 10, at: .zero))
  }
  #expect(!budget.request(.automatic, liveRouteCount: 10, at: .zero))
}

@Test func rebuildBudgetCooldownDoublesOnConsecutiveTripsAndResetsOnFullRefill() {
  let budget = BudgetBox(
    RouteRebuildBudget(
      refillInterval: .seconds(10),
      baseCooldown: .seconds(30),
      maximumCooldown: .seconds(600)
    ))
  for _ in 0..<16 { _ = budget.request(.automatic, liveRouteCount: 0, at: .zero) }
  #expect(!budget.request(.automatic, liveRouteCount: 0, at: .zero))  // trip 1: 30 s
  #expect(!budget.request(.automatic, liveRouteCount: 0, at: .seconds(29)))
  // 30 s refilled three tokens.
  #expect(budget.request(.automatic, liveRouteCount: 0, at: .seconds(30)))
  #expect(budget.request(.automatic, liveRouteCount: 0, at: .seconds(30)))
  #expect(budget.request(.automatic, liveRouteCount: 0, at: .seconds(30)))
  #expect(!budget.request(.automatic, liveRouteCount: 0, at: .seconds(30)))  // trip 2: 60 s
  #expect(!budget.request(.automatic, liveRouteCount: 0, at: .seconds(89)))
  #expect(budget.request(.automatic, liveRouteCount: 0, at: .seconds(90)))
  #expect(budget.refusedCount == 4)

  // A bucket that refilled completely forgets earlier trips.
  for _ in 0..<16 { _ = budget.request(.automatic, liveRouteCount: 0, at: .seconds(1_000)) }
  #expect(!budget.request(.automatic, liveRouteCount: 0, at: .seconds(1_000)))
  #expect(budget.request(.automatic, liveRouteCount: 0, at: .seconds(1_030)))
}

@Test func rebuildBudgetCooldownIsCapped() {
  let budget = BudgetBox(
    RouteRebuildBudget(
      refillInterval: .seconds(10_000),
      baseCooldown: .seconds(30),
      maximumCooldown: .seconds(100)
    ))
  var now = Duration.zero
  for _ in 0..<16 { _ = budget.request(.automatic, liveRouteCount: 0, at: now) }
  for _ in 0..<6 {
    #expect(!budget.request(.automatic, liveRouteCount: 0, at: now))
    now += .seconds(100)
  }
  // Six trips later the cooldown is still the 100 s cap, not 30 * 2^5.
  #expect(!budget.request(.automatic, liveRouteCount: 0, at: now - .seconds(1)))
}

@Test func rebuildBudgetUserRecoveryClearsTheCooldown() {
  let budget = BudgetBox()
  for _ in 0..<17 { _ = budget.request(.automatic, liveRouteCount: 0, at: .zero) }
  #expect(budget.isCeilingActive(liveRouteCount: 0, at: .zero))
  budget.resetForUserRecovery()
  #expect(!budget.isCeilingActive(liveRouteCount: 0, at: .zero))
  #expect(budget.request(.automatic, liveRouteCount: 0, at: .zero))
  #expect(budget.automaticCount == 17)
}

/// `#expect` cannot wrap a mutating call, so the pure tests drive the budget
/// through a reference.
final class BudgetBox {
  private var budget: RouteRebuildBudget
  init(_ budget: RouteRebuildBudget = RouteRebuildBudget()) { self.budget = budget }

  func request(_ origin: RouteWorkOrigin, liveRouteCount: Int, at now: Duration) -> Bool {
    budget.request(origin, liveRouteCount: liveRouteCount, at: now)
  }
  func isCeilingActive(liveRouteCount: Int, at now: Duration) -> Bool {
    budget.isCeilingActive(liveRouteCount: liveRouteCount, at: now)
  }
  func resetForUserRecovery() { budget.resetForUserRecovery() }
  var automaticCount: Int { budget.automaticCount }
  var userInitiatedCount: Int { budget.userInitiatedCount }
  var refusedCount: Int { budget.refusedCount }
}

// MARK: - Item 6: backend integration

@Test func automaticGeometryRebuildsStopAtTheCeilingWhileUserWorkContinues() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  let baseline = fixture.events.creations

  // Each cycle is a fresh geometry mismatch after a clean verification window,
  // so each one asks for exactly one automatic rebuild.
  for cycle in 0..<RouteRebuildBudget.minimumCapacity {
    await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
    await backend.updateAudioLevels(at: .seconds(10 + cycle * 2))
  }
  #expect(fixture.events.creations == baseline + RouteRebuildBudget.minimumCapacity)

  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  await backend.updateAudioLevels(at: .seconds(10 + RouteRebuildBudget.minimumCapacity * 2))
  #expect(fixture.events.creations == baseline + RouteRebuildBudget.minimumCapacity)

  let report = await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
  let budgetCheck = try #require(report.checks.first { $0.title == "Route rebuild budget" })
  #expect(budgetCheck.status == .warning)
  #expect(budgetCheck.detail.contains("\(RouteRebuildBudget.minimumCapacity) automatic"))
  #expect(budgetCheck.detail.contains("1 automatic refused"))
  #expect(budgetCheck.detail.contains("ceiling: active"))

  // A user-initiated rebuild (an output-device change) still goes through.
  let result = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.4, generation: 50, targetDeviceUID: "usb-dac")
  )
  #expect(result.outcome == .applied)
  #expect(fixture.events.creations == baseline + RouteRebuildBudget.minimumCapacity + 1)
}

// MARK: - Item 1: default-output change is make before break

@Test func defaultOutputChangeBuildsTheReplacementBeforeReleasingTheOldTap() async throws {
  let fixture = RouteFixture(apps: [
    routeTestApp(id: "app.a"),
    routeTestApp(id: "app.b", targetDeviceUID: "usb-dac"),
  ])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  _ = try await backend.restoreDefaultFollowingRoutesForTesting()

  // The old tap (#1) releases its app only after the replacement (#3) runs,
  // and the old renderer was silent while #3 was built. The pinned route (#2)
  // is untouched.
  #expect(fixture.events.values == ["prior #1 muted=true", "create app.a #3", "audible #1"])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 2)
  let apps = await backend.currentSnapshot().apps
  #expect(apps.first { $0.id == "app.a" }?.routingState == .managed)
  #expect(apps.first { $0.id == "app.a" }?.appliedVolume == 0.5)
  #expect(fixture.events.controller(serial: 3)?.settledIsMutedForTesting() == false)
}

@Test func defaultOutputChangeReleasesARouteItCannotRebuildAndSaysWhy() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextCreations(3)

  _ = try await backend.restoreDefaultFollowingRoutesForTesting()

  #expect(fixture.events.values.last == "audible #1")
  #expect(fixture.events.creations == 0)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .error)
  #expect(app.appliedVolume == nil)
  #expect(app.notes?.contains("plays at its own volume") == true)
}

@Test func failedInPlaceRebuildGivesTheSilencedIncumbentItsLevelsBack() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a", volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextCreations(3)

  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  await backend.updateAudioLevels(at: .seconds(10))

  let incumbent = try #require(fixture.events.controller(serial: 1))
  #expect(fixture.events.values.contains("audible #1") == false)
  #expect(incumbent.settledIsMutedForTesting() == false)
  #expect(incumbent.settledGainsForTesting().volume == 0.5)
}

// MARK: - Item 3: a device that was both the default and a pinned target

@Test func deviceChangePlanReconcilesPinnedRoutesInTheSamePassAsADefaultChange() {
  let both = DeviceChangePassPlan(defaultOutputChanged: true, inventoryChanged: true)
  #expect(both.rehomesDefaultFollowingRoutes)
  #expect(both.reconcilesPinnedRoutes)
  let defaultOnly = DeviceChangePassPlan(defaultOutputChanged: true, inventoryChanged: false)
  #expect(defaultOnly.rehomesDefaultFollowingRoutes)
  #expect(!defaultOnly.reconcilesPinnedRoutes)
  // Waves's own aggregate churn never reaches the plan as an inventory change.
  let neither = DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: false)
  #expect(!neither.rehomesDefaultFollowingRoutes)
  #expect(!neither.reconcilesPinnedRoutes)
}

@Test func unpluggingTheDefaultThatIsAlsoAPinnedTargetReleasesThePinnedRoute() async throws {
  let fixture = RouteFixture(apps: [
    routeTestApp(id: "app.a"),
    routeTestApp(id: "app.b", targetDeviceUID: "usb-dac"),
  ])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The USB DAC was the default and app.b's pinned output; it is now gone.
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: true, inventoryChanged: true),
    availableDeviceUIDs: ["builtin-speakers"]
  )

  let apps = await backend.currentSnapshot().apps
  let pinned = try #require(apps.first { $0.id == "app.b" })
  #expect(pinned.routingState == .error)
  #expect(pinned.notes?.contains("chosen output device") == true)
  #expect(fixture.events.values.contains("audible #2"))
  // The default-following route moved, make before break.
  #expect(apps.first { $0.id == "app.a" }?.routingState == .managed)
  #expect(fixture.events.values.contains("create app.a #3"))
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
}

// MARK: - Item 4: exhausted geometry recovery does not outlive its controller

@Test func exhaustedMaintenanceRecoveryReleasesTheRouteAndTheNextControllerStartsClean() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Every rebuild fails: three geometry attempts, then exhaustion.
  fixture.events.failNextCreations(1_000)
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  await backend.updateAudioLevels(at: .seconds(10))
  await backend.updateAudioLevels(at: .seconds(11))
  await backend.updateAudioLevels(at: .seconds(12))

  // The mismatching controller is released so the app is audible, and its
  // spent coordinator goes with it.
  #expect(fixture.events.values.contains("audible #1"))
  let exhausted = await backend.lifecycleDebugSnapshot()
  #expect(exhausted.liveControllers == 0)
  #expect(exhausted.retainedGeometryRecoveryStates == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .error)
  #expect(app.routeHealthContext == .geometryRecoveryExhausted)
  #expect(app.appliedVolume == nil)

  // Recover Routes re-applies the app's levels (the store sends this intent
  // after the backend pass). The new route must be able to recover again.
  fixture.events.failNextCreations(0)
  let recovery = AppRouteIntent(
    appID: "app.a",
    desiredVolume: 0.5,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: 20,
    reason: .routeRecovery
  )
  #expect(await backend.applyAppIntent(recovery).outcome == .applied)
  let creationsBefore = fixture.events.creations
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  await backend.updateAudioLevels(at: .seconds(20))
  #expect(fixture.events.creations == creationsBefore + 1)
  #expect(await backend.currentSnapshot().apps.first?.routingState == .managed)
}

@Test func retiringAControllerRetiresItsGeometryRecoveryState() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  await backend.updateAudioLevels(at: .seconds(10))
  #expect(await backend.lifecycleDebugSnapshot().retainedGeometryRecoveryStates == 1)

  // The app quits (or Recover Routes clears every route).
  _ = await backend.disposeControllers(keeping: [])
  #expect(await backend.lifecycleDebugSnapshot().retainedGeometryRecoveryStates == 0)
}

@Test func aUserRebuildStartsWithAFreshGeometryBudget() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  await backend.updateAudioLevels(at: .seconds(10))
  #expect(await backend.lifecycleDebugSnapshot().retainedGeometryRecoveryStates == 1)

  let move = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(move.outcome == .applied)
  #expect(await backend.lifecycleDebugSnapshot().retainedGeometryRecoveryStates == 0)
}

// MARK: - Item 5: sample-rate, stream-format, alive, and wake revalidation

private let rate48 = DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 2)
private let rate96 = DeviceFormatSignature(sampleRate: 96_000, outputChannelCount: 2)

@Test func formatRevalidationRebuildsOnlyRoutesWhoseDeviceChanged() {
  let bindings = [
    "a": RouteOutputBinding(deviceUID: "builtin", signature: rate48),
    "b": RouteOutputBinding(deviceUID: "usb-dac", signature: rate48),
  ]
  let decision = RouteFormatRevalidation.decide(
    bindings: bindings,
    observations: ["builtin": .alive(rate96), "usb-dac": .alive(rate48)],
    devicesPreviouslySeenNotAlive: []
  )
  #expect(decision.runtimeIDsToRebuild == ["a"])

  // Bluetooth HFP: same rate, different channel layout.
  let mono = DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 1)
  let profileSwitch = RouteFormatRevalidation.decide(
    bindings: bindings,
    observations: ["builtin": .alive(rate48), "usb-dac": .alive(mono)],
    devicesPreviouslySeenNotAlive: []
  )
  #expect(profileSwitch.runtimeIDsToRebuild == ["b"])
}

@Test func formatRevalidationWaitsForADeviceThatIsNotAliveAndRebuildsWhenItReturns() {
  let bindings = ["a": RouteOutputBinding(deviceUID: "headset", signature: rate48)]
  let down = RouteFormatRevalidation.decide(
    bindings: bindings,
    observations: ["headset": .notAlive],
    devicesPreviouslySeenNotAlive: []
  )
  #expect(down.runtimeIDsToRebuild.isEmpty)
  #expect(down.devicesSeenNotAlive == ["headset"])

  // Back with the same format: its old aggregate may not have survived.
  let back = RouteFormatRevalidation.decide(
    bindings: bindings,
    observations: ["headset": .alive(rate48)],
    devicesPreviouslySeenNotAlive: down.devicesSeenNotAlive
  )
  #expect(back.runtimeIDsToRebuild == ["a"])
  #expect(back.devicesSeenNotAlive.isEmpty)

  // A device that left the list is the inventory pass's job, not this one.
  let gone = RouteFormatRevalidation.decide(
    bindings: bindings,
    observations: ["headset": .missing],
    devicesPreviouslySeenNotAlive: []
  )
  #expect(gone.runtimeIDsToRebuild.isEmpty)
  #expect(gone.devicesSeenNotAlive.isEmpty)
}

@Test func sameDeviceRateChangeRebuildsTheAffectedRouteOnceThroughTheBudget() async throws {
  let fixture = RouteFixture(apps: [
    routeTestApp(id: "app.a"),
    routeTestApp(id: "app.b", targetDeviceUID: "usb-dac"),
  ])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Audio MIDI Setup: built-in output 48 kHz to 96 kHz.
  fixture.devices.set("builtin", .alive(rate96))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))
  #expect(fixture.events.values == ["prior #1 muted=true", "create app.a #3", "audible #1"])

  // The rebuilt route recorded 96 kHz, so the events its own rebuild raises
  // (and any repeat of the original one) find nothing to do.
  await backend.revalidateRouteFormatsForTesting(at: .seconds(11))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(12))
  #expect(fixture.events.creations == 1)

  let report = await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
  let budget = try #require(report.checks.first { $0.title == "Route rebuild budget" })
  #expect(budget.detail.contains("1 automatic"))
}

@Test func formatRebuildsAreRefusedWhileTheRebuildCeilingIsActive() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // A device flapping between rates: each flip asks for a rebuild.
  for flip in 0..<(RouteRebuildBudget.minimumCapacity + 4) {
    fixture.devices.set("builtin", .alive(flip.isMultiple(of: 2) ? rate96 : rate48))
    await backend.revalidateRouteFormatsForTesting(at: .seconds(10 + flip))
  }
  #expect(fixture.events.creations == RouteRebuildBudget.minimumCapacity)
  let report = await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
  let budget = try #require(report.checks.first { $0.title == "Route rebuild budget" })
  #expect(budget.detail.contains("ceiling: active"))
}

@Test func deviceFormatListenersFollowTheDeviceListAndRetryRefusedDevices() {
  let calls = ListenerCalls()
  let lifecycle = DeviceFormatListenerLifecycle(
    nativeCalls: DeviceFormatListenerNativeCalls(
      add: { device, address, _ in calls.add(device, address.mSelector) },
      remove: { device, address, _ in calls.remove(device, address.mSelector) }
    )
  )
  let perDevice = DeviceFormatListenerLifecycle.addresses.count

  #expect(lifecycle.sync(deviceIDs: [1, 2]) {}.isEmpty)
  #expect(calls.live == [1: perDevice, 2: perDevice])

  // Device 1 unplugged, device 3 plugged in; device 3 refuses the rate listener.
  calls.refuse(device: 3, selector: kAudioDevicePropertyNominalSampleRate)
  #expect(lifecycle.sync(deviceIDs: [2, 3]) {}.count == 1)
  #expect(calls.live == [2: perDevice])

  calls.refuse(device: 3, selector: nil)
  #expect(lifecycle.sync(deviceIDs: [2, 3]) {}.isEmpty)
  #expect(calls.live == [2: perDevice, 3: perDevice])

  #expect(lifecycle.remove().isEmpty)
  #expect(calls.live.isEmpty)
}

private final class ListenerCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [AudioObjectID: Int] = [:]
  private var refused: (AudioObjectID, AudioObjectPropertySelector)?

  var live: [AudioObjectID: Int] { lock.withLock { counts.filter { $0.value > 0 } } }

  func refuse(device: AudioObjectID, selector: AudioObjectPropertySelector?) {
    lock.withLock { refused = selector.map { (device, $0) } }
  }

  func add(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> OSStatus {
    lock.withLock {
      if let refused, refused.0 == device, refused.1 == selector { return -1 }
      counts[device, default: 0] += 1
      return noErr
    }
  }

  func remove(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> OSStatus {
    lock.withLock {
      counts[device, default: 0] -= 1
      return noErr
    }
  }
}

// MARK: - Item 2: background repair cannot overwrite newer intent

@Test func suspendedBackgroundRepairCannotRecreateARouteTheUserExcluded() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(apps: [routeTestApp()], retryPause: { _ in await gate.pause() })
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The geometry repair's first creation fails, so it suspends before retrying.
  fixture.events.failNextCreations(1)
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  let repair = Task { await backend.updateAudioLevels(at: .seconds(10)) }
  await gate.waitUntilPaused()

  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await gate.release()
  await repair.value

  #expect(fixture.events.creations == 0)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .monitorOnly)
  #expect(app.notes == nil)
}

@Test func suspendedBackgroundRepairCannotReplaceANewerOutputChoice() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(apps: [routeTestApp()], retryPause: { _ in await gate.pause() })
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  fixture.events.failNextCreations(1)
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  let repair = Task { await backend.updateAudioLevels(at: .seconds(10)) }
  await gate.waitUntilPaused()

  let choice = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.3, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(choice.outcome == .applied)
  let afterChoice = fixture.events.values
  await gate.release()
  await repair.value

  // The user's controller (built for the new device) is still the live one:
  // no further creation, and it was never torn down.
  #expect(fixture.events.values == afterChoice)
  #expect(fixture.events.creations == 1)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.targetDeviceUID == "usb-dac")
  #expect(app.routingState == .managed)
  #expect(app.desiredVolume == 0.3)
}

@Test func supersededGeometryRepairIsRetriedRatherThanCounted() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(apps: [routeTestApp()], retryPause: { _ in await gate.pause() })
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  fixture.events.failNextCreations(1)
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  let repair = Task { await backend.updateAudioLevels(at: .seconds(10)) }
  await gate.waitUntilPaused()
  // A parameter-only edit reuses the live controller but still supersedes
  // the repair, which would otherwise re-apply the old volume.
  let edit = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.2, generation: 10))
  #expect(edit.outcome == .applied)
  await gate.release()
  await repair.value
  #expect(fixture.events.creations == 0)
  #expect(await backend.lifecycleDebugSnapshot().pendingGeometryRecoveries == 1)

  // The next tick retries the rebuild with the current volume.
  await backend.updateAudioLevels(at: .seconds(11))
  #expect(fixture.events.creations == 1)
  #expect(await backend.lifecycleDebugSnapshot().pendingGeometryRecoveries == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .managed)
  #expect(app.appliedVolume == 0.2)
}

// MARK: - Fixture

/// Holds a controller-creation retry until the test releases it.
actor RetryGate {
  private var paused: CheckedContinuation<Void, Never>?
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false

  func pause() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      paused = continuation
      pauseWaiters.forEach { $0.resume() }
      pauseWaiters.removeAll()
    }
  }

  func waitUntilPaused() async {
    guard paused == nil else { return }
    await withCheckedContinuation { pauseWaiters.append($0) }
  }

  func release() {
    isReleased = true
    paused?.resume()
    paused = nil
  }
}

func routeTestApp(
  id: String = "app.a",
  volume: Float = 0.5,
  routingState: RoutingState = .managed,
  targetDeviceUID: String? = nil
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: id,
    pid: 900,
    bundleID: "com.example.\(id)",
    displayName: "App \(id)",
    category: .media,
    isActive: true,
    desiredVolume: volume,
    appliedVolume: routingState == .managed ? volume : nil,
    routingState: routingState,
    compatibility: .supported,
    targetDeviceUID: targetDeviceUID
  )
}

func routeIntent(
  appID: String,
  volume: Float,
  generation: UInt64,
  isMuted: Bool = false,
  targetDeviceUID: String? = nil,
  isExcluded: Bool = false
) -> AppRouteIntent {
  AppRouteIntent(
    appID: appID,
    desiredVolume: volume,
    isMuted: isMuted,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: targetDeviceUID,
    generation: generation,
    reason: .userEdit,
    isExcluded: isExcluded
  )
}

/// Records, in order, every controller creation and every moment a
/// controller's tap stops muting its app (the instant the app would be heard
/// at its own, unattenuated level).
final class RouteEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private var serial = 0
  private var failuresRemaining = 0

  var values: [String] { lock.withLock { recorded } }
  var creations: Int { lock.withLock { recorded.count { $0.hasPrefix("create ") } } }

  func record(_ value: String) { lock.withLock { recorded.append(value) } }

  func nextSerial() -> Int {
    lock.withLock {
      serial += 1
      return serial
    }
  }

  func failNextCreations(_ count: Int) { lock.withLock { failuresRemaining = count } }

  func consumeFailure() -> Bool {
    lock.withLock {
      guard failuresRemaining > 0 else { return false }
      failuresRemaining -= 1
      return true
    }
  }

  func reset() { lock.withLock { recorded.removeAll() } }

  private var created: [Int: (appID: String, controller: PerAppTapController)] = [:]

  func remember(_ controller: PerAppTapController, serial: Int, appID: String) {
    lock.withLock { created[serial] = (appID, controller) }
  }

  func controller(serial: Int) -> PerAppTapController? {
    lock.withLock { created[serial]?.controller }
  }

  /// The newest still-running controller built for `appID`, if any.
  func liveController(for appID: String) -> (serial: Int, controller: PerAppTapController)? {
    lock.withLock {
      created
        .filter { $0.value.appID == appID && $0.value.controller.isActive }
        .max { $0.key < $1.key }
        .map { ($0.key, $0.value.controller) }
    }
  }
}

/// The fake output devices' current formats. Default-following routes play
/// on "builtin"; pinned routes on their target.
final class DeviceFormatState: @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [String: DeviceFormatObservation] = [
    "builtin": .alive(DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 2)),
    "usb-dac": .alive(DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 2)),
  ]

  func set(_ uid: String, _ observation: DeviceFormatObservation) {
    lock.withLock { observations[uid] = observation }
  }

  func observation(_ uid: String) -> DeviceFormatObservation {
    lock.withLock { observations[uid] ?? .missing }
  }

  func binding(for app: AudioApp) -> RouteOutputBinding? {
    let uid = app.targetDeviceUID ?? "builtin"
    guard case .alive(let signature) = observation(uid) else { return nil }
    return RouteOutputBinding(deviceUID: uid, signature: signature)
  }
}

final class RouteFixture: @unchecked Sendable {
  let backend: WorkspaceAudioControlBackend
  let events = RouteEvents()
  let devices = DeviceFormatState()

  init(
    apps: [AudioApp],
    retryPause: WorkspaceAudioControlBackend.ControllerRetryPause? = nil
  ) {
    let events = self.events
    let devices = self.devices
    backend = WorkspaceAudioControlBackend(
      testingSnapshot: AudioSessionSnapshot(
        apps: apps,
        currentDevice: nil,
        recentDeviceIDs: [],
        supportMatrix: SupportMatrix(entries: []),
        backendStatus: BackendStatus(
          isAudioComponentInstalled: true,
          hasRequiredPermissions: true,
          isRouteRecoveryHealthy: true
        )
      ),
      captureAuthorization: .authorized,
      routerObservationNativeCalls: RouterObservationListenerNativeCalls(
        add: { _, _ in noErr },
        remove: { _, _ in noErr }
      ),
      controllerFactory: { app, processObjectIDs, _, _, _ in
        if events.consumeFailure() {
          events.record("fail \(app.id)")
          throw BackendError.managedRouteUnavailable("Injected creation failure")
        }
        // Whether the outgoing renderer was already silent when its
        // replacement was built (make before break without double audio).
        if let prior = events.liveController(for: app.id) {
          events.record("prior #\(prior.serial) muted=\(prior.controller.settledIsMutedForTesting())")
        }
        let serial = events.nextSerial()
        events.record("create \(app.id) #\(serial)")
        let controller = try PerAppTapController.testingController(
          appID: app.id,
          logicalID: app.logicalID,
          targetProcessObjectIDs: processObjectIDs,
          teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
            makeOriginalAudioAudible: {
              events.record("audible #\(serial)")
              return noErr
            },
            stopIOProc: { noErr },
            restoreTapMuting: { noErr }
          )
        )
        events.remember(controller, serial: serial, appID: app.id)
        return controller
      },
      processObjectIDResolver: { _ in [1] },
      processObjectLivenessProvider: { _ in true },
      captureAuthorizationProbe: { .authorized },
      routeBudgetClock: { .seconds(1) },
      controllerRetryPause: retryPause ?? { _ in },
      routeOutputBindingProvider: { devices.binding(for: $0) },
      deviceFormatObservationProvider: { devices.observation($0) },
      deviceFormatListenerNativeCalls: DeviceFormatListenerNativeCalls(
        add: { _, _, _ in noErr },
        remove: { _, _, _ in noErr }
      )
    )
  }

  /// Gives every managed app a live controller through the user path, then
  /// clears the event log.
  func installInitialRoutes() async throws {
    let snapshot = await backend.currentSnapshot()
    for (offset, app) in snapshot.apps.enumerated() where app.routingState == .managed {
      let result = await backend.applyAppIntent(
        routeIntent(
          appID: app.logicalID,
          volume: app.desiredVolume,
          generation: UInt64(offset + 1),
          targetDeviceUID: app.targetDeviceUID
        )
      )
      try #require(result.outcome == .applied || result.outcome == .noChange)
    }
    events.reset()
  }
}
