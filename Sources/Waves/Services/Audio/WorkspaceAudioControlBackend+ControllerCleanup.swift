import AudioToolbox
import Foundation
import OSLog
import WavesAudioCore

// MARK: - Controller disposal and cleanup accounting
//
// Every release names its kind (`PerAppTapController.DisposalKind`):
// retirement beside a successor, a forced release when Waves must not render
// the app at all, or a managed release, which leaves the app audible one way
// or the other. A controller whose native teardown fails is parked: silent
// for good, and retried on every maintenance pass until it is gone.

extension WorkspaceAudioControlBackend {
  func releaseControllers(
    forRuntimeIdentity runtimeIdentity: AppRuntimeIdentity,
    clearMuteState: Bool = false
  ) async {
    guard !isShuttingDown else { return }
    var targetIDs = snapshot.apps.filter { app in
      app.runtimeIdentity == runtimeIdentity
    }.map(\.id)
    // A route whose row is gone is found by the process it was built for.
    targetIDs += controllers.filter {
      $0.value.ownerProcessLifetime == runtimeIdentity.lifetime && !targetIDs.contains($0.key)
    }.map(\.key)

    guard !targetIDs.isEmpty else { return }

    for id in targetIDs {
      // The process is gone: nothing may carry it, and nothing can. A repair
      // recorded for it ends with it.
      if let logicalID = snapshot.apps.first(where: { $0.id == id })?.logicalID {
        failOpenReleases.removeValue(forKey: logicalID)
      }
      releaseInstalledController(runtimeID: id, kind: .forcedRelease)
      controllerGenerationByRuntimeID.removeValue(forKey: id)
      staleRouteTicks.removeValue(forKey: id)
      lastRenderTickByAppID.removeValue(forKey: id)
    }

    for index in snapshot.apps.indices where targetIDs.contains(snapshot.apps[index].id) {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].isActive = false
      snapshot.apps[index].appliedVolume = nil
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
      // Only the EXCLUSION path clears mute, so a later whole-session pull
      // (buildSnapshot carries previous.isMuted forward) does not resurrect a
      // mute the user cleared by excluding the app, keeping the backend snapshot
      // in agreement with the store (which clears mute + sets muteSource = .user
      // on exclusion). Plain termination must NOT clear it.
      if clearMuteState {
        snapshot.apps[index].isMuted = false
        snapshot.apps[index].muteSource = .user
      }
    }
    publishRouteHolds()
  }

  /// Releases every installed controller whose app is not in `appIDs`, as a
  /// managed release. One that is still routing stays installed.
  func disposeControllers(keeping appIDs: Set<String>) {
    let stale = Set(controllers.keys).subtracting(appIDs).sorted()
    for appID in stale {
      releaseRoute(runtimeID: appID)
    }
  }

  /// Releases every installed controller whose app discovery no longer
  /// lists. One whose process is confirmed gone is force-released: nothing
  /// can carry it. Otherwise discovery may merely have missed the app: a
  /// managed release, and a route still routing keeps its last row
  /// (`previous`) in `apps`, so the user can still reach it and Waves still
  /// observes it, until its release completes.
  func releaseRoutesMissing(from apps: inout [AudioApp], previous: [AudioApp]) {
    for runtimeID in Set(controllers.keys).subtracting(apps.map(\.id)).sorted() {
      guard let controller = controllers[runtimeID] else { continue }
      var lifetimes = controller.targetProcessFamily.processLifetimeIdentities
      if let owner = controller.ownerProcessLifetime { lifetimes.insert(owner) }
      guard var row = previous.first(where: { $0.id == runtimeID }),
        lifetimes.isEmpty || lifetimes.contains(where: processLifetimeLiveness)
      else {
        releaseRoute(runtimeID: runtimeID, kind: .forcedRelease)
        continue
      }
      guard releaseRoute(runtimeID: runtimeID) == .stillRouting else { continue }
      row.isActive = false
      row.isProducingOutput = false
      apps.append(row)
    }
  }

  /// What became of an app's installed route when Waves let it go.
  enum RouteReleaseOutcome: Equatable {
    /// No controller of Waves's carries the app any more.
    case released
    /// A managed release could not hand the app back; its controller is
    /// still installed and still plays it at the level the user set.
    case stillRouting
  }

  /// Takes down `runtimeID`'s installed controller, if any, as `kind`
  /// describes (`PerAppTapController.DisposalKind`), and parks it if its
  /// teardown did not finish. A controller that is still routing stays
  /// installed, and its row says why (`unreleasedRoutes`).
  @discardableResult
  func releaseInstalledController(
    runtimeID: String,
    kind: PerAppTapController.DisposalKind,
    reason: String? = nil
  ) -> RouteReleaseOutcome {
    guard let controller = controllers[runtimeID] else {
      appLostItsRoute(runtimeID)
      return .released
    }
    // A route that cannot carry the app is no audible fallback: release it
    // as Waves would an app it must not render, and say so if that fails.
    let kind = kind == .managedRelease && isKnownUnableToRender(runtimeID) ? .forcedRelease : kind
    // A managed release that failed waits for its next attempt; the route
    // keeps playing the app meanwhile, and nothing waits on its queue.
    let failed = unreleasedRoutes[runtimeID].flatMap { $0.controller == ObjectIdentifier(controller) ? $0 : nil }
    if kind == .managedRelease, let failed, routeBudgetClock() < failed.nextAttemptAt {
      return .stillRouting
    }
    let result = controller.dispose(kind)
    retainCleanupDegradations(result.degradations)
    if result.outcome == .stillRouting {
      let name = snapshot.apps.first { $0.id == runtimeID }?.displayName ?? controller.appName
      let interval = max(
        UnreleasedRoute.firstRetryInterval,
        min((failed?.retryInterval ?? .zero) * 2, UnreleasedRoute.maximumRetryInterval)
      )
      unreleasedRoutes[runtimeID] = UnreleasedRoute(
        controller: ObjectIdentifier(controller),
        note: Self.stillRoutingNote(appName: name, reason: reason),
        nextAttemptAt: routeBudgetClock() + interval,
        retryInterval: interval
      )
      applyStickyRouteNotes(to: &snapshot.apps)
      return .stillRouting
    }
    controllers.removeValue(forKey: runtimeID)
    unreleasedRoutes.removeValue(forKey: runtimeID)
    pendingRouteRepairs.removeValue(forKey: runtimeID)
    park(controller)
    appLostItsRoute(runtimeID)
    return .released
  }

  /// Whether `runtimeID`'s installed route is known to be unable to carry
  /// its app: it stopped rendering while the app plays, its callback
  /// geometry is unusable, or its output device is gone. (A renderer that
  /// is not running at all is caught by the controller itself.)
  func isKnownUnableToRender(_ runtimeID: String) -> Bool {
    if pendingRepair(for: runtimeID) == .stalled { return true }
    if geometryRecoveryByRuntimeID[runtimeID]?.isUnusable == true { return true }
    guard let deviceUID = routeOutputBindingByRuntimeID[runtimeID]?.deviceUID else { return false }
    return deviceFormatObservation(uid: deviceUID) == .missing
  }

  /// Lets failed managed releases (of `runtimeID`, or all) try again at
  /// once, with their backoff restarted: the user asked for something, or
  /// a device came or went.
  func resetReleasePacing(runtimeID: String? = nil) {
    for id in unreleasedRoutes.keys where runtimeID == nil || id == runtimeID {
      unreleasedRoutes[id]?.nextAttemptAt = .zero
      unreleasedRoutes[id]?.retryInterval = .zero
    }
  }

  /// The app has no live Waves route any more, by whatever path. Every
  /// parked tap still muting it is released now, in the same operation:
  /// leaving them to the next maintenance pass left the app silent for
  /// seconds after every release call that would have succeeded. The row
  /// shows the resulting hold at once. Destroying the parked controllers'
  /// native resources stays maintenance work.
  func appLostItsRoute(_ runtimeID: String) {
    guard controllers[runtimeID]?.isActive != true else { return }
    for controller in orphanedControllers where controller.appID == runtimeID && controller.tapMutesApp {
      retainCleanupDegradations(controller.releaseTapMuteIfHeld())
    }
    publishRouteHolds()
  }

  /// Publishes, on the live snapshot, which apps a parked tap holds silent
  /// and every other sticky explanation (`applyStickyRouteNotes`). Called
  /// whenever a release changes them, and by each path that rewrites a
  /// released row afterwards, so the hold is never overwritten.
  func publishRouteHolds() {
    applyStickyRouteNotes(to: &snapshot.apps)
    refreshGlobalRouteHealth()
    snapshot.updatedAt = .now
  }

  static func stillRoutingNote(appName: String, reason: String?) -> String {
    let note = "Waves couldn't hand \(appName) back to macOS, so it is still playing it at the level you set."
    guard let reason, !reason.isEmpty else { return note }
    return "\(note) \(reason)"
  }

  func dictionaryByLogicalID(_ apps: [AudioApp]) -> [String: AudioApp] {
    apps.reduce(into: [:]) { result, app in
      result[app.logicalID] = app
    }
  }

  func withStatusCheck(_ status: OSStatus, action: String) throws {
    if status != noErr {
      throw BackendError.managedRouteUnavailable("\(action) failed (OSStatus: \(status)).")
    }
  }

  func retainCleanupStatus(
    _ status: OSStatus,
    appID: String? = nil,
    stage: CleanupStage,
    detail: String
  ) {
    retainCleanupDegradations(
      checkedCleanupDegradations(from: [
        CleanupStatusObservation(
          appID: appID,
          stage: stage,
          nativeStatus: status,
          detail: detail
        )
      ]))
  }

  /// Records cleanup failures for diagnostics, bounded in both size and noise.
  ///
  /// A route that fails the same teardown stage on every maintenance pass used
  /// to append a row and emit a log line every time, for the life of the
  /// process — an unbounded array and an unbounded log for one stuck condition.
  /// Keeping the first rows preserves the original failure (usually the
  /// informative one) while a counter records what came after.
  func retainCleanupDegradations(_ degradations: [CleanupDegradation]) {
    guard !degradations.isEmpty else { return }
    for degradation in degradations {
      if retainedCleanupDegradations.count < Self.maxRetainedCleanupDegradations {
        retainedCleanupDegradations.append(degradation)
      } else {
        droppedCleanupDegradations += 1
      }
    }
    logCleanupDegradations(degradations)
  }

  /// Retires a controller that a successor has replaced, without releasing
  /// its tap mute (`PerAppTapController.DisposalKind.retirement`).
  func retireController(_ controller: PerAppTapController) {
    let result = controller.dispose(.retirement)
    park(controller)
    retainCleanupDegradations(result.degradations)
  }

  /// Force-releases a controller that is not installed: a replacement that
  /// never left silence, so there is nothing for it to carry.
  func forceReleaseUninstalledController(_ controller: PerAppTapController) {
    let result = controller.dispose(.forcedRelease)
    park(controller)
    retainCleanupDegradations(result.degradations)
    appLostItsRoute(controller.appID)
  }

  private func park(_ controller: PerAppTapController) {
    guard !controller.isTornDown, !orphanedControllers.contains(where: { $0 === controller }) else { return }
    orphanedControllers.append(controller)
  }

  /// A parked controller has one job: get out of the way. Its renderer was
  /// cut to silence for good when it was disposed, so it never plays again.
  /// What it may still hold is retried here, on every pass, for as long as it
  /// exists:
  /// - While its app has a live Waves route, its tap stays muted: the live
  ///   route's tap mutes the app's own output anyway, and the app is heard
  ///   through that route. Only the native teardown is retried.
  /// - Once the app has no live route, for whatever reason, its tap's mute is
  ///   released too, so the app plays at its own level.
  ///
  /// Each attempt is a few Core Audio calls on handles that already exist.
  /// Nothing is created, so it spends no rebuild budget; a destroy that
  /// fails changes no device list, and one that succeeds forgets its handle,
  /// so it raises its one notification once. A controller that is fully torn
  /// down is forgotten.
  ///
  /// A tap whose mute will not release leaves its app silent while it has no
  /// live route. Waves cannot fix that from inside the process and does not
  /// paper over it: the app's row and Diagnostics say so
  /// (`appsHeldSilentByParkedTaps`, `AudioApp.isHeldSilentByWaves`).
  func retryParkedControllers() {
    guard !orphanedControllers.isEmpty else { return }
    for controller in orphanedControllers {
      let hasLiveRoute = controllers[controller.appID]?.isActive == true
      _ = controller.retryDispose(releasingTapMute: !hasLiveRoute)
    }
    orphanedControllers.removeAll(where: \.isTornDown)
    guard heldSilentRuntimeIDs(in: snapshot.apps) != appsHeldSilentByParkedTaps else { return }
    publishRouteHolds()
  }

  /// Apps a parked tap holds silent: the tap still mutes the app's own
  /// output, no live route of Waves plays it, and the tap was built for the
  /// process the row describes now. A tap built for an earlier process that
  /// reused the app's IDs cannot mute a relaunched one; a row whose identity
  /// is ambiguous shows that error instead.
  func heldSilentRuntimeIDs(in apps: [AudioApp]) -> Set<String> {
    let lifetimeByID = Dictionary(
      apps.filter { !$0.hasAmbiguousIdentity }.map { ($0.id, $0.runtimeIdentity?.lifetime) },
      uniquingKeysWith: { first, _ in first }
    )
    return Set(
      orphanedControllers
        .filter { controller in
          guard controller.tapMutesApp, controllers[controller.appID]?.isActive != true,
            let lifetime = lifetimeByID[controller.appID]
          else { return false }
          return lifetime == controller.ownerProcessLifetime
        }
        .map(\.appID)
    )
  }

  /// Whether every parked renderer of `runtimeID` is confirmed silent, so a
  /// new route for the app may be un-muted. Each was cut when it was
  /// disposed; a cut whose wait timed out may still have a callback ahead of
  /// it, so it is confirmed here (`PerAppTapController.cutToSilence`).
  func confirmParkedRenderersSilent(forRuntimeID runtimeID: String) -> Bool {
    orphanedControllers.filter { $0.appID == runtimeID }.allSatisfy { $0.cutToSilence() }
  }

  static func heldSilentNote(for app: AudioApp) -> String {
    "Waves could not release its hold on \(app.displayName)'s sound, so it stays silent. Quit and reopen Waves to restore it."
  }

  /// Logs the first occurrence of each (stage, app) pair, then stays quiet:
  /// repetition adds no information and buries everything else. A route stuck
  /// failing the same teardown every maintenance pass used to log forever.
  func logCleanupDegradations(_ degradations: [CleanupDegradation]) {
    for degradation in degradations {
      let key = CleanupLogKey(stage: degradation.stage, appID: degradation.appID)
      let seen = (cleanupDegradationLogCounts[key] ?? 0) + 1
      cleanupDegradationLogCounts[key] = seen
      guard seen == 1 else { continue }
      logger.error(
        "Cleanup degraded at \(degradation.stage.name, privacy: .public) for \(degradation.appID ?? "backend", privacy: .public): OSStatus \(degradation.nativeStatus ?? 0, privacy: .public). \(degradation.detail ?? "No detail.", privacy: .public)"
      )
    }
  }
}
