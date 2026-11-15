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

@Test func aFormatRebuildRefusedByTheRebuildCeilingReleasesTheRoute() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(id: "app.a")])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Automatic rebuilds have spent the budget.
  for cycle in 0..<RouteRebuildBudget.minimumCapacity {
    await backend.flagGeometryMismatchForTesting(runtimeID: "app.a")
    await backend.updateAudioLevels(at: .seconds(10 + cycle * 2))
  }
  let creations = fixture.events.creations
  let incumbent = creations + 1
  fixture.events.stopRendering(serial: incumbent)
  fixture.devices.set("builtin", .alive(rate96))
  await backend.revalidateRouteFormatsForTesting(at: .seconds(40))

  // Refused, so the route that no longer works is released, not kept.
  #expect(fixture.events.creations == creations)
  #expect(fixture.events.lastTapMuteEvent(serial: incumbent) == "audible #\(incumbent)")
  #expect(await backend.lifecycleDebugSnapshot().liveControllers == 0)
  let app = try #require(await backend.currentSnapshot().apps.first)
  #expect(app.routingState == .error)
  #expect(app.notes?.contains("paused automatic audio route rebuilds") == true)
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

@Test func aRetireeWhoseTeardownIsExhaustedIsReleasedOnceItsSuccessorGoes() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // #1 is retired by a move and will not stop. Every teardown retry fails
  // while #2 plays, until the retry allowance is spent.
  fixture.events.failNextStops(1_000)
  let move = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 10, targetDeviceUID: "usb-dac")
  )
  #expect(move.outcome == .applied)
  for pass in 0..<WorkspaceAudioControlBackend.maxOrphanDisposeRetries {
    await maintenancePass(fixture, from: 10 + pass * 20)
  }
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == nil)

  // The user excludes the app: #2 goes, fail open. #1 is silent and its tap
  // still mutes the app, so the next pass must release it.
  fixture.events.failNextStops(0)
  let exclusion = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.5, generation: 11, isExcluded: true)
  )
  #expect(exclusion.outcome == .excluded)
  await maintenancePass(fixture, from: 200)
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == "audible #1")
  #expect(fixture.events.pumpRenders().isEmpty)

  // The exhaustion row described what was true at the time.
  let result = await backend.shutdownWithResult()
  let row = try #require(result.degradations.first { $0.detail?.contains("attempts") == true })
  #expect(row.detail?.contains("stays muted while the app's current route plays") == true)
  #expect(row.detail?.contains("fail-open") != true)
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

  // Its stop fails again, but its renderer is silent: re-muting its tap
  // would leave the app silent, so the release stands.
  #expect(fixture.events.lastTapMuteEvent(serial: 1) == "audible #1")
}

@Test func failedTeardownsCannotAccumulateWithoutBound() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextStops(1_000)

  // Each output change parks the route it replaced.
  let outputs = ["usb-dac", "headphones", "builtin"]
  var outcomes: [AppIntentApplyOutcome] = []
  for (offset, output) in outputs.enumerated() {
    let result = await backend.applyAppIntent(
      routeIntent(appID: "app.a", volume: 0.5, generation: UInt64(10 + offset), targetDeviceUID: output)
    )
    outcomes.append(result.outcome)
  }

  // Two parked; the third change is refused and the current route keeps
  // playing the app.
  #expect(outcomes == [.applied, .applied, .failed])
  let lifecycle = await backend.lifecycleDebugSnapshot()
  #expect(lifecycle.orphanedControllers == WorkspaceAudioControlBackend.maxParkedControllersPerApp)
  #expect(lifecycle.liveControllers == 1)
  #expect(fixture.events.creations == 2)
  #expect(fixture.events.pumpRenders() == [3])
}

@Test func aParkedRendererThatStillPlaysIsSilencedBeforeANewRouteIsHeard() async throws {
  let fixture = RouteFixture(apps: [routeTestApp()])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend

  // Excluding the app releases #1 fail open, but its tap will not release,
  // so its renderer keeps carrying the app (that is the fail-open path).
  fixture.events.failNextMuteReleases(1)
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 10, isExcluded: true))
  #expect(fixture.events.pumpRenders() == [1])

  // The user manages the app again. Only the new route may be heard.
  let managed = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.5, generation: 11))
  #expect(managed.outcome == .applied)
  #expect(fixture.events.pumpRenders() == [2])
  #expect(fixture.events.overlaps.isEmpty)
}

