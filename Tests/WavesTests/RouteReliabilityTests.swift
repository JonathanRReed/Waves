import AppKit
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

  _ = try await backend.autoRestoreDevice()

  // The replacement (#3) is built while the old renderer (#1) keeps playing,
  // and the two are never heard together. The old renderer is stopped, not
  // told to un-mute its tap: #3's tap keeps the app's own output muted. The
  // pinned route (#2) is untouched.
  #expect(fixture.events.values == ["create app.a #3", "stop #1"])
  #expect(fixture.events.overlaps.isEmpty)
  #expect(fixture.events.pumpRenders() == [2, 3])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 2)
  let apps = await backend.currentSnapshot().apps
  #expect(apps.first { $0.id == "app.a" }?.routingState == .managed)
  #expect(apps.first { $0.id == "app.a" }?.appliedVolume == 0.5)
}

@Test func defaultOutputChangeReleasesARouteItCannotRebuildAndSaysWhy() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextCreations(3)

  _ = try await backend.autoRestoreDevice()

  // Released fail-open: the tap's mute goes first, then the renderer stops.
  #expect(fixture.events.values.suffix(2) == ["audible #1", "stop #1"])
  #expect(fixture.events.creations == 0)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .error)
  #expect(app.appliedVolume == nil)
  #expect(app.notes?.contains("plays at its own volume") == true)
}

@Test func aFormatRebuildThatFailsReleasesTheBrokenRouteAndSaysWhy() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a", volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The built-in output resets and comes back at 96 kHz under the same UID.
  // #1's aggregate did not survive: it renders nothing, while its tap still
  // mutes the app. Every rebuild attempt fails.
  fixture.events.stopRendering(serial: 1)
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(3)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))

  // Released fail open, so the app plays at its own level, and the row says so.
  #expect(fixture.events.values == ["fail app.a", "fail app.a", "fail app.a", "audible #1", "stop #1"])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .error)
  #expect(app.appliedVolume == nil)
  #expect(app.notes?.contains("plays at its own volume") == true)
}

@Test func aFailedRepairThatCouldNotHandTheAppBackNeverAlsoClaimsItPlaysOnItsOwn() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a", volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(3)
  fixture.events.failNextMuteReleases(1)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))

  #expect(fixture.events.hearing("app.a") == "waves #1")
  let note = try #require(await backend.currentSnapshot().apps.first?.notes)
  #expect(note.contains("still playing it at the level you set"))
  #expect(note.contains("couldn't rebuild the audio route for App app.a"))
  #expect(!note.contains("its own volume"), "\(note)")
}

/// Spends the automatic rebuild budget with geometry repairs of app.a.
private func spendRebuildBudget(_ fixture: RouteFixture) async {
  for cycle in 0..<RouteRebuildBudget.minimumCapacity {
    await fixture.backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
    await fixture.backend.updateAudioLevels(at: .seconds(10 + cycle * 2))
  }
}

@Test func aFormatRebuildRefusedByTheRebuildCeilingKeepsARouteThatStillRenders() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await spendRebuildBudget(fixture)
  let creations = fixture.events.creations
  let incumbent = creations + 1

  // The rate changes while automatic rebuilds are paused. The refusal says
  // nothing about the route, which still plays the app at its level.
  fixture.devices.set("builtin", .alive(rate96))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(40))

  #expect(fixture.events.creations == creations)
  #expect(fixture.events.lastTapMuteEvent(serial: incumbent) == nil)
  #expect(fixture.events.pumpRenders() == [incumbent])
  // Kept, but not called healthy: its EQ runs at the old rate until the
  // rebuild, and the row says the rebuild is still to come.
  let kept = try #require(await backend.currentSnapshot().apps.first)
  #expect(kept.routingState == .error)
  #expect(kept.notes?.contains("its output device changed format") == true)
  #expect(kept.notes?.contains("Automatic rebuilds are paused") == true)
  #expect(kept.appliedVolume == 0.5)

  // Once the budget refills, the next maintenance pass rebuilds it.
  fixture.budgetClock.value = .seconds(600)
  await maintenancePass(fixture, from: 100)
  #expect(fixture.events.creations == creations + 1)
  #expect(fixture.events.pumpRenders() == [incumbent + 1])
}

@Test func aDeviceResetWhoseRebuildTheBudgetRefusedIsStillRebuiltOnceTheBudgetAllows() async throws {
  let calls = ListenerCalls()
  let fixture = RouteFixture(apps: [routeTestApp()], deviceFormatListenerNativeCalls: calls.nativeCalls)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.syncDeviceFormatListenersForTesting(devices: [10: "builtin"])
  await spendRebuildBudget(fixture)
  let creations = fixture.events.creations
  let incumbent = creations + 1

  // The built-in output drops and comes back with the same format while
  // automatic rebuilds are paused. Its aggregate may not have survived, so
  // the route needs rebuilding, but the budget refuses it for now.
  calls.setAlive(false)
  calls.fireAliveChange(on: 10)
  calls.setAlive(true)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(40))
  #expect(fixture.events.creations == creations)
  #expect(fixture.events.pumpRenders() == [incumbent])
  let pending = try #require(await backend.currentSnapshot().apps.first)
  #expect(pending.routingState == .error)
  #expect(pending.notes?.contains("disconnected and came back") == true)
  #expect(pending.appliedVolume == 0.5)

  // The device's own transition was consumed by that pass. The route still
  // remembers its repair: once the budget allows, maintenance rebuilds it.
  fixture.budgetClock.value = .seconds(600)
  await maintenancePass(fixture, from: 100)
  #expect(fixture.events.creations == creations + 1)
  #expect(fixture.events.pumpRenders() == [incumbent + 1])
  let rebuilt = try #require(await backend.currentSnapshot().apps.first)
  #expect(rebuilt.routingState == .managed)
  #expect(rebuilt.notes == nil)

  // And it is not rebuilt again.
  await maintenancePass(fixture, from: 200)
  #expect(fixture.events.creations == creations + 1)
}

@Test func recoverRoutesReplacesARouteItCouldNotReleaseRatherThanReusingIt() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await spendRebuildBudget(fixture)
  let creations = fixture.events.creations
  let incumbent = creations + 1
  // A format change whose rebuild the budget refused: still pending.
  fixture.devices.set("builtin", .alive(rate96))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(40))

  // Recover Routes cannot hand the app back (its tap will not let go once),
  // so the incumbent stays installed. It must still be rebuilt.
  fixture.events.failNextMuteReleases(1)
  _ = try await backend.recoverRoutes()

  #expect(fixture.events.creations == creations + 1)
  #expect(fixture.events.hearing("app.a") == "waves #\(incumbent + 1)")
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.routingState == .managed)
  #expect(row.notes == nil)
}

@Test func aRebuildRefusedByTheCeilingReleasesARouteThatStoppedRenderingAndRetriesLater() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await spendRebuildBudget(fixture)
  let creations = fixture.events.creations
  let incumbent = creations + 1

  // The aggregate stopped rendering while the app plays into its tap, so the
  // app is silent. The rebuild is refused: release it, and say why.
  fixture.events.stopRendering(serial: incumbent)
  await maintenancePass(fixture, from: 100, ticks: 30)
  #expect(fixture.events.creations == creations)
  #expect(fixture.events.lastTapMuteEvent(serial: incumbent) == "audible #\(incumbent)")
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let released = try #require(await backend.currentSnapshot().apps.first)
  #expect(released.routingState == .error)
  #expect(released.appliedVolume == nil)
  #expect(released.notes?.contains("paused automatic audio route rebuilds") == true)

  // The release is recoverable: once automatic rebuilds are allowed again,
  // the route comes back without the user pressing Recover Routes.
  fixture.budgetClock.value = .seconds(600)
  await maintenancePass(fixture, from: 200)
  #expect(fixture.events.creations == creations + 1)
  let recovered = try #require(await backend.currentSnapshot().apps.first)
  #expect(recovered.routingState == .managed)
  #expect(recovered.appliedVolume == 0.5)
  #expect(recovered.notes == nil)
}

@Test func aRepairThatFindsAnotherRouterOwningTheAppYieldsInsteadOfFallingBack() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await spendRebuildBudget(fixture)
  let creations = fixture.events.creations
  let incumbent = creations + 1
  // A format change whose rebuild the budget refuses: still pending.
  fixture.devices.set("builtin", .alive(rate96))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(40))
  #expect(fixture.events.hearing("app.a") == "waves #\(incumbent)")

  // By the time the budget allows the rebuild, another router owns the
  // app, and the incumbent's tap will not let go, so a managed release
  // would keep it playing. Waves yields: it must not render the app itself.
  fixture.routerRunning.value = true
  fixture.events.failNextMuteReleases(1_000)
  fixture.budgetClock.value = .seconds(600)
  await maintenancePass(fixture, from: 100)

  #expect(fixture.events.creations == creations)
  #expect(fixture.events.hearing("app.a") == "own output")
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.routingState == .monitorOnly)
  #expect(row.routeHealthContext == .unattributableRouterFallback)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
}

@Test func aRouteWhoseAggregateSilentlyStoppedIsRebuilt() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The device dropped and returned too fast for any listener to see, and
  // #1's aggregate stopped rendering. The app keeps playing into its tap.
  fixture.events.stopRendering(serial: 1)
  await maintenancePass(fixture, from: 10, ticks: 30)

  #expect(fixture.events.values == ["create app.a #2", "stop #1"])
  #expect(fixture.events.pumpRenders() == [2])
}

@Test func aRouteWhoseAggregateSilentlyStoppedIsReleasedIfItCannotBeRebuilt() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.stopRendering(serial: 1)
  fixture.events.failNextCreations(3)
  await maintenancePass(fixture, from: 10, ticks: 30)

  #expect(fixture.events.values.suffix(2) == ["audible #1", "stop #1"])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  #expect(await backend.currentSnapshot().apps.first?.notes?.contains("plays at its own volume") == true)
}

// MARK: - The handoff: silence first, one renderer at a time

@Test func anAbandonedRepairCannotUnmuteAnIncumbentThatANewerRebuildReplaces() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(apps: [routeTestApp()], retryPause: { _ in await gate.pause() })
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // A geometry repair's first creation fails and it pauses before retrying.
  fixture.events.failNextCreations(1)
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  let repair = Task { await backend.updateAudioLevels(at: .seconds(10)) }
  await gate.waitUntilPaused(count: 1)
  // A newer output choice fails its first creation too and pauses as well.
  fixture.events.failNextCreations(1)
  let choice = Task {
    await backend.applyAppIntent(
      routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
    )
  }
  await gate.waitUntilPaused(count: 2)

  // The repair resumes first, finds itself overtaken, and leaves the
  // incumbent alone: it is still the one renderer playing the app.
  await gate.releaseFirst()
  await repair.value
  #expect(fixture.events.pumpRenders() == [1])

  await gate.releaseFirst()
  #expect(await choice.value.outcome == .applied)
  #expect(fixture.events.values == ["fail app.a", "fail app.a", "create app.a #2", "stop #1"])
  #expect(fixture.events.overlaps.isEmpty)
  #expect(fixture.events.pumpRenders() == [2])
}

