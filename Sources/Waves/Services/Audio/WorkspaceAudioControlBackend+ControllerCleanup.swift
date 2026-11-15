import AudioToolbox
import Foundation
import OSLog
import WavesAudioCore

// MARK: - Controller disposal and cleanup accounting
//
// Disposal is idempotent and fail-open for the target app's audio; anything
// that could not be torn down is retained and retried in bounded rounds.

extension WorkspaceAudioControlBackend {
  func releaseControllers(
    forRuntimeIdentity runtimeIdentity: AppRuntimeIdentity,
    clearMuteState: Bool = false
  ) async {
    guard !isShuttingDown else { return }
    let targetIDs = snapshot.apps.filter { app in
      app.runtimeIdentity == runtimeIdentity
    }.map(\.id)

    guard !targetIDs.isEmpty else { return }

    for id in targetIDs {
      if let controller = controllers.removeValue(forKey: id) {
        retainCleanupDegradations(disposeController(controller))
      }
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
  }

  func disposeControllers(keeping appIDs: Set<String>) -> [CleanupDegradation] {
    let stale = Set(controllers.keys).subtracting(appIDs).sorted()
    var degradations: [CleanupDegradation] = []
    for appID in stale {
      if let controller = controllers.removeValue(forKey: appID) {
        degradations.append(contentsOf: disposeController(controller))
      }
      controllerGenerationByRuntimeID.removeValue(forKey: appID)
      staleRouteTicks.removeValue(forKey: appID)
      lastRenderTickByAppID.removeValue(forKey: appID)
      geometryRecoveryByRuntimeID.removeValue(forKey: appID)
      routeOutputBindingByRuntimeID.removeValue(forKey: appID)
    }
    return degradations
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

  /// Disposes a controller and, if the native teardown failed, keeps it for
  /// another attempt.
  ///
  /// A failed teardown is not cosmetic: the process tap is created with
  /// `.mutedWhenTapped`, so while it exists but nothing renders it, the target
  /// app is *silent*. Before this, the controller was dropped on the floor
  /// regardless of outcome and `IdempotentCleanupResult` memoized the failure,
  /// so nothing would ever try again — the app stayed muted for the rest of the
  /// session with no signal to the user.
  func disposeController(_ controller: PerAppTapController) -> [CleanupDegradation] {
    let degradations = controller.dispose()
    guard !degradations.isEmpty else { return degradations }
    orphanedControllers.append(controller)
    return degradations
  }

  /// Retires a controller that a successor has replaced, without releasing its
  /// tap mute (see `PerAppTapController.dispose(releasingTapMute:)`). A failed
  /// teardown parks it like any other; it stays silent meanwhile.
  func retireController(_ controller: PerAppTapController) {
    let degradations = controller.dispose(releasingTapMute: false)
    guard !degradations.isEmpty else { return }
    orphanedControllers.append(controller)
    retainCleanupDegradations(degradations)
  }

  /// Retries parked teardowns and keeps every parked controller's app audible.
  /// Driven from the existing route-maintenance tick, so it costs nothing when
  /// there is nothing parked.
  ///
  /// Two separate policies:
  /// - Teardown is retried a bounded number of times. A controller whose IO
  ///   proc never relinquished its callback stays alive for the backend's
  ///   lifetime, because dropping it would free callback state Core Audio may
  ///   still use.
  /// - Release is not bounded. While the app has a live route, that route's
  ///   tap keeps the app's own output muted, and releasing a parked tap's
  ///   mute could only add a second, full-level copy. Once the app has no live
  ///   route, every pass releases a parked tap that still mutes it (fail
  ///   open), however many teardowns failed. If even that fails, a parked
  ///   renderer that can still play is restored to the app's committed level,
  ///   so the app is not left silent.
  func retryOrphanedControllerDisposals() {
    guard !orphanedControllers.isEmpty else { return }
    var stillOrphaned: [PerAppTapController] = []
    for controller in orphanedControllers {
      let controllerID = ObjectIdentifier(controller)
      let hasLiveRoute = controllers[controller.appID]?.isActive == true
      let attempts = orphanDisposeAttempts[controllerID] ?? 0
      var exhaustedNow = false
      if attempts < Self.maxOrphanDisposeRetries {
        let degradations = controller.retryDispose(releasingTapMute: !hasLiveRoute)
        if degradations.isEmpty {
          // Released at last — drop its attempt count too, so a later controller
          // that happens to reuse this appID starts from a full retry budget.
          orphanDisposeAttempts.removeValue(forKey: controllerID)
          continue
        }
        orphanDisposeAttempts[controllerID] = attempts + 1
        exhaustedNow = attempts + 1 >= Self.maxOrphanDisposeRetries
      }
      if !hasLiveRoute {
        keepAppAudible(withParked: controller)
      }
      if exhaustedNow {
        retainCleanupDegradations([
          CleanupDegradation(
            appID: controller.appID,
            stage: .controllerDisposal,
            detail:
              "Native audio resources still had not released after \(Self.maxOrphanDisposeRetries) attempts. Waves keeps the controller so its callbacks stay safe. \(parkedAudibilityDetail(controller, hasLiveRoute: hasLiveRoute))"
          )
        ])
      }
      stillOrphaned.append(controller)
    }
    orphanedControllers = stillOrphaned
  }

  /// The release policy for one parked controller whose app has no live route.
  private func keepAppAudible(withParked controller: PerAppTapController) {
    retainCleanupDegradations(controller.releaseTapMuteForFailOpen())
    guard controller.tapMutesApp, controller.rendererIsSilent, controller.isActive,
      !orphanedControllers.contains(where: {
        $0 !== controller && $0.appID == controller.appID && !$0.rendererIsSilent
      }),
      let app = snapshot.apps.first(where: { $0.id == controller.appID })
    else { return }
    // The tap will not release, its renderer still runs, and no other parked
    // renderer already carries the app: let this one carry it again, at the
    // level the user set, never above it.
    controller.apply(volume: app.desiredVolume, volumeBoost: app.volumeBoost, muted: app.isMuted)
  }

  /// What a parked controller does to its app's sound right now.
  private func parkedAudibilityDetail(_ controller: PerAppTapController, hasLiveRoute: Bool) -> String {
    if !controller.tapMutesApp {
      return "Its tap no longer mutes the app, so the app plays at its own volume."
    }
    if hasLiveRoute {
      return "It is silent and its tap stays muted while the app's current route plays; Waves releases it if that route goes away."
    }
    if !controller.rendererIsSilent {
      return "Its tap could not be released, so its renderer plays the app at the level set in Waves."
    }
    return "Its tap could not be released, so the app may stay silent until Waves quits."
  }

  /// Controllers parked for `runtimeID` after a failed teardown.
  func parkedControllerCount(forRuntimeID runtimeID: String) -> Int {
    orphanedControllers.count { $0.appID == runtimeID }
  }

  /// Silences every parked controller of `runtimeID` that still plays, before
  /// a new route for the app is heard. A parked renderer carries the app only
  /// while nothing else does; beside a new route it would be a second copy.
  func silenceParkedControllers(forRuntimeID runtimeID: String) {
    for controller in orphanedControllers where controller.appID == runtimeID && !controller.rendererIsSilent {
      _ = controller.silenceForHandoff(maxPolls: 0, pause: {})
    }
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
