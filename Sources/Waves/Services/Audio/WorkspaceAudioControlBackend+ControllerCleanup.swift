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
    }
    return degradations
  }

  /// - Parameter knownIconData: icons already encoded on a previous pass, keyed
  ///   by logical ID. Reused rather than re-encoded; an app's icon is fixed for
  ///   as long as it runs.

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

  /// Retries parked teardowns, dropping each one once it succeeds or has had
  /// enough attempts. Driven from the existing route-maintenance tick, so it
  /// costs nothing when there is nothing parked.
  func retryOrphanedControllerDisposals() {
    guard !orphanedControllers.isEmpty else { return }
    var stillOrphaned: [PerAppTapController] = []
    for controller in orphanedControllers {
      let controllerID = ObjectIdentifier(controller)
      // A controller whose native IO proc never relinquished its callback must
      // remain alive for the lifetime of this backend. Dropping it after the
      // retry budget would free callback state that Core Audio may still use.
      if (orphanDisposeAttempts[controllerID] ?? 0) >= Self.maxOrphanDisposeRetries {
        stillOrphaned.append(controller)
        continue
      }
      let degradations = controller.retryDispose()
      if degradations.isEmpty {
        // Released at last — drop its attempt count too, so a later controller
        // that happens to reuse this appID starts from a full retry budget.
        orphanDisposeAttempts.removeValue(forKey: controllerID)
        continue
      }
      let attempts = (orphanDisposeAttempts[controllerID] ?? 0) + 1
      orphanDisposeAttempts[controllerID] = attempts
      if attempts >= Self.maxOrphanDisposeRetries {
        retainCleanupDegradations([
          CleanupDegradation(
            appID: controller.appID,
            stage: .controllerDisposal,
            detail:
              "Native audio resources still had not released after \(attempts) attempts. Waves retained the controller to keep callbacks safe and original audio fail-open until restart."
          )
        ])
        stillOrphaned.append(controller)
        continue
      }
      stillOrphaned.append(controller)
    }
    orphanedControllers = stillOrphaned
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