@Test func anIncumbentThatWillNotStopIsSilencedBeforeItsReplacementPlays() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextStops(1)

  let move = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(move.outcome == .applied)

  // #1 could not be stopped, so it is parked still running. It had faded out
  // before #2 was un-muted, so only #2 is heard.
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 1)
  #expect(fixture.events.pumpRenders() == [2])
  #expect(fixture.events.overlaps.isEmpty)

  // The parked teardown is retried on the maintenance tick. While #2 plays,
  // #1's tap is never told to un-mute: that could only add a second copy.
  for tick in 0..<20 {
    await backend.updateAudioLevels(at: .seconds(10 + tick))
  }
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 0)
  #expect(fixture.events.values.contains("stop #1"))
  #expect(!fixture.events.values.contains("audible #1"))
}

@Test func anIncumbentThatIsNotRenderingIsCutToSilenceBeforeItsReplacementPlays() async throws {
  // The outgoing renderer's device has stopped, so its fade never runs.
  let fixture = RouteFixture(apps: [routeTestApp()], rendersDuringHandoff: false)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextStops(1)

  let move = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(move.outcome == .applied)

  // If its device comes back before the parked teardown succeeds, #1 still
  // renders nothing: it was cut to silence rather than left mid-fade.
  #expect(fixture.events.pumpRenders() == [2])
  #expect(fixture.events.overlaps.isEmpty)
}

// MARK: - A parked controller never outlives its app's audibility

/// Level ticks, by default enough for one route-maintenance pass. Every
/// running controller renders a buffer before each tick, as its IO proc would.
private func maintenancePass(_ fixture: RouteFixture, from start: Int, ticks: Int = 20) async {
  for tick in 0..<ticks {
    fixture.events.pumpRenders()
    await fixture.backend.updateAudioLevels(at: .seconds(start + tick))
  }
}

@Test func aParkedControllerIsRetriedEveryPassWithoutLimitAndReleasedOnceItsRouteGoes() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // #1 is retired by a move and will not stop. While #2 plays, every pass
  // retries the teardown, however many have failed, and never un-mutes #1's
  // tap: #2's tap mutes the app and the app is heard through #2.
  fixture.events.failNextStops(1_000)
  let move = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(move.outcome == .applied)
  let passes = 10
  for pass in 0..<passes {
    await maintenancePass(fixture, from: 10 + pass * 20)
  }
  #expect(fixture.events.values.count { $0 == "stop failed #1" } == 1 + passes)
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == nil)
  #expect(fixture.events.pumpRenders() == [2])

  // The user excludes the app: #2 goes, fail open. The next pass releases
  // #1's tap too, and its teardown finishes, so it is forgotten.
  fixture.events.failNextStops(0)
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 11, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await maintenancePass(fixture, from: 500)
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == "audible #1")
  #expect(fixture.events.pumpRenders().isEmpty)
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 0)
}

@Test func quittingReleasesASilentRetireeThatWillNotStop() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 1)

  _ = await backend.shutdownWithResult()

  // Its stop fails again; its renderer is silent and its tap is released.
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == "audible #1")
  #expect(fixture.events.pumpRenders().isEmpty)
}

@Test func parkedControllersNeverStopTheUserRoutingTheApp() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextStops(1_000)

  // Each output change parks the route it replaced. Every change still
  // applies, and only the newest route is heard.
  let outputs = ["usb-dac", "headphones", "builtin"]
  var outcomes: [AppIntentApplyOutcome] = []
  for (offset, output) in outputs.enumerated() {
    let result = await backend.applyAppIntent(
      routeIntent(appID: "app.a", volume: 0.5, generation: UInt64(10 + offset), targetDeviceUID: output)
    )
    outcomes.append(result.outcome)
  }
  #expect(outcomes == [.applied, .applied, .applied])
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 3)
  #expect(fixture.events.pumpRenders() == [4])
  #expect(fixture.events.overlaps.isEmpty)

  // Memory, not behaviour, is what is bounded: a parked controller whose
  // teardown finishes is forgotten.
  fixture.events.failNextStops(0)
  await maintenancePass(fixture, from: 10)
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 0)
  #expect(fixture.events.pumpRenders() == [4])
}

@Test func anExcludedAppIsNeverRenderedByWavesEvenWhenItsTapWillNotRelease() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.4)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Excluding the app releases #1, but its tap will not un-mute and its
  // renderer will not stop. Waves must not keep rendering an excluded app.
  fixture.events.failNextMuteReleases(1_000)
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.4, generation: 10, isExcluded: true))
  #expect(fixture.events.pumpRenders().isEmpty)
  await maintenancePass(fixture, from: 10)
  #expect(fixture.events.pumpRenders().isEmpty)

  // The app is silent and Waves says so, on the row and in Diagnostics, and
  // keeps saying so through a refresh.
  _ = try await backend.refresh()
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.notes?.contains("could not release its hold on App app.a's sound") == true)
  #expect(row.appliedVolume == nil)
  let report = await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
  let check = try #require(report.checks.first { $0.title == "Closing audio routes" })
  #expect(check.status == .failed)
  #expect(check.detail.contains("App app.a"))

  // The user manages the app again. Only the new route is heard.
  let managed = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.4, generation: 11))
  #expect(managed.outcome == .applied)
  #expect(fixture.events.pumpRenders() == [2])
  #expect(fixture.events.overlaps.isEmpty)
  #expect(await backend.currentSnapshot().apps.first?.notes == nil)
}

@Test func aPinnedOutputReturningNeverCapturesAnAppHeldSilentByItsExclusion() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5, targetDeviceUID: "usb-dac")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Excluded, but the tap will neither release nor stop: parked, the app
  // held silent, the row in error.
  fixture.events.failNextMuteReleases(1_000)
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true))
  let held = try #require(await backend.currentSnapshot().apps.first)
  #expect(held.routingState == .error)
  #expect(held.isHeldSilentByWaves)
  // The backend keeps the excluded app's controls, pin included.
  #expect(held.targetDeviceUID == "usb-dac")

  // The pinned output appears again, a fresh event for the pinned route.
  // The exclusion still stands: nothing is built for the app.
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "usb-dac", "headphones"],
    appearedDeviceUIDs: ["usb-dac"]
  )
  await maintenancePass(fixture, from: 10)
  #expect(fixture.events.creations == 0)
  #expect(fixture.events.pumpRenders().isEmpty)

  // Only the user's own intent to manage it again builds a route.
  fixture.events.failNextStops(0)
  let managed = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 11, targetDeviceUID: "usb-dac")
  )
  #expect(managed.outcome == .applied)
  #expect(fixture.events.creations == 1)
}

@Test(arguments: [false, true])
func aParkedRendererIsNeverRevivedWhenItsAppLosesItsRoute(byYield: Bool) async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.8)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  // #1 is retired by a move and will not stop.
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.8, generation: 10, targetDeviceUID: "usb-dac")
  )
  // #2's route goes, by exclusion or by a yield to another router, and #1's
  // tap will never release. #1 stays silent: the app is not rendered by
  // Waves, at any level.
  fixture.events.failNextStops(0)
  fixture.events.failNextMuteReleases(1_000)
  if byYield {
    fixture.routerRunning.value = true
    await backend.yieldRouteToRouterForTesting(logicalID: "app.a")
  } else {
    _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.8, generation: 11, isExcluded: true))
  }
  fixture.events.failNextStops(1_000)
  await maintenancePass(fixture, from: 10)
  #expect(fixture.events.pumpRenders().isEmpty)

  // Later level and mute changes cannot reach it either.
  let parked = try #require(fixture.events.controller(serial: 1))
  parked.apply(volume: 0.2, volumeBoost: 1, muted: false)
  #expect(fixture.events.pumpRenders().isEmpty)
  #expect(await backend.currentSnapshot().apps.first?.notes?.contains("could not release its hold") == true)
}

@Test(arguments: ["exclusion", "yield", "release"])
func losingTheLastRouteReleasesEveryParkedHoldAtOnce(_ path: String) async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  // #1 is retired by a move and will not stop: parked, its tap still muting
  // while #2 plays the app.
  fixture.events.failNextStops(1)
  _ = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == nil)
  #expect(fixture.events.hearing("app.a") == "waves #2")

  // #2's route goes. Every release call would succeed, so the app is
  // audible straight away, before any maintenance pass runs.
  switch path {
  case "exclusion":
    _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 11, isExcluded: true))
  case "yield":
    fixture.routerRunning.value = true
    await backend.yieldRouteToRouterForTesting(logicalID: "app.a")
  default:
    // The pinned output disappears: a managed release with no successor.
    await backend.applyDeviceChangePlanForTesting(
      DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
      availableDeviceUIDs: ["builtin", "headphones"]
    )
  }
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == "audible #1")
  #expect(fixture.events.hearing("app.a") == "own output")
  #expect(await backend.currentSnapshot().apps.first?.isHeldSilentByWaves == false)
}

@Test func aDisposalWhoseStopFailsDuringAMuteFadeNeverPlaysBesideTheReleasedApp() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.pumpRenders()

  // The user mutes the app; the fade is queued but no buffer has rendered
  // since. Then the app is excluded: its tap is released (the app plays at
  // its own level) and its renderer will not stop.
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 10, isMuted: true))
  fixture.events.failNextStops(1)
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 11, isExcluded: true))

  // A mute request is not silence: the fade must not finish beside the app.
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == "audible #1")
  #expect(fixture.events.pumpRenders().isEmpty)
}

// MARK: - Silence is confirmed before anything else plays

/// Queues a render callback on `serial`'s callback queue behind one that is
/// still running, as Core Audio would. The gate opens from an independent
/// timer, so a regression cannot hang the suite. The returned box gets what
/// the user heard of app.a at the moment that callback ran. `serial` is
/// marked as no longer rendering for the fixture's own pumps, which would
/// otherwise wait on the blocked queue.
private func queueCallbackAheadOfTheBackend(_ fixture: RouteFixture, serial: Int) throws -> (
  heard: TestBox<String?>, controller: PerAppTapController
) {
  let controller = try #require(fixture.events.controller(serial: serial))
  fixture.events.stopRendering(serial: serial)
  let heard = TestBox<String?>(nil)
  let gate = DispatchSemaphore(value: 0)
  controller.occupyCallbackQueueForTesting(until: gate) {
    var parts = fixture.events.hearing("app.a").components(separatedBy: " + ").filter { $0 != "silent" }
    if fixture.events.peak(of: controller) > 0 { parts.append("waves #\(serial)") }
    heard.value = parts.isEmpty ? "silent" : parts.joined(separator: " + ")
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { gate.signal() }
  return (heard, controller)
}

@Test(.timeLimit(.minutes(1)))
func aCallbackAheadOfAManagedReleaseNeverPlaysBesideTheAppsOwnOutput() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5, targetDeviceUID: "usb-dac")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  let queued = try queueCallbackAheadOfTheBackend(fixture, serial: 1)

  // The pinned output goes: a managed release. The silence it queues cannot
  // land before the earlier callback, and the renderer will not stop.
  fixture.events.failNextStops(1)
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "headphones"]
  )
  #expect(!fixture.events.values.contains("audible #1"))
  _ = queued.controller.settledGainsForTesting()
  #expect(queued.heard.value == "waves #1")
  // Not handed back, and the row says so; the release is tried again later.
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.notes?.contains("still playing it at the level you set") == true)
  #expect(abs(fixture.events.peak(of: queued.controller) - 0.25) < 0.001)
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "headphones"]
  )
  #expect(fixture.events.ownOutputIsAudible("app.a"))
  #expect(fixture.events.peak(of: queued.controller) == 0)
}

