import AudioToolbox
import Foundation
import OSLog
import WavesAudioCore

// MARK: - Controller disposal and cleanup accounting
//
// Disposal is idempotent and fail-open for the target app's audio. A
// controller whose native teardown fails is parked: silent for good, and
// retried on every maintenance pass until it is gone.

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

  /// Disposes a controller fail open and parks it if its native teardown did
  /// not finish.
  ///
  /// A failed teardown is not cosmetic: the process tap is created with
  /// `.mutedWhenTapped`, so while it exists the app's own output can stay
  /// muted. Dropping it would also free callback state Core Audio may still
  /// use. Parking keeps it until a retry finishes the job.
  func disposeController(_ controller: PerAppTapController) -> [CleanupDegradation] {
    let degradations = controller.dispose()
    park(controller)
    return degradations
  }

  /// Retires a controller that a successor has replaced, without releasing its
  /// tap mute (see `PerAppTapController.dispose(releasingTapMute:)`).
  func retireController(_ controller: PerAppTapController) {
    let degradations = controller.dispose(releasingTapMute: false)
    park(controller)
    retainCleanupDegradations(degradations)
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
  /// (`appsHeldSilentByParkedTaps`).
  func retryParkedControllers() {
    guard !orphanedControllers.isEmpty else { return }
    for controller in orphanedControllers {
      let hasLiveRoute = controllers[controller.appID]?.isActive == true
      _ = controller.retryDispose(releasingTapMute: !hasLiveRoute)
    }
    orphanedControllers.removeAll(where: \.isTornDown)
    let held = Set(
      orphanedControllers
        .filter { $0.tapMutesApp && controllers[$0.appID]?.isActive != true }
        .map(\.appID)
    )
    guard held != appsHeldSilentByParkedTaps else { return }
    let releasedIDs = appsHeldSilentByParkedTaps.subtracting(held)
    appsHeldSilentByParkedTaps = held
    // An app no longer held plays at its own level again.
    for index in snapshot.apps.indices where releasedIDs.contains(snapshot.apps[index].id) {
      let app = snapshot.apps[index]
      guard controllers[app.id]?.isActive != true, app.notes == Self.heldSilentNote(for: app) else { continue }
      snapshot.apps[index].notes = nil
      if app.routeHealthContext == nil { snapshot.apps[index].routingState = .monitorOnly }
    }
    applyStickyRouteNotes(to: &snapshot.apps)
    refreshGlobalRouteHealth()
    snapshot.updatedAt = .now
  }

  /// Cuts every parked renderer of `runtimeID` to silence before a new route
  /// for the app is un-muted. Each was cut when it was disposed and cannot be
  /// un-muted, so this changes nothing; it makes the handoff's guarantee (no
  /// other renderer of the app can be heard) independent of how a controller
  /// came to be parked.
  func cutParkedRenderers(forRuntimeID runtimeID: String) {
    for controller in orphanedControllers where controller.appID == runtimeID {
      controller.cutToSilence()
    }
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