@Test func aParkedRendererWhoseTapWillNotReleaseCarriesTheAppAgainWhenItsRouteGoes() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.4)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  // #1 is retired by a move and will not stop; it is silent.
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.4, generation: 10, targetDeviceUID: "usb-dac")
  )
  // #2's route goes (the user excludes the app) and #1's tap will never
  // release. The app must not be left silent: #1 carries it again, at the
  // level the user set.
  fixture.events.failNextStops(0)
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.4, generation: 11, isExcluded: true))
  fixture.events.failNextMuteReleases(1_000)
  fixture.events.failNextStops(1_000)
  await maintenancePass(fixture, from: 10)

  #expect(fixture.events.pumpRenders() == [1])
  let parked = try #require(fixture.events.controller(serial: 1))
  #expect(parked.settledGainsForTesting().volume == 0.4)
}

@Test func twoParkedRenderersNeverCarryTheSameAppTogether() async throws {
  let fixture = RouteFixture(apps: [routeTestApp(volume: 0.4)])
  try await fixture.installInitialRoutes()
  let backend = fixture.backend
  fixture.events.failNextStops(1_000)
  _ = await backend.applyAppIntent(
    routeIntent(appID: "app.a", volume: 0.4, generation: 10, targetDeviceUID: "usb-dac")
  )
  // Excluding the app parks #2 too, and neither tap will release: #2 keeps
  // carrying the app, so silent #1 must not join it.
  fixture.events.failNextMuteReleases(1_000)
  _ = await backend.applyAppIntent(routeIntent(appID: "app.a", volume: 0.4, generation: 11, isExcluded: true))
  await maintenancePass(fixture, from: 10)

  #expect(fixture.events.pumpRenders() == [2])
  #expect(fixture.events.overlaps.isEmpty)
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
      },
      restoreTapMuting: { noErr }
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
      },
      restoreTapMuting: { noErr }
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
      availableDeviceUIDs: ["builtin", "usb-dac"]
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

  func failRemove(device: AudioObjectID, selector: AudioObjectPropertySelector, status: OSStatus) {
    lock.withLock { failedRemoves["\(device)/\(selector)"] = status == noErr ? nil : status }
  }

  func add(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> OSStatus {
    lock.withLock {
      if let refusedAdd, refusedAdd.0 == device, refusedAdd.1 == selector { return -1 }
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
    for (serial, entry) in running.sorted(by: { $0.key < $1.key }) where peak(of: entry.controller) > 0 {
      heardByApp[entry.appID, default: []].append(serial)
    }
    for (appID, serials) in heardByApp.sorted(by: { $0.key < $1.key }) where serials.count > 1 {
      record("overlap \(appID) " + serials.map { "#\($0)" }.joined(separator: "+"))
    }
    return heardByApp.values.flatMap { $0 }.sorted()
  }

  private func peak(of controller: PerAppTapController) -> Float {
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

final class RouteFixture: @unchecked Sendable {
  let backend: WorkspaceAudioControlBackend
  let events = RouteEvents()
  let devices = DeviceFormatState()
  let inventory = DeviceInventory()

  /// - Parameter rendersDuringHandoff: whether outgoing renderers keep
  ///   rendering while a handoff waits for them to fade out. False models a
  ///   renderer whose device has stopped.
  /// - Parameter discoveryPause: runs inside every snapshot rebuild's
  ///   application capture, the rebuild's first suspension, so a test can
  ///   land newer work while discovery is in flight.
  init(
    apps: [AudioApp],
    retryPause: WorkspaceAudioControlBackend.ControllerRetryPause? = nil,
    rendersDuringHandoff: Bool = true,
    deviceFormatListenerNativeCalls: DeviceFormatListenerNativeCalls? = nil,
    discoveryPause: (@Sendable () async -> Void)? = nil
  ) {
    let events = self.events
    let devices = self.devices
    let inventory = self.inventory
    // Every test app is still running. Captured as background-only processes
    // so discovery keeps the backend's own rows rather than inventing new ones.
    let capture = AppRuntimeDiscovery.Capture(
      applications: apps.map {
        AppRuntimeDiscovery.CapturedApplication(
          pid: $0.pid ?? 900,
          bundleID: $0.bundleID,
          localizedName: $0.displayName,
          bundlePath: $0.runtimeIdentity?.outerBundlePath,
          activationPolicy: .prohibited,
          isActive: false,
          iconTIFFData: nil,
          runtimeIdentity: $0.runtimeIdentity
        )
      }
    )
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
        VerifiedRouterActivitySnapshot(routers: [], processObjects: [], routerBundleIdentifiers: [])
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
            restoreTapMuting: {
              events.record("muted #\(serial)")
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
      processObjectLivenessProvider: { _ in true },
      captureAuthorizationProbe: { .authorized },
      applicationCaptureProvider: {
        await discoveryPause?()
        return capture
      },
      routeBudgetClock: { .seconds(1) },
      controllerRetryPause: retryPause ?? { _ in },
      handoffSilencePause: { if rendersDuringHandoff { events.pumpRenders() } },
      outputDeviceUIDProvider: { devices.outputUID(for: $0) },
      deviceInventoryProvider: { inventory.current },
      deviceFormatObservationProvider: { devices.observation($0) },
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