@Test(.timeLimit(.minutes(1)))
func aCallbackAheadOfAForcedReleaseNeverPlaysBesideTheAppOrAReplacement() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  let queued = try queueCallbackAheadOfTheBackend(fixture, serial: 1)

  // Excluded while a callback is ahead of the cut, and #1 will not stop: the
  // tap keeps the app muted until the cut is confirmed.
  fixture.events.failNextStops(1)
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  #expect(!fixture.events.values.contains("audible #1"))
  #expect(await backend.currentSnapshot().apps.first?.isHeldSilentByWaves == true)
  // Managed again at once: the parked renderer is not confirmed silent, so
  // the replacement is discarded rather than un-muted beside it.
  let managed = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 11))
  #expect(managed.outcome == .failed)
  _ = queued.controller.settledGainsForTesting()
  #expect(queued.heard.value == "waves #1")

  // The queue has drained: the next pass lets the app go, and the user's
  // next try installs a route.
  await maintenancePass(fixture, from: 10)
  #expect(fixture.events.hearing("app.a") == "own output")
  let retried = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 12))
  #expect(retried.outcome == .applied)
  #expect(fixture.events.hearing("app.a") == "waves #3")
  #expect(fixture.events.overlaps.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aHandoffThatCannotConfirmSilenceKeepsTheIncumbentAndDiscardsTheReplacement() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)], rendersDuringHandoff: false)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  let queued = try queueCallbackAheadOfTheBackend(fixture, serial: 1)

  // A move to another output while a callback is ahead of the mute; the
  // first renderer stop fails.
  fixture.events.failNextStops(1)
  let move = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(move.outcome == .failed)
  _ = queued.controller.settledGainsForTesting()
  #expect(queued.heard.value == "waves #1")
  // #1 is still the route, back at its level; #2 never left silence.
  _ = fixture.events.peak(of: queued.controller)
  #expect(abs(fixture.events.peak(of: queued.controller) - 0.25) < 0.001)
  #expect(fixture.events.pumpRenders().isEmpty)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
}

// MARK: - Every disposal kind leaves the app audible, or says why not

enum DisposalPath: String, CaseIterable, Sendable {
  /// A move to another output: a live successor takes over.
  case retirement
  /// Exclusion: Waves must not render the app at all.
  case forcedRelease
  /// A failed format repair: no successor, and the old route still renders,
  /// so Waves may keep playing the app.
  case managedRelease
  /// The pinned output is unplugged: no successor, and the route renders
  /// nothing, so it cannot carry the app either.
  case managedReleaseOfADeadRoute
}

enum TeardownFailure: String, CaseIterable, Sendable {
  case none, release, stop, destroy, releaseAndStop, releaseAndDestroy

  var failsRelease: Bool { [.release, .releaseAndStop, .releaseAndDestroy].contains(self) }
  var failsStop: Bool { [.stop, .releaseAndStop].contains(self) }
  var failsDestroy: Bool { [.destroy, .releaseAndDestroy].contains(self) }
}

/// What the user hears right after each disposal: the route that replaced
/// it, the app's own output, or, for a managed release of a route that still
/// renders and whose tap would not let go, the same renderer at the level
/// the user set. A release whose tap neither releases nor goes away leaves
/// the app silent only when no Waves renderer may or can play it (an
/// excluded app, a dead route); the row says so.
func expectedHearing(_ path: DisposalPath, _ failure: TeardownFailure) -> String {
  switch path {
  case .retirement:
    "waves #2"
  case .forcedRelease, .managedReleaseOfADeadRoute:
    failure == .releaseAndStop || failure == .releaseAndDestroy ? "silent" : "own output"
  case .managedRelease:
    failure.failsRelease ? "waves #1" : "own output"
  }
}

@Test(arguments: DisposalPath.allCases, TeardownFailure.allCases)
func everyDisposalLeavesTheAppAudibleOneWayOrTheOther(_ path: DisposalPath, _ failure: TeardownFailure) async throws {
  let fixture = RouteFixture(
    apps: [routeTestApp(volume: 0.5, targetDeviceUID: path == .managedReleaseOfADeadRoute ? "usb-dac" : nil)]
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  #expect(fixture.events.hearing("app.a") == "waves #1")
  // Also sampled at the instant each tap stops muting the app.
  fixture.events.samplesHearingAtRelease = true

  // A failing call keeps failing, however often it is retried.
  if failure.failsRelease { fixture.events.failNextMuteReleases(1_000) }
  if failure.failsStop { fixture.events.failNextStops(1_000) }
  if failure.failsDestroy { fixture.events.failNextDestroys(.processTapDestroy, 1_000) }
  switch path {
  case .retirement:
    let move = await backend.applyAppIntent(
      routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
    )
    #expect(move.outcome == .applied)
  case .forcedRelease:
    let exclusion = await backend.applyAppIntent(
      routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true)
    )
    #expect(exclusion.outcome == .excluded)
  case .managedRelease:
    fixture.devices.set("builtin", .alive(rate96))
    fixture.events.failNextCreations(3)
    await backend.revalidateRouteFormatsForTesting(at: .seconds(10))
  case .managedReleaseOfADeadRoute:
    // Unplugged for real: gone from the device list, and the aggregate on
    // it renders nothing.
    fixture.events.stopRendering(serial: 1)
    fixture.devices.set("usb-dac", .missing)
    fixture.inventory.set([10: "builtin", 30: "headphones"])
    await backend.applyDeviceChangePlanForTesting(
      DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
      availableDeviceUIDs: ["builtin", "headphones"]
    )
  }

  let heard = fixture.events.hearing("app.a")
  #expect(heard == expectedHearing(path, failure))
  #expect(!heard.contains("+"), "the app's own output and a Waves renderer must never play together")
  #expect(!fixture.events.heardAtRelease.contains { $0.contains("+") }, "\(fixture.events.heardAtRelease)")
  // A Waves renderer that still plays the app plays it at the level the
  // user set (input 0.5 x volume 0.5), never louder.
  if let serial = Int(heard.split(separator: "#").last ?? ""), heard.hasPrefix("waves") {
    fixture.events.pumpRenders()
    let peak = try #require(fixture.events.lastPeak(serial: serial))
    #expect(abs(peak - 0.25) < 0.001)
  }

  let row = try #require(await backend.currentSnapshot().apps.first)
  switch path {
  case .retirement:
    #expect(row.routingState == .managed)
    #expect(row.appliedVolume == 0.5)
  case .forcedRelease:
    // Silent only because Waves could not let go: the row says so at once.
    #expect(row.isHeldSilentByWaves == (heard == "silent"))
    if heard == "silent" {
      #expect(row.routingState == .error)
      #expect(row.notes?.contains("could not release its hold on App app.a's sound") == true)
    } else {
      #expect(row.routingState == .monitorOnly)
      #expect(row.notes == nil)
    }
  case .managedRelease:
    #expect(row.routingState == .error)
    if failure.failsRelease {
      #expect(row.notes?.contains("couldn't hand App app.a back to macOS, so it is still playing it at the level you set") == true)
      #expect(row.appliedVolume == 0.5)
    } else {
      #expect(row.notes?.contains("plays at its own volume") == true)
      #expect(row.appliedVolume == nil)
    }
  case .managedReleaseOfADeadRoute:
    // Never claims to play the app through a route that renders nothing.
    #expect(row.routingState == .error)
    #expect(row.isHeldSilentByWaves == (heard == "silent"))
    #expect(row.notes?.contains("still playing it") != true)
    if heard == "silent" {
      #expect(row.notes?.contains("could not release its hold on App app.a's sound") == true)
    } else {
      #expect(row.notes?.contains("chosen output device for App app.a is unavailable") == true)
      #expect(row.appliedVolume == nil)
    }
  }
}

@Test func aRouteThatCouldNotBeHandedBackFollowsTheUserAndCanBeReleasedLater() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5, targetDeviceUID: "usb-dac")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextMuteReleases(1)
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "headphones"]
  )
  #expect(fixture.events.hearing("app.a") == "waves #1")
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
  #expect(await backend.lifecycleDebugSnapshot().orphanedControllers == 0)

  // The explanation survives a refresh: the live route does not claim to be healthy.
  _ = try await backend.refresh()
  #expect(await backend.currentSnapshot().apps.first?.notes?.contains("still playing it at the level you set") == true)

  // It is still the app's route: it follows the user's level and mute.
  let quieter = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.3, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(quieter.outcome == .applied)
  fixture.events.pumpRenders()
  fixture.events.pumpRenders()
  #expect(abs((fixture.events.lastPeak(serial: 1) ?? 0) - 0.15) < 0.001)
  let muted = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.3, generation: 11, isMuted: true, targetDeviceUID: "usb-dac")
  )
  #expect(muted.outcome == .applied)
  fixture.events.pumpRenders()
  #expect(fixture.events.hearing("app.a") == "silent")

  // And it can be released later, once its tap lets go.
  let exclusion = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.3, generation: 12, isExcluded: true))
  #expect(exclusion.outcome == .excluded)
  #expect(fixture.events.hearing("app.a") == "own output")
  #expect(fixture.events.creations == 0)
}

@Test func quittingHandsEveryAppBackBeforeStoppingAnyRenderer() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  // app.a's route is retired by a move and parked (it will not stop).
  fixture.events.failNextStops(1)
  _ = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  fixture.events.reset()

  _ = await backend.shutdownWithResult()

  // Every tap is released, installed and parked alike, before the first
  // renderer is stopped or anything is destroyed.
  let values = fixture.events.values
  let firstStop = try #require(values.firstIndex { $0.hasPrefix("stop") })
  #expect(Set(values[..<firstStop]) == ["audible #2", "audible #3", "audible #1"])
  #expect(fixture.events.hearing("app.a") == "own output")
  #expect(fixture.events.hearing("app.b") == "own output")
}

@Test func handingAppsBackForQuitKeepsTheSessionReadableAndAdmitsNoNewRoute() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  await backend.handBackAppsForShutdown()
  #expect(fixture.events.hearing("app.a") == "own output")
  #expect(await backend.currentSnapshot().apps.count == 1)
  let late = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.7, generation: 10))
  #expect(late.outcome == .failed)
  #expect(fixture.events.creations == 0)

  // The rest of shutdown tears down what was handed back, once.
  let result = await backend.shutdownWithResult()
  #expect(result.completion == .clean)
  #expect(fixture.events.values.filter { $0.hasPrefix("audible") } == ["audible #1"])
  #expect(fixture.events.values.contains("stop #1"))
}

@Test func quittingKeepsPlayingAnAppItCouldNotHandBackAndSaysSo() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  fixture.events.failNextMuteReleases(1)

  let result = await fixture.backend.shutdownWithResult()

  #expect(fixture.events.hearing("app.a") == "waves #1")
  #expect(result.degradations.contains { $0.detail?.contains("played through Waves until Waves exited") == true })
}

// MARK: - A route discovery drops is never left installed and unreachable

@Test func aRouteWhoseRowDiscoveryDroppedStaysVisibleUntilItIsReleased() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Discovery misses the app, whose process is still running, and its
  // tap will not let go once: still routing, and still on the list.
  fixture.lifetimeLiveness.value = true
  fixture.captured.value = []
  fixture.events.failNextMuteReleases(1)
  _ = try await backend.refresh()
  #expect(fixture.events.hearing("app.a") == "waves #1")
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.notes?.contains("still playing it at the level you set") == true)

  // So the user's exclusion still reaches it.
  let exclusion = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true))
  #expect(exclusion.outcome == .excluded)
  #expect(fixture.events.hearing("app.a") == "own output")
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
}

@Test func aReleaseThatKeepsFailingIsRetriedWithBackoffWhileTheRouteKeepsPlaying() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.lifetimeLiveness.value = true
  fixture.captured.value = []
  fixture.events.failNextMuteReleases(1_000)
  func attempts() -> Int { fixture.events.values.count { $0 == "release failed #1" } }
  func refresh(after seconds: Int) async throws {
    fixture.budgetClock.value += .seconds(seconds)
    _ = try await backend.refresh()
  }

  // Each refresh would retry the release. The first failure waits one
  // maintenance cadence, then the wait doubles.
  try await refresh(after: 0)
  try await refresh(after: 0)
  #expect(attempts() == 1)
  try await refresh(after: 5)
  #expect(attempts() == 2)
  try await refresh(after: 5)
  #expect(attempts() == 2)
  try await refresh(after: 5)
  #expect(attempts() == 3)
  #expect(fixture.events.hearing("app.a") == "waves #1")

  // A device coming or going is worth trying again at once.
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "headphones"]
  )
  try await refresh(after: 0)
  #expect(attempts() == 4)
}

@Test func aRouteWhoseProcessIsGoneIsForceReleasedEvenIfItsTapWillNotLetGo() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  fixture.lifetimeLiveness.value = false
  fixture.captured.value = []
  fixture.events.failNextMuteReleases(1_000)
  _ = try await backend.refresh()

  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  #expect(fixture.events.pumpRenders().isEmpty)
  #expect(fixture.events.ownOutputIsAudible("app.a"))
}

@Test func terminationAndExclusionReachAControllerThatHasNoRow() async throws {
  let identity = routeTestIdentity("app.c")
  func backend(owning controller: PerAppTapController) -> WorkspaceAudioControlBackend {
    WorkspaceAudioControlBackend(testingSnapshot: .empty, testingControllers: [controller])
  }
  let terminated = try PerAppTapController.testingController(appID: "app.c")
  terminated.ownerProcessLifetime = identity.lifetime
  let afterTermination = backend(owning: terminated)
  await afterTermination.releaseControllers(forRuntimeIdentity: identity)
  #expect(await afterTermination.lifecycleDebugSnapshot().liveControllers == 0)

  let excluded = try PerAppTapController.testingController(appID: "app.c")
  let afterExclusion = backend(owning: excluded)
  _ = await afterExclusion.applyAppIntent(routeIntent(appID: "app.c", volume: 1, generation: 1, isExcluded: true))
  #expect(await afterExclusion.lifecycleDebugSnapshot().liveControllers == 0)
}

// MARK: - A route released by a failed repair is recoverable and truthful

/// Releases app.a's route: its device resets to 96 kHz, its aggregate stops
/// rendering, and every rebuild attempt fails.
private func releaseAfterFailedRepair(_ fixture: RouteFixture, app: String = "app.a") async {
  fixture.events.stopRendering(serial: 1)
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(3)
  await fixture.backend.revalidateRouteFormatsForTesting(at: .seconds(10))
}

@Test func aRouteReleasedByAFailedRepairComesBackOnceItCanBeBuilt() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await releaseAfterFailedRepair(fixture)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)

  // Paused: nothing to tap, so no attempt is made (or spent).
  fixture.playing.value = false
  await maintenancePass(fixture, from: 20)
  // Playing, but its output device is mid-reset.
  fixture.playing.value = true
  fixture.devices.set("builtin", .notAlive)
  await maintenancePass(fixture, from: 40)
  #expect(fixture.events.creations == 0)

  // The device reports a usable format: the next pass rebuilds the route.
  fixture.devices.set("builtin", .alive(rate96))
  await maintenancePass(fixture, from: 60)
  #expect(fixture.events.creations == 1)
  #expect(fixture.events.pumpRenders() == [2])
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .managed)
  #expect(app.appliedVolume == 0.5)
  #expect(app.notes == nil)
}

@Test(arguments: ["exclusion", "yield", "newer intent"])
func aReleasedRouteIsNeverRebuiltAfterNewerOwnership(_ change: String) async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await releaseAfterFailedRepair(fixture)

  switch change {
  case "exclusion":
    _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true))
  case "yield":
    fixture.routerRunning.value = true
    await backend.yieldRouteToRouterForTesting(logicalID: "app.a")
  default:
    // A newer edit that itself fails: the user's newest intent owns the row.
    fixture.events.failNextCreations(3)
    _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.3, generation: 10))
  }
  for pass in 0..<3 {
    await maintenancePass(fixture, from: 20 + pass * 20)
  }
  #expect(fixture.events.creations == 0)
  #expect(fixture.events.pumpRenders().isEmpty)
}

@Test func automaticRetriesAfterAFailOpenReleaseAreBounded() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await releaseAfterFailedRepair(fixture)
  fixture.events.failNextCreations(1_000)

  for pass in 0..<6 {
    await maintenancePass(fixture, from: 20 + pass * 20)
  }

  // Three creation tries for the repair itself, then three for each of the
  // bounded number of retries, and nothing after that.
  let attempts = fixture.events.values.count { $0 == "fail app.a" }
  #expect(attempts == 3 + 3 * FailOpenRelease.maximumAttempts)
  #expect(await backend.currentSnapshot().apps.first?.notes?.contains("plays at its own volume") == true)
}

@Test func theFirstDeviceListPassDoesNotTreatEveryPresentOutputAsNew() async throws {
  // A pinned route released before observation started; its output is
  // present the whole time.
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a", routingState: .error, targetDeviceUID: "usb-dac")])
  let backend = fixture.backend
  await backend.startObservingDeviceChangesForTesting()

  // The first device-list notification, with nothing added or removed.
  await backend.performDeviceChangePassForTesting(changes: [.deviceInventory])

  #expect(fixture.events.creations == 0)
}

@Test func anUnrelatedDeviceChangeNeverRetriesAPinnedRouteWhoseAllowanceIsSpent() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.5, targetDeviceUID: "usb-dac")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  // The pinned output resets to 96 kHz, #1's aggregate died, and no rebuild
  // will work: released fail open, then retried until its allowance is spent.
  fixture.events.stopRendering(serial: 1)
  fixture.devices.set("usb-dac", .alive(rate96))
  fixture.events.failNextCreations(1_000)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  for pass in 0..<6 {
    await maintenancePass(fixture, from: 20 + pass * 20)
  }
  func failedTries() -> Int { fixture.events.values.count { $0 == "fail app.a" } }
  let spent = failedTries()
  #expect(spent == 3 + 3 * FailOpenRelease.maximumAttempts)

  // The headphones are unplugged. Nothing about usb-dac changed, so its
  // route is not retried, however available its output is.
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "usb-dac"]
  )
  #expect(failedTries() == spent)

  // usb-dac itself leaves and comes back: a fresh allowance, spent one
  // attempt at a time by every automatic path alike.
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin"]
  )
  await backend.applyDeviceChangePlanForTesting(
    DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
    availableDeviceUIDs: ["builtin", "usb-dac"],
    appearedDeviceUIDs: ["usb-dac"]
  )
  #expect(failedTries() == spent + 3)
  // The maintenance retry spends the rest of that allowance once the rebuild
  // budget, which these failures used up, allows automatic work again.
  fixture.budgetClock.value = .seconds(5_000)
  for pass in 0..<6 {
    await maintenancePass(fixture, from: 300 + pass * 20)
  }
  #expect(failedTries() == spent + 3 * FailOpenRelease.maximumAttempts)
  #expect(fixture.events.creations == 0)
}

@Test func aReleasedForegroundAppKeepsItsExplanationAndUnknownLevelAcrossRefreshes() async throws {
  // An ordinary app the user launched: discovery reports it as a fresh
  // candidate on every refresh, and merges the backend's state into it.
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "com.example.player", volume: 0.3, bundleID: "com.example.player")],
    foreground: true
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.stopRendering(serial: 1)
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(1_000)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))

  // Released at the app's own level, which Waves did not set and cannot read.
  func expectReleasedRow() async throws {
    let app = try #require(await backend.currentSnapshot().apps.first)
    #expect(app.routingState == .error)
    #expect(app.appliedVolume == nil)
    #expect(app.notes?.contains("plays at its own volume") == true)
  }
  try await expectReleasedRow()
  _ = try await backend.refresh()
  try await expectReleasedRow()
  // Discovery now hears it playing (at its own level). That is no reason to
  // claim the old attenuated level or drop the explanation.
  fixture.audiblePIDs.value = [900]
  _ = try await backend.refresh()
  try await expectReleasedRow()
}

// MARK: - Recovery state belongs to one process lifetime

private let playerID = "com.example.player"

private func foregroundPlayerFixture() -> RouteFixture {
  RouteFixture(apps: [routeTestApp(id: playerID, volume: 0.3, bundleID: playerID)], foreground: true)
}

@Test func aRepairRecordedForAnAppNeverCapturesItsRelaunchedProcess() async throws {
  let fixture = foregroundPlayerFixture()
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.stopRendering(serial: 1)
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(3)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)

  // The app quits and opens again between two snapshots, with no snapshot
  // in which it was absent. Same IDs, generation, output and router state.
  fixture.relaunch(bundleID: playerID)
  _ = try await backend.refresh()
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.runtimeIdentity?.lifetime.pid == 901)
  #expect(row.notes?.contains("plays at its own volume") != true)
  #expect(row.routingState != .error)

  // The old process's repair authorizes nothing for the new one.
  for pass in 0..<3 {
    await maintenancePass(fixture, from: 20 + pass * 20)
  }
  #expect(fixture.events.creations == 0)
}

@Test func aTapHeldForAnEarlierProcessDoesNotClaimTheRelaunchedApp() async throws {
  let fixture = foregroundPlayerFixture()
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextMuteReleases(1_000)
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(routeIntent(appID: playerID, volume: 0.3, generation: 10, isExcluded: true))
  #expect(await backend.currentSnapshot().apps.first?.isHeldSilentByWaves == true)

  // The tap targets the process that quit; the relaunched one plays freely.
  fixture.relaunch(bundleID: playerID)
  _ = try await backend.refresh()
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.isHeldSilentByWaves == false)
  #expect(row.notes?.contains("could not release its hold") != true)
}

@Test func anIdentityCollisionExplainsTheRowRatherThanAStaleRepairNote() async throws {
  let fixture = foregroundPlayerFixture()
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.stopRendering(serial: 1)
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(3)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))

  fixture.addImpostor(bundleID: playerID)
  _ = try await backend.refresh()
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.hasAmbiguousIdentity)
  #expect(row.notes == AppRuntimeDiscovery.identityCollisionNote)
}

// MARK: - A replacement that will not start

@Test func aReplacementThatWillNotStartNeverUnmutesItsTapBesideTheLiveRoute() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  let events = fixture.events
  let replacement = try PerAppTapController.testingController(
    appID: "app.a",
    muted: true,
    teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
      makeOriginalAudioAudible: {
        events.record("audible #99")
        return noErr
      },
      stopIOProc: {
        events.record("stop #99")
        return noErr
      }
    )
  )

  // #1 plays the app. The new controller's IO proc fails to start.
  var startFailed = false
  do {
    try await backend.startNewControllerForTesting(replacement, runtimeID: "app.a") {
      throw BackendError.managedRouteUnavailable("Injected start failure")
    }
  } catch {
    startFailed = true
  }
  #expect(startFailed)
  // Retired, not released: #1's route is the one the user hears.
  #expect(events.values == ["stop #99"])
  #expect(events.pumpRenders() == [1])
}

@Test func aLoneControllerThatWillNotStartIsReleasedFailOpen() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(routingState: .monitorOnly)])
  let backend = fixture.backend
  let events = fixture.events
  let controller = try PerAppTapController.testingController(
    appID: "app.a",
    muted: true,
    teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
      makeOriginalAudioAudible: {
        events.record("audible #99")
        return noErr
      },
      stopIOProc: {
        events.record("stop #99")
        return noErr
      }
    )
  )
  var startFailed = false
  do {
    try await backend.startNewControllerForTesting(controller, runtimeID: "app.a") {
      throw BackendError.managedRouteUnavailable("Injected start failure")
    }
  } catch {
    startFailed = true
  }
  #expect(startFailed)
  #expect(events.values == ["audible #99", "stop #99"])
}

// MARK: - A move to a new default is never lost to newer work

@Test func aVolumeEditThatOvertakesAMoveToTheNewDefaultStillMovesTheRoute() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(apps: [routeTestApp()], retryPause: { _ in await gate.pause() })
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The default changes from the built-in output to headphones. The move's
  // first creation fails and it pauses before retrying.
  fixture.devices.defaultUID = "headphones"
  fixture.events.failNextCreations(1)
  let move = Task { try await backend.autoRestoreDevice() }
  await gate.waitUntilPaused()

  // A volume edit lands meanwhile and supersedes the move.
  let edit = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.2, generation: 10))
  #expect(edit.outcome == .applied)
  await gate.release()
  _ = try await move.value

  // The edit itself moved the route rather than leaving it on the old device.
  #expect(await backend.routeOutputBindingForTesting(runtimeID: "app.a")?.deviceUID == "headphones")
  #expect(fixture.events.values == ["fail app.a", "create app.a #2", "stop #1"])
  #expect(fixture.events.overlaps.isEmpty)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .managed)
  #expect(app.appliedVolume == 0.2)
}

@Test func maintenanceMovesARouteLeftOnADeviceItShouldNoLongerPlayOn() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The default changed but no pass moved the route (the event was consumed
  // by work that was then overtaken).
  fixture.devices.defaultUID = "headphones"
  for tick in 0..<20 {
    await backend.updateAudioLevels(at: .seconds(10 + tick))
  }

  #expect(await backend.routeOutputBindingForTesting(runtimeID: "app.a")?.deviceUID == "headphones")
  #expect(fixture.events.creations == 1)
  #expect(await backend.currentSnapshot().apps.first?.routingState == .managed)

  // Once moved, maintenance leaves it alone.
  for tick in 20..<40 {
    await backend.updateAudioLevels(at: .seconds(10 + tick))
  }
  #expect(fixture.events.creations == 1)
}

@Test func aRouteMaintenanceCannotMoveIsReleasedAndSaysWhy() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.devices.defaultUID = "headphones"
  fixture.events.failNextCreations(3)

  for tick in 0..<20 {
    await backend.updateAudioLevels(at: .seconds(10 + tick))
  }

  #expect(fixture.events.values.suffix(2) == ["audible #1", "stop #1"])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .error)
  #expect(app.notes?.contains("plays at its own volume") == true)
}

// MARK: - The recorded binding is the successful attempt's

@Test func aRetriedCreationRecordsTheDeviceAndFormatItActuallyUsed() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(targetDeviceUID: "usb-dac")],
    retryPause: { _ in await gate.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The user unpins the app; its first creation on the default fails.
  fixture.events.failNextCreations(1)
  let unpin = Task {
    await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 10))
  }
  await gate.waitUntilPaused()
  // The default changes while the retry waits. The committed row still looks
  // pinned, so no device-change pass would move this route.
  fixture.devices.defaultUID = "headphones"
  await gate.release()
  #expect(await unpin.value.outcome == .applied)
  #expect(await backend.routeOutputBindingForTesting(runtimeID: "app.a")?.deviceUID == "headphones")

  // So a rate change on the device it really plays on is noticed.
  fixture.devices.set("headphones", .alive(rate96))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))
  #expect(fixture.events.creations == 2)
}

@Test func aRouteBuiltWhileItsDeviceFormatWasUnreadableStillRecordsItsDevice() async throws {
  // The built-in output's format cannot be read while the route is built
  // (mid-reset, say); the route itself is created fine.
  let fixture = RouteFixture(apps: [routeTestApp()])
  fixture.devices.set("builtin", .notAlive)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  #expect(await backend.routeOutputBindingForTesting(runtimeID: "app.a") == RouteOutputBinding(deviceUID: "builtin", signature: nil))

  // The default moves on; a volume edit must not take the old route as
  // correctly placed just because its format was never recorded.
  fixture.devices.set("builtin", .alive(rate48))
  fixture.devices.defaultUID = "headphones"
  let edit = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.2, generation: 10))
  #expect(edit.outcome == .applied)
  #expect(await backend.routeOutputBindingForTesting(runtimeID: "app.a")?.deviceUID == "headphones")
  #expect(fixture.events.values == ["create app.a #2", "stop #1"])
}

@Test func aRouteWithNoRecordedFormatIsRebuiltOnceItsDeviceReportsOne() {
  let bindings = ["a": RouteOutputBinding(deviceUID: "builtin", signature: nil)]
  let decision = RouteFormatRevalidation.decide(
    bindings: bindings,
    observations: ["builtin": .alive(rate48)],
    devicesPreviouslySeenNotAlive: []
  )
  #expect(decision.runtimeIDsToRebuild == ["a"])
}

// MARK: - Queued repairs carry the authorization they were selected with

@Test func aMoveCannotRecreateAnAppExcludedWhileAnEarlierRouteWasRetrying() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")],
    retryPause: { _ in await gate.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The default changes; app.a's move fails once and pauses.
  fixture.devices.defaultUID = "headphones"
  fixture.events.failNextCreations(1)
  let move = Task { try await backend.autoRestoreDevice() }
  await gate.waitUntilPaused()
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.b", volume: 0.5, generation: 10, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await gate.release()
  _ = try await move.value

  // app.b's route is released by the exclusion itself and never rebuilt.
  #expect(fixture.events.values == ["fail app.a", "audible #2", "stop #2", "create app.a #3", "stop #1"])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
  let excluded = try #require(await backend.currentSnapshot().apps.first { $0.id == "app.b" })
  #expect(excluded.routingState == .monitorOnly)
}

@Test func aFormatRebuildBatchCannotRecreateAnAppYieldedToAnotherRouter() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")],
    retryPause: { _ in await gate.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Both routes are on the built-in output, which changes rate. app.a's
  // rebuild fails once and pauses; meanwhile app.b is yielded to a router.
  fixture.devices.set("builtin", .alive(rate96))
  fixture.events.failNextCreations(1)
  let revalidation = Task { await backend.revalidateRouteFormatsForTesting(at: .seconds(10)) }
  await gate.waitUntilPaused()
  await backend.yieldRouteToRouterForTesting(logicalID: "app.b")
  await gate.release()
  await revalidation.value

  #expect(fixture.events.creations == 1)
  #expect(fixture.events.values.contains("create app.a #3"))
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
  let yielded = try #require(await backend.currentSnapshot().apps.first { $0.id == "app.b" })
  #expect(yielded.routingState == .monitorOnly)
}

@Test func aReattachCannotCaptureARouteWithNoControllerThatWasYieldedMeanwhile() async throws {
  let gate = RetryGate()
  // Two routes pinned to a DAC that was unplugged: no controllers, in error.
  let fixture = RouteFixture(
    apps: [
      routeTestApp(id: "app.a", routingState: .error, targetDeviceUID: "usb-dac"),
      routeTestApp(id: "app.b", routingState: .error, targetDeviceUID: "usb-dac"),
    ],
    retryPause: { _ in await gate.pause() }
  )
  let backend = fixture.backend

  // The DAC comes back; app.a's reattach fails once and pauses. app.b is
  // yielded to a router meanwhile, which changes neither its generation nor
  // its (absent) controller, only its routing state.
  fixture.events.failNextCreations(1)
  let reattach = Task {
    await backend.applyDeviceChangePlanForTesting(
      DeviceChangePassPlan(defaultOutputChanged: false, inventoryChanged: true),
      availableDeviceUIDs: ["builtin", "usb-dac"],
      appearedDeviceUIDs: ["usb-dac"]
    )
  }
  await gate.waitUntilPaused()
  await backend.yieldRouteToRouterForTesting(logicalID: "app.b")
  await gate.release()
  await reattach.value

  #expect(fixture.events.values == ["fail app.a", "create app.a #1"])
  let yielded = try #require(await backend.currentSnapshot().apps.first { $0.id == "app.b" })
  #expect(yielded.routingState == .monitorOnly)
}

@Test func maintenanceCannotRecreateAnAppExcludedWhileAnEarlierRouteWasRetrying() async throws {
  let gate = RetryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")],
    retryPause: { _ in await gate.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Both routes are on the old default; the maintenance pass moves them.
  fixture.devices.defaultUID = "headphones"
  fixture.events.failNextCreations(1)
  let maintenance = Task {
    for tick in 0..<20 {
      await backend.updateAudioLevels(at: .seconds(10 + tick))
    }
  }
  await gate.waitUntilPaused()
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.b", volume: 0.5, generation: 10, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await gate.release()
  await maintenance.value

  #expect(fixture.events.creations == 1)
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
  let excluded = try #require(await backend.currentSnapshot().apps.first { $0.id == "app.b" })
  #expect(excluded.routingState == .monitorOnly)
}

// MARK: - Authorization is captured before discovery suspends

@Test func aDefaultMoveCannotRecreateAnAppExcludedWhileDiscoveryRan() async throws {
  let discovery = DiscoveryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")],
    discoveryPause: { await discovery.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // The default changes. The pass's snapshot rebuild suspends in application
  // capture, and the user excludes app.b meanwhile.
  fixture.devices.defaultUID = "headphones"
  await discovery.arm()
  let move = Task { try await backend.autoRestoreDevice() }
  await discovery.waitUntilPaused()
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.b", volume: 0.5, generation: 10, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await discovery.release()
  _ = try await move.value

  // app.a moved; app.b stays released and unmanaged.
  #expect(fixture.events.values == ["audible #2", "stop #2", "create app.a #3", "stop #1"])
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 1)
  let excluded = try #require(await backend.currentSnapshot().apps.first { $0.id == "app.b" })
  #expect(excluded.routingState == .monitorOnly)
  #expect(excluded.appliedVolume == nil)
}

@Test func recoverRoutesCannotRecreateAnAppExcludedWhileDiscoveryRan() async throws {
  let discovery = DiscoveryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")],
    discoveryPause: { await discovery.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  await discovery.arm()
  let recovery = Task { try await backend.recoverRoutes() }
  await discovery.waitUntilPaused()
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.b", volume: 0.5, generation: 10, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await discovery.release()
  _ = try await recovery.value

  #expect(!fixture.events.values.contains { $0.hasPrefix("create app.b") })
  #expect(fixture.events.values.contains("create app.a #3"))
  let excluded = try #require(await backend.currentSnapshot().apps.first { $0.id == "app.b" })
  #expect(excluded.routingState == .monitorOnly)
}

@Test func discoveryKeepsControlStateThatLandedWhileItRan() async throws {
  let discovery = DiscoveryGate()
  let fixture = RouteFixture(
    apps: [routeTestApp(id: "app.a"), routeTestApp(id: "app.b")],
    discoveryPause: { await discovery.pause() }
  )
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // A refresh suspends in discovery. A call mutes app.a and a profile moves
  // app.b to the USB DAC before it resumes.
  await discovery.arm()
  let refresh = Task { try await backend.refresh() }
  await discovery.waitUntilPaused()
  let mute = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, isMuted: true)
  )
  #expect(mute.outcome == .applied)
  let output = await backend.applyAppIntent(
    routeIntent(appID: "app.b", volume: 0.5, generation: 11, targetDeviceUID: "usb-dac")
  )
  #expect(output.outcome == .applied)
  await discovery.release()
  _ = try await refresh.value

  let apps = await backend.currentSnapshot().apps
  let muted = try #require(apps.first { $0.id == "app.a" })
  #expect(muted.isMuted)
  #expect(muted.appliedVolume == 0)
  #expect(apps.first { $0.id == "app.b" }?.targetDeviceUID == "usb-dac")
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

@Test func aRouteWhoseGeometryRecoveryIsSpentIsNeverKeptAsTheAudibleFallback() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Its callbacks reject every buffer, so it renders nothing; every rebuild
  // fails; and its tap will not let go when asked.
  fixture.events.stopRendering(serial: 1)
  fixture.events.failNextCreations(1_000)
  fixture.events.failNextMuteReleases(1_000)
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  for second in 10...12 { await backend.updateAudioLevels(at: .seconds(second)) }

  // Not kept as a fallback that plays nothing: torn down, so the app plays.
  #expect(fixture.events.hearing("app.a") == "own output")
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  // Later mismatches find nothing to rebuild, and the row stays terminal.
  await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
  for second in 13...15 { await backend.updateAudioLevels(at: .seconds(second)) }
  let row = try #require(await backend.currentSnapshot().apps.first)
  #expect(row.routeHealthContext == .geometryRecoveryExhausted)
  #expect(row.notes?.contains("recovery failed") == true)
  #expect(row.notes?.contains("still playing it") != true)
  #expect(row.notes?.contains("rebuilding") != true)
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
  #expect(fixture.events.values == ["create app.a #3", "stop #1"])

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

private func listenerLifecycle(_ calls: ListenerCalls) -> DeviceFormatListenerLifecycle {
  DeviceFormatListenerLifecycle(nativeCalls: calls.nativeCalls)
}

extension DeviceFormatListenerLifecycle {
  fileprivate func sync(
    deviceIDs: Set<AudioObjectID>,
    onChange: @escaping @Sendable () -> Void
  ) -> [CleanupDegradation] {
    sync(devices: Dictionary(uniqueKeysWithValues: deviceIDs.map { ($0, "device-\($0)") }), onChange: onChange)
  }
}

private let perDevice = DeviceFormatListenerLifecycle.addresses.count

@Test func deviceFormatListenersFollowTheDeviceListAndRetryRefusedListeners() {
  let calls = ListenerCalls()
  let lifecycle = listenerLifecycle(calls)

  #expect(lifecycle.sync(deviceIDs: [1, 2]) {}.isEmpty)
  #expect(calls.live == [1: perDevice, 2: perDevice])

  // Device 1 unplugged, device 3 plugged in; device 3 refuses the rate
  // listener. It keeps the two it accepted, and the next sync adds only the
  // missing one.
  calls.refuseAdd(device: 3, selector: kAudioDevicePropertyNominalSampleRate)
  #expect(lifecycle.sync(deviceIDs: [2, 3]) {}.count == 1)
  #expect(calls.live == [2: perDevice, 3: perDevice - 1])

  calls.refuseAdd(device: 3, selector: nil)
  #expect(lifecycle.sync(deviceIDs: [2, 3]) {}.isEmpty)
  #expect(calls.live == [2: perDevice, 3: perDevice])
  #expect(calls.adds(on: 3) == perDevice)

  #expect(lifecycle.remove().isEmpty)
  #expect(calls.live.isEmpty)
}

@Test func aListenerWhoseRemovalFailsStaysOwnedReportedAndRetried() {
  let calls = ListenerCalls()
  let lifecycle = listenerLifecycle(calls)
  #expect(lifecycle.sync(deviceIDs: [1, 2]) {}.isEmpty)

  // Device 1 leaves the list; its rate listener will not come off.
  calls.failRemove(device: 1, selector: kAudioDevicePropertyNominalSampleRate, status: -1)
  #expect(lifecycle.sync(deviceIDs: [2]) {}.count == 1)
  #expect(calls.live == [1: 1, 2: perDevice])
  #expect(lifecycle.registrationCount == perDevice + 1)

  // Shutdown reports it and keeps it; a later attempt retries only it.
  #expect(lifecycle.remove().count == 1)
  #expect(calls.live == [1: 1])
  calls.failRemove(device: 1, selector: kAudioDevicePropertyNominalSampleRate, status: noErr)
  #expect(lifecycle.remove().isEmpty)
  #expect(calls.live.isEmpty)
  #expect(lifecycle.registrationCount == 0)
}

@Test func aListenerOnADeviceThatIsAlreadyGoneIsNotReportedOrKept() {
  let calls = ListenerCalls()
  let lifecycle = listenerLifecycle(calls)
  #expect(lifecycle.sync(deviceIDs: [1]) {}.isEmpty)
  calls.failRemove(device: 1, selector: kAudioDevicePropertyDeviceIsAlive, status: kAudioHardwareBadObjectError)
  #expect(lifecycle.sync(deviceIDs: []) {}.isEmpty)
  #expect(lifecycle.registrationCount == 0)
}

@Test func releasingTheListenerOwnerRemovesWhatItStillHolds() {
  let calls = ListenerCalls()
  do {
    let lifecycle = listenerLifecycle(calls)
    #expect(lifecycle.sync(deviceIDs: [1, 2]) {}.isEmpty)
    #expect(calls.live == [1: perDevice, 2: perDevice])
  }
  #expect(calls.live.isEmpty)
}

@Test func releasingTheBackendWithoutShutdownRemovesItsFormatListeners() async {
  let calls = ListenerCalls()
  var backend: WorkspaceAudioControlBackend? = WorkspaceAudioControlBackend(
    testingSnapshot: .empty,
    deviceFormatListenerNativeCalls: DeviceFormatListenerNativeCalls(
      add: { device, address, _ in calls.add(device, address.mSelector) },
      remove: { device, address, _ in calls.remove(device, address.mSelector) }
    )
  )
  await backend?.syncDeviceFormatListenersForTesting(devices: [1: "builtin", 2: "usb-dac"])
  #expect(calls.live == [1: perDevice, 2: perDevice])
  backend = nil
  #expect(calls.live.isEmpty)
}

@Test func aDeviceThatDropsAndReturnsInsideTheDebounceIsStillRebuiltOn() async throws {
  let calls = ListenerCalls()
  let fixture = RouteFixture(apps: [routeTestApp()], deviceFormatListenerNativeCalls: calls.nativeCalls)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.syncDeviceFormatListenersForTesting(devices: [10: "builtin"])

  // The built-in output drops (its listener fires while it is not alive) and
  // comes back with the same format before the debounced pass runs.
  calls.setAlive(false)
  calls.fireAliveChange(on: 10)
  calls.setAlive(true)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))

  #expect(fixture.events.values == ["create app.a #2", "stop #1"])

  // The transition is consumed: the next pass finds nothing to do.
  await backend.revalidateRouteFormatsForTesting(at: .seconds(11))
  #expect(fixture.events.creations == 1)
}

@Test func anAliveEventWhileTheDeviceIsAliveIsNotATransition() async throws {
  let calls = ListenerCalls()
  let fixture = RouteFixture(apps: [routeTestApp()], deviceFormatListenerNativeCalls: calls.nativeCalls)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.syncDeviceFormatListenersForTesting(devices: [10: "builtin"])

  calls.fireAliveChange(on: 10)
  await backend.revalidateRouteFormatsForTesting(at: .seconds(10))
  #expect(fixture.events.creations == 0)
}

@Test func aDeviceThatReturnsAsANewObjectIsListenedToAndCountsAsSeenNotAlive() {
  let calls = ListenerCalls()
  let lifecycle = listenerLifecycle(calls)
  #expect(lifecycle.sync(devices: [10: "builtin"]) {}.isEmpty)

  // Same UID, new object: the old registrations go, the new object gets its
  // own, and the device counts as having dropped.
  #expect(lifecycle.sync(devices: [11: "builtin"]) {}.isEmpty)
  #expect(calls.live == [11: perDevice])
  #expect(lifecycle.takeDevicesSeenNotAlive() == ["builtin"])
}

@Test func anObjectIDReusedForAnotherDeviceGetsThatDevicesOwnListener() {
  let calls = ListenerCalls()
  let lifecycle = listenerLifecycle(calls)
  #expect(lifecycle.sync(devices: [10: "builtin"]) {}.isEmpty)

  // Core Audio reuses object 10 for the USB DAC.
  #expect(lifecycle.sync(devices: [10: "usb-dac"]) {}.isEmpty)
  #expect(calls.live == [10: perDevice])
  #expect(calls.adds(on: 10) == 2 * perDevice)

  // Its callback is the DAC's, not the built-in output's.
  calls.setAlive(false)
  calls.fireAliveChange(on: 10)
  #expect(lifecycle.takeDevicesSeenNotAlive() == ["usb-dac"])
}

@Test func aDeviceListNotificationReconcilesListenersEvenWhenNoUIDChanged() async throws {
  let calls = ListenerCalls()
  let fixture = RouteFixture(apps: [routeTestApp()], deviceFormatListenerNativeCalls: calls.nativeCalls)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.performDeviceChangePassForTesting(changes: [.deviceInventory])
  #expect(calls.live[10] == perDevice)

  // The built-in output resets and is back, as a new object under the same
  // UID, before the pass for its device-list notification runs.
  fixture.inventory.set([11: "builtin", 20: "usb-dac", 30: "headphones"])
  await backend.performDeviceChangePassForTesting(changes: [.deviceInventory])

  #expect(calls.live[10] == nil)
  #expect(calls.live[11] == perDevice)
  // The route built on the old object is rebuilt on the device that came back.
  #expect(fixture.events.values == ["create app.a #2", "stop #1"])
}

@Test func aDeviceMoveIsRecordedOnceWhileItsOldRegistrationWillNotComeOff() {
  let calls = ListenerCalls()
  let lifecycle = listenerLifecycle(calls)
  #expect(lifecycle.sync(devices: [10: "builtin"]) {}.isEmpty)

  // The device comes back as object 11. Its old registrations on 10 will not
  // come off, and 11 refuses new ones for now.
  for address in DeviceFormatListenerLifecycle.addresses {
    calls.failRemove(device: 10, selector: address.mSelector, status: -1)
  }
  calls.refuseAllAdds(on: 11)
  _ = lifecycle.sync(devices: [11: "builtin"]) {}
  #expect(lifecycle.takeDevicesSeenNotAlive() == ["builtin"])

  // The same inventory again is not another move.
  _ = lifecycle.sync(devices: [11: "builtin"]) {}
  _ = lifecycle.sync(devices: [11: "builtin"]) {}
  #expect(lifecycle.takeDevicesSeenNotAlive().isEmpty)
}

@Test func unchangedInventoryWithAStuckListenerDoesNotRebuildRoutesAgain() async throws {
  let calls = ListenerCalls()
  let fixture = RouteFixture(apps: [routeTestApp()], deviceFormatListenerNativeCalls: calls.nativeCalls)
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  await backend.performDeviceChangePassForTesting(changes: [.deviceInventory])

  // The built-in output returns as object 11; object 10's listeners will not
  // come off and 11 will not take new ones yet. The move rebuilds once.
  for address in DeviceFormatListenerLifecycle.addresses {
    calls.failRemove(device: 10, selector: address.mSelector, status: -1)
  }
  calls.refuseAllAdds(on: 11)
  fixture.inventory.set([11: "builtin", 20: "usb-dac", 30: "headphones"])
  await backend.performDeviceChangePassForTesting(changes: [.deviceInventory])
  #expect(fixture.events.creations == 1)

  // Each rebuild raises another device-list notification. With nothing
  // changed outside Waves, those passes rebuild nothing.
  for _ in 0..<3 {
    await backend.performDeviceChangePassForTesting(changes: [.deviceInventory])
  }
  #expect(fixture.events.creations == 1)
}

@Test func releasingTheWakeObserverUnregistersIt() {
  let center = NotificationCenter()
  let wakes = ListenerCalls()
  var token: WakeObserverToken? = WakeObserverToken(center: center) { _ = wakes.add(1, 0) }
  center.post(name: NSWorkspace.didWakeNotification, object: nil)
  #expect(wakes.live == [1: 1])
  _ = token
  token = nil
  center.post(name: NSWorkspace.didWakeNotification, object: nil)
  #expect(wakes.live == [1: 1])
}

private final class ListenerCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [AudioObjectID: Int] = [:]
  private var addCounts: [AudioObjectID: Int] = [:]
  private var refusedAdd: (AudioObjectID, AudioObjectPropertySelector)?
  private var refusedAllAdds: Set<AudioObjectID> = []
  private var failedRemoves: [String: OSStatus] = [:]
  private var listeners: [AudioObjectID: RouterObservationListenerBlockReference] = [:]
  private var alive = true

  var nativeCalls: DeviceFormatListenerNativeCalls {
    DeviceFormatListenerNativeCalls(
      add: { device, address, listener in
        self.lock.withLock { self.listeners[device] = listener }
        return self.add(device, address.mSelector)
      },
      remove: { device, address, _ in self.remove(device, address.mSelector) },
      isAlive: { _ in self.lock.withLock { self.alive } }
    )
  }

  func setAlive(_ value: Bool) { lock.withLock { alive = value } }

  /// Delivers a device-is-alive change the way Core Audio's listener would.
  func fireAliveChange(on device: AudioObjectID) {
    guard let listener = lock.withLock({ listeners[device] }) else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    listener.block(1, &address)
  }

  var live: [AudioObjectID: Int] { lock.withLock { counts.filter { $0.value > 0 } } }

  func adds(on device: AudioObjectID) -> Int { lock.withLock { addCounts[device] ?? 0 } }

  func refuseAdd(device: AudioObjectID, selector: AudioObjectPropertySelector?) {
    lock.withLock { refusedAdd = selector.map { (device, $0) } }
  }

  func refuseAllAdds(on device: AudioObjectID) { lock.withLock { _ = refusedAllAdds.insert(device) } }

  func failRemove(device: AudioObjectID, selector: AudioObjectPropertySelector, status: OSStatus) {
    lock.withLock { failedRemoves["\(device)/\(selector)"] = status == noErr ? nil : status }
  }

  func add(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> OSStatus {
    lock.withLock {
      if let refusedAdd, refusedAdd.0 == device, refusedAdd.1 == selector { return -1 }
      if refusedAllAdds.contains(device) { return -1 }
      counts[device, default: 0] += 1
      addCounts[device, default: 0] += 1
      return noErr
    }
  }

  func remove(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> OSStatus {
    lock.withLock {
      if let status = failedRemoves["\(device)/\(selector)"] {
        // A device that is already gone took the registration with it.
        if status == kAudioHardwareBadObjectError { counts[device, default: 0] -= 1 }
        return status
      }
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

/// Holds controller-creation retries until the test releases them, in the
/// order they paused.
actor RetryGate {
  private var paused: [CheckedContinuation<Void, Never>] = []
  private var pauseWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var isReleased = false

  func pause() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      paused.append(continuation)
      let ready = pauseWaiters.filter { $0.count <= paused.count }
      pauseWaiters.removeAll { $0.count <= paused.count }
      ready.forEach { $0.continuation.resume() }
    }
  }

  /// Returns once `count` retries are paused.
  func waitUntilPaused(count: Int = 1) async {
    guard paused.count < count else { return }
    await withCheckedContinuation { pauseWaiters.append((count, $0)) }
  }

  /// Resumes the retry that paused first.
  func releaseFirst() {
    guard !paused.isEmpty else { return }
    paused.removeFirst().resume()
  }

  /// Resumes every paused retry and lets later ones through.
  func release() {
    isReleased = true
    paused.forEach { $0.resume() }
    paused.removeAll()
  }
}

/// Holds one snapshot rebuild in application capture, its first
/// suspension, until the test releases it.
actor DiscoveryGate {
  private var armed = false
  private var paused: CheckedContinuation<Void, Never>?
  private var waiter: CheckedContinuation<Void, Never>?

  /// The next capture pauses; later ones run straight through.
  func arm() { armed = true }

  func pause() async {
    guard armed else { return }
    armed = false
    await withCheckedContinuation { continuation in
      paused = continuation
      waiter?.resume()
      waiter = nil
    }
  }

  func waitUntilPaused() async {
    guard paused == nil else { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func release() {
    paused?.resume()
    paused = nil
  }
}

func routeTestApp(
  id: String = "app.a",
  volume: Float = 0.5,
  routingState: RoutingState = .managed,
  targetDeviceUID: String? = nil,
  bundleID: String? = nil
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: id,
    pid: 900,
    bundleID: bundleID ?? "com.example.\(id)",
    displayName: "App \(id)",
    category: .media,
    isActive: true,
    desiredVolume: volume,
    appliedVolume: routingState == .managed ? volume : nil,
    routingState: routingState,
    compatibility: .supported,
    targetDeviceUID: targetDeviceUID,
    runtimeIdentity: routeTestIdentity(id)
  )
}

/// A stable identity per test app, so the backend's real discovery merge
/// recognizes the app as still running across snapshot rebuilds.
func routeTestIdentity(_ id: String) -> AppRuntimeIdentity {
  AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(pid: 900, startTimeSeconds: 100, startTimeMicroseconds: 0),
    executablePath: "/Applications/\(id).app/Contents/MacOS/\(id)",
    outerBundlePath: "/Applications/\(id).app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.\(id)",
      teamIdentifier: nil,
      designatedRequirement: "identifier \"com.example.\(id)\"",
      codeDirectoryHash: Data(id.utf8)
    )
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

/// Records, in order, every controller creation, every renderer stop, and
/// every moment a controller's tap stops muting its app (the instant the app
/// would be heard at its own, unattenuated level). `pumpRenders` plays one
/// buffer through every running controller, the way their IO procs would,
/// and records any moment two renderers of one app are heard together.
final class RouteEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private var serial = 0
  private var failuresRemaining = 0
  private var stopFailuresRemaining = 0
  private var muteReleaseFailuresRemaining = 0
  private var destroyFailuresRemaining: [CleanupStage: Int] = [:]
  /// Serials whose tap still mutes its app's own output: from creation until
  /// a mute release or a tap destroy succeeds.
  private var muting: Set<Int> = []
  private var lastPeaks: [Int: Float] = [:]
  private var sampledAtRelease: [String] = []
  /// Set by a test to record `hearing` at the instant any tap stops muting
  /// its app, in `heardAtRelease`.
  var samplesHearingAtRelease: Bool {
    get { lock.withLock { samplingAtRelease } }
    set { lock.withLock { samplingAtRelease = newValue } }
  }
  private var samplingAtRelease = false
  var heardAtRelease: [String] { lock.withLock { sampledAtRelease } }

  func sampleHearingAtRelease(_ appID: String) {
    guard samplesHearingAtRelease else { return }
    let heard = hearing(appID)
    lock.withLock { sampledAtRelease.append(heard) }
  }
  private var dead: Set<Int> = []
  private var created: [Int: (appID: String, controller: PerAppTapController)] = [:]

  var values: [String] { lock.withLock { recorded } }
  var creations: Int { lock.withLock { recorded.count { $0.hasPrefix("create ") } } }
  var overlaps: [String] { lock.withLock { recorded.filter { $0.hasPrefix("overlap ") } } }

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

  func failNextStops(_ count: Int) { lock.withLock { stopFailuresRemaining = count } }

  func consumeStopFailure() -> Bool {
    lock.withLock {
      guard stopFailuresRemaining > 0 else { return false }
      stopFailuresRemaining -= 1
      return true
    }
  }

  func failNextMuteReleases(_ count: Int) { lock.withLock { muteReleaseFailuresRemaining = count } }

  func consumeMuteReleaseFailure() -> Bool {
    lock.withLock {
      guard muteReleaseFailuresRemaining > 0 else { return false }
      muteReleaseFailuresRemaining -= 1
      return true
    }
  }

  /// The next `count` destroys of `stage` (IO proc, aggregate device or
  /// process tap) fail.
  func failNextDestroys(_ stage: CleanupStage, _ count: Int) {
    lock.withLock { destroyFailuresRemaining[stage] = count }
  }

  func consumeDestroyFailure(_ stage: CleanupStage) -> Bool {
    lock.withLock {
      guard let remaining = destroyFailuresRemaining[stage], remaining > 0 else { return false }
      destroyFailuresRemaining[stage] = remaining - 1
      return true
    }
  }

  func tapCreated(serial: Int) { lock.withLock { _ = muting.insert(serial) } }
  func tapReleased(serial: Int) { lock.withLock { _ = muting.remove(serial) } }

  /// Whether `appID` plays through its own output: no tap of any of its
  /// controllers still mutes it.
  func ownOutputIsAudible(_ appID: String) -> Bool {
    lock.withLock { !muting.contains { created[$0]?.appID == appID } }
  }

  /// What the user hears of `appID` right now, after one buffer through
  /// every running renderer: "own output", "waves #n", "silent", or
  /// "own output + waves #n" (louder than set: never acceptable).
  func hearing(_ appID: String) -> String {
    let renderers = pumpRenders().filter { controllerAppID(serial: $0) == appID }
    var heard: [String] = []
    if ownOutputIsAudible(appID) { heard.append("own output") }
    heard += renderers.map { "waves #\($0)" }
    return heard.isEmpty ? "silent" : heard.joined(separator: " + ")
  }

  /// The loudest sample serial `serial` produced in the last `pumpRenders`.
  func lastPeak(serial: Int) -> Float? { lock.withLock { lastPeaks[serial] } }

  private func controllerAppID(serial: Int) -> String? { lock.withLock { created[serial]?.appID } }

  /// The last thing that happened to a controller's tap mute: "audible"
  /// (released, the app plays at its own level) or "muted" (re-muted).
  func lastTapMuteEvent(serial: Int) -> String? {
    lock.withLock {
      recorded.last { $0 == "audible #\(serial)" || $0 == "muted #\(serial)" }
    }
  }

  /// Models an aggregate that stopped rendering (its device reset under it):
  /// its IO proc is never called again.
  func stopRendering(serial: Int) { lock.withLock { _ = dead.insert(serial) } }

  func reset() { lock.withLock { recorded.removeAll() } }

  func remember(_ controller: PerAppTapController, serial: Int, appID: String) {
    lock.withLock { created[serial] = (appID, controller) }
  }

  func controller(serial: Int) -> PerAppTapController? {
    lock.withLock { created[serial]?.controller }
  }

  /// Plays one buffer through every controller that is still rendering and
  /// returns the serials that produced sound.
  @discardableResult
  func pumpRenders() -> [Int] {
    let running = lock.withLock { created.filter { $0.value.controller.isActive && !dead.contains($0.key) } }
    var heardByApp: [String: [Int]] = [:]
    for (serial, entry) in running.sorted(by: { $0.key < $1.key }) {
      let level = peak(of: entry.controller)
      lock.withLock { lastPeaks[serial] = level }
      guard level > 0 else { continue }
      heardByApp[entry.appID, default: []].append(serial)
    }
    for (appID, serials) in heardByApp.sorted(by: { $0.key < $1.key }) where serials.count > 1 {
      record("overlap \(appID) " + serials.map { "#\($0)" }.joined(separator: "+"))
    }
    return heardByApp.values.flatMap { $0 }.sorted()
  }

  func peak(of controller: PerAppTapController) -> Float {
    var input = [Float](repeating: 0.5, count: 512 * 2)
    var output = [Float](repeating: 0, count: input.count)
    input.withUnsafeMutableBytes { inputBytes in
      output.withUnsafeMutableBytes { outputBytes in
        var inputList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(inputBytes.count),
            mData: inputBytes.baseAddress
          )
        )
        var outputList = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(outputBytes.count),
            mData: outputBytes.baseAddress
          )
        )
        controller.renderForTesting(input: &inputList, output: &outputList)
      }
    }
    return output.map(abs).max() ?? 0
  }
}

/// The fake output devices' current formats. Default-following routes play
/// on `defaultUID`; pinned routes on their target.
final class DeviceFormatState: @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [String: DeviceFormatObservation] = [
    "builtin": .alive(DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 2)),
    "usb-dac": .alive(DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 2)),
    "headphones": .alive(DeviceFormatSignature(sampleRate: 48_000, outputChannelCount: 2)),
  ]
  private var currentDefaultUID = "builtin"

  var defaultUID: String {
    get { lock.withLock { currentDefaultUID } }
    set { lock.withLock { currentDefaultUID = newValue } }
  }

  func set(_ uid: String, _ observation: DeviceFormatObservation) {
    lock.withLock { observations[uid] = observation }
  }

  func observation(_ uid: String) -> DeviceFormatObservation {
    lock.withLock { observations[uid] ?? .missing }
  }

  /// Where `app`'s route should play: its pinned target, or the default.
  func outputUID(for app: AudioApp) -> String {
    app.targetDeviceUID ?? defaultUID
  }
}

/// The fake Core Audio device list: output devices by object ID.
final class DeviceInventory: @unchecked Sendable {
  private let lock = NSLock()
  private var devices: [AudioObjectID: String] = [10: "builtin", 20: "usb-dac", 30: "headphones"]

  var current: [AudioObjectID: String] { lock.withLock { devices } }
  func set(_ devices: [AudioObjectID: String]) { lock.withLock { self.devices = devices } }
}

/// A value a fixture's injected providers read, changed by the test.
final class TestBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

final class RouteFixture: @unchecked Sendable {
  let backend: WorkspaceAudioControlBackend
  let events = RouteEvents()
  let devices = DeviceFormatState()
  let inventory = DeviceInventory()
  /// The rebuild budget's clock.
  let budgetClock = TestBox<Duration>(.seconds(1))
  /// Whether the apps' processes are producing output.
  let playing = TestBox(true)
  /// PIDs discovery sees as audible.
  let audiblePIDs = TestBox<Set<pid_t>>([])
  /// Whether a verified audio router is mixing every app's output.
  let routerRunning = TestBox(false)
  /// The running applications discovery captures.
  let captured = TestBox<[AppRuntimeDiscovery.CapturedApplication]>([])
  /// Whether a process lifetime is still running; nil asks the real system.
  let lifetimeLiveness = TestBox<Bool?>(nil)

  /// The app quits and opens again: a new process, under the same bundle,
  /// name and therefore the same runtime and logical IDs.
  func relaunch(bundleID: String) {
    captured.value = captured.value.map { application in
      guard application.bundleID == bundleID, let identity = application.runtimeIdentity else { return application }
      return AppRuntimeDiscovery.CapturedApplication(
        pid: 901,
        bundleID: application.bundleID,
        localizedName: application.localizedName,
        bundlePath: application.bundlePath,
        activationPolicy: application.activationPolicy,
        isActive: application.isActive,
        iconTIFFData: nil,
        runtimeIdentity: AppRuntimeIdentity(
          lifetime: AppProcessLifetimeIdentity(pid: 901, startTimeSeconds: 200, startTimeMicroseconds: 0),
          executablePath: identity.executablePath,
          outerBundlePath: identity.outerBundlePath,
          signingIdentity: identity.signingIdentity
        )
      )
    }
  }

  /// A second, unrelated app claims the same bundle ID and name, so
  /// discovery cannot tell which one the row means.
  func addImpostor(bundleID: String) {
    guard let original = captured.value.first(where: { $0.bundleID == bundleID }) else { return }
    let impostor = routeTestIdentity("impostor")
    captured.value.append(
      AppRuntimeDiscovery.CapturedApplication(
        pid: 902,
        bundleID: bundleID,
        localizedName: original.localizedName,
        bundlePath: impostor.outerBundlePath,
        activationPolicy: original.activationPolicy,
        isActive: false,
        iconTIFFData: nil,
        runtimeIdentity: impostor
      )
    )
  }

  /// - Parameter rendersDuringHandoff: whether outgoing renderers keep
  ///   rendering while a handoff waits for them to fade out. False models a
  ///   renderer whose device has stopped.
  /// - Parameter discoveryPause: runs inside every snapshot rebuild's
  ///   application capture, the rebuild's first suspension, so a test can
  ///   land newer work while discovery is in flight.
  /// - Parameter foreground: captures the apps as regular, foreground apps,
  ///   so discovery reports them as fresh candidates (the merge path ordinary
  ///   apps take) rather than keeping the backend's rows.
  init(
    apps: [AudioApp],
    retryPause: WorkspaceAudioControlBackend.ControllerRetryPause? = nil,
    rendersDuringHandoff: Bool = true,
    deviceFormatListenerNativeCalls: DeviceFormatListenerNativeCalls? = nil,
    discoveryPause: (@Sendable () async -> Void)? = nil,
    foreground: Bool = false
  ) {
    let events = self.events
    let devices = self.devices
    let inventory = self.inventory
    let budgetClock = self.budgetClock
    let playing = self.playing
    let audiblePIDs = self.audiblePIDs
    let routerRunning = self.routerRunning
    let lifetimeLiveness = self.lifetimeLiveness
    // Every test app is still running. Captured as background-only processes
    // so discovery keeps the backend's own rows rather than inventing new ones.
    let captured = self.captured
    captured.value = apps.map {
      AppRuntimeDiscovery.CapturedApplication(
        pid: $0.pid ?? 900,
        bundleID: $0.bundleID,
        localizedName: $0.displayName,
        bundlePath: $0.runtimeIdentity?.outerBundlePath,
        activationPolicy: foreground ? .regular : .prohibited,
        isActive: foreground,
        iconTIFFData: nil,
        runtimeIdentity: $0.runtimeIdentity
      )
    }
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
      // A pass captures this once, before it suspends, as production does.
      verifiedRouterActivityProvider: {
        VerifiedRouterActivitySnapshot(
          routers: routerRunning.value
            ? [VerifiedRouter(descriptor: .waveLink3_2_2, pid: 4_242, processObjectID: 77)] : [],
          processObjects: [],
          routerBundleIdentifiers: []
        )
      },
      routerObservationNativeCalls: RouterObservationListenerNativeCalls(
        add: { _, _ in noErr },
        remove: { _, _ in noErr }
      ),
      controllerFactory: { app, processObjectIDs, _, _, _ in
        if events.consumeFailure() {
          events.record("fail \(app.id)")
          throw BackendError.managedRouteUnavailable("Injected creation failure")
        }
        let serial = events.nextSerial()
        events.record("create \(app.id) #\(serial)")
        events.tapCreated(serial: serial)
        let controller = try PerAppTapController.testingController(
          appID: app.id,
          logicalID: app.logicalID,
          targetProcessObjectIDs: processObjectIDs,
          volume: app.desiredVolume,
          muted: app.isMuted,
          teardownNativeCalls: PerAppTapControllerTeardownNativeCalls(
            makeOriginalAudioAudible: {
              guard !events.consumeMuteReleaseFailure() else {
                events.record("release failed #\(serial)")
                return -1
              }
              events.record("audible #\(serial)")
              events.tapReleased(serial: serial)
              events.sampleHearingAtRelease(app.id)
              return noErr
            },
            stopIOProc: {
              guard !events.consumeStopFailure() else {
                events.record("stop failed #\(serial)")
                return -1
              }
              events.record("stop #\(serial)")
              return noErr
            },
            destroyIOProc: { _, _ in events.consumeDestroyFailure(.ioProcDestroy) ? -1 : noErr },
            destroyAggregateDevice: { _ in events.consumeDestroyFailure(.aggregateDeviceDestroy) ? -1 : noErr },
            destroyProcessTap: { _ in
              guard !events.consumeDestroyFailure(.processTapDestroy) else {
                events.record("destroy tap failed #\(serial)")
                return -1
              }
              // A destroyed tap no longer mutes anything.
              events.tapReleased(serial: serial)
              events.sampleHearingAtRelease(app.id)
              return noErr
            }
          )
        )
        events.remember(controller, serial: serial, appID: app.id)
        // The new IO proc starts rendering as soon as it is created, while
        // every other renderer keeps going.
        events.pumpRenders()
        return controller
      },
      processObjectIDResolver: { _ in [1] },
      processObjectLivenessProvider: { _ in playing.value },
      captureAuthorizationProbe: { .authorized },
      applicationCaptureProvider: {
        await discoveryPause?()
        return AppRuntimeDiscovery.Capture(applications: captured.value)
      },
      processLifetimeLiveness: { lifetimeLiveness.value ?? RuntimeProcessIdentity.mayStillBeRunning($0) },
      routeBudgetClock: { budgetClock.value },
      controllerRetryPause: retryPause ?? { _ in },
      handoffSilencePause: { if rendersDuringHandoff { events.pumpRenders() } },
      outputDeviceUIDProvider: { devices.outputUID(for: $0) },
      deviceInventoryProvider: { inventory.current },
      deviceFormatObservationProvider: { devices.observation($0) },
      audibleProcessIndexProvider: { .init(pids: audiblePIDs.value) },
      deviceFormatListenerNativeCalls: deviceFormatListenerNativeCalls
        ?? DeviceFormatListenerNativeCalls(add: { _, _, _ in noErr }, remove: { _, _, _ in noErr })
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
