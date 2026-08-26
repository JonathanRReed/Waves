import AudioToolbox
import Foundation
import WavesAudioCore

// MARK: - Route health, reattachment, and periodic maintenance

extension WorkspaceAudioControlBackend {

  /// Recompute global route readiness from authorization, the confirmed current
  /// output device, and every app route. A successful app apply cannot erase an
  /// authorization/device query failure or another app's route error.
  func refreshGlobalRouteHealth(latestError: String? = nil) {
    let hasRouteErrors = hasBlockingRouteErrors(in: snapshot.apps)
    let deviceIsReady = snapshot.currentDevice != nil
    snapshot.backendStatus.hasRequiredPermissions = captureAuthorization == .authorized
    snapshot.backendStatus.isRouteRecoveryHealthy =
      supportsPerAppRouting
      && captureAuthorization == .authorized
      && deviceIsReady
      && !hasRouteErrors
      && routerObservationListenerFailureDetail == nil

    let routeError =
      hasRouteErrors
      ? latestError
        ?? snapshot.apps.first(where: { $0.routingState == .error && $0.notes != nil })?.notes
        ?? snapshot.backendStatus.lastError
      : nil
    snapshot.backendStatus.lastError = combinedBackendError(routeError: routeError)
  }

  func combinedBackendError(routeError: String?) -> String? {
    var details: [String] = []
    if let authorizationError = CaptureAuthorizationPresentation(captureAuthorization).backendErrorDetail {
      details.append(authorizationError)
    }
    if let outputDeviceReadinessError {
      details.append(outputDeviceReadinessError)
    }
    if let routerObservationListenerFailureDetail {
      details.append(routerObservationListenerFailureDetail)
    }
    if let routeError, !details.contains(routeError) {
      details.append(routeError)
    }
    return details.isEmpty ? nil : details.joined(separator: " ")
  }

  // Apps with hasNoAudioCapability never had a Core Audio process object to
  // begin with (menu-bar utilities, CLI tools) — retrying can never route
  // them, so they shouldn't hold the global "Needs attention" badge or the
  // Route recovery diagnostic red forever. Their row still shows an Error
  // chip + explanation; this only excludes them from the app-wide signal.
  func hasBlockingRouteErrors(in apps: [AudioApp]) -> Bool {
    apps.contains { $0.routingState == .error && !$0.hasNoAudioCapability }
  }

  /// Records route failures. A missing active stream on a normal app is kept as
  /// monitor-only because it is a retryable precondition, not a broken route.
  /// True route failures become `.error`; permanent non-audio rows also record
  /// `hasNoAudioCapability` so UI can suggest exclusion.
  func markRouteError(at index: Int, error: Error) {
    if case BackendError.noActiveAudioStream = error {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.apps[index].hasNoAudioCapability = false
      snapshot.apps[index].routeHealthContext = nil
      return
    }

    snapshot.apps[index].routingState = .error
    snapshot.apps[index].notes = error.localizedDescription
    snapshot.apps[index].routeHealthContext = nil
    if case BackendError.noAudioCapability = error {
      snapshot.apps[index].hasNoAudioCapability = true
    } else {
      snapshot.apps[index].hasNoAudioCapability = false
    }
  }

  func reattachRoutes(forLogicalIDs logicalIDs: Set<String>) async {
    guard !isShuttingDown else { return }
    // A reattach is one coherent setup pass. Capture router activity before
    // any await so every route sees the same verified Security/Core Audio view.
    let routerActivity = verifiedRouterActivityProvider?()
    var lastError: String?

    // applyRoute suspends (tap-retry backoff) and the actor is reentrant, so a
    // concurrent refresh/buildSnapshot can replace `snapshot.apps` mid-loop.
    // Iterate by logicalID and re-resolve the row after every await — a stale
    // index would trap or write onto the wrong app. Rows that vanished are
    // skipped.
    let targetLogicalIDs = snapshot.apps.map(\.logicalID).filter { logicalIDs.contains($0) }
    for logicalID in targetLogicalIDs {
      guard !isShuttingDown else { return }
      guard let app = snapshot.apps.first(where: { $0.logicalID == logicalID }) else { continue }

      if let conflict = competingAudioRouterConflict(
        for: app,
        routerActivity: routerActivity
      ) {
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          suspendManagedRouteForConflict(at: index, conflict: conflict)
        }
        continue
      }

      do {
        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted,
          routerActivity: routerActivity
        )
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          snapshot.apps[index].routingState = .managed
          snapshot.apps[index].appliedVolume =
            snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
          snapshot.apps[index].notes = nil
          snapshot.apps[index].routeHealthContext = nil
        }
      } catch {
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          markRouteError(at: index, error: error)
        }
        lastError = error.localizedDescription
      }
    }

    // Health is "no errors anywhere", not "any route recovered": a partial
    // reattach that leaves some apps in .error must keep the badge red.
    refreshGlobalRouteHealth(latestError: lastError)
    snapshot.updatedAt = .now
  }

  func startLevelUpdateTask() {
    guard !isShuttingDown else { return }
    levelUpdateTask?.cancel()
    levelUpdateTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)  // 0.25 seconds (optimized from 0.1s)
        await self?.updateAudioLevels()
      }
    }
  }

  private func stopLevelUpdateTask() {
    levelUpdateTask?.cancel()
    levelUpdateTask = nil
  }

  private func updateAudioLevels() async {
    await updateAudioLevels(at: monotonicRouteTime())
  }

  func updateAudioLevels(at now: Duration) async {
    guard !isShuttingDown else { return }
    if routerObservationListeners.consumeFallbackReobservationTick() {
      retainCleanupDegradations(addRouterObservationListeners())
      markRouterObservationDirty()
    }
    // Most of the app's lifetime has no managed renderers. Avoid rescanning the
    // entire app snapshot four times per second when there is nothing a router
    // conflict could suspend.
    let routerActivity = verifiedRouterActivityProvider?()
    let routerReleasedRouteIDs = observeCompetingRouterConflicts(
      at: now,
      routerActivity: routerActivity
    )
    // With no controllers left there are no levels to read — but there may still
    // be a parked teardown to retry, and that is exactly the case where one
    // exists: disposing the last controller removes it from `controllers` before
    // dispose() runs, so a failure there leaves an orphan with nothing to drive
    // its retry. A stranded tap is created `.mutedWhenTapped`, so the app it
    // targets stays silent until Waves restarts.
    guard !controllers.isEmpty else {
      routeMaintenanceTick += 1
      if routeMaintenanceTick >= routeMaintenanceTickInterval || !routerReleasedRouteIDs.isEmpty {
        routeMaintenanceTick = 0
        retryOrphanedControllerDisposals()
        await performRouteMaintenance(
          forceRebuildIDs: routerReleasedRouteIDs,
          routerActivity: routerActivity
        )
      }
      return
    }

    let appIndexMap = snapshot.apps.enumerated().reduce(into: [String: Int]()) { result, pair in
      result[pair.element.logicalID] = pair.offset
    }

    var routeIDsNeedingRebuild = Set<String>()
    var geometryRecoveryRouteIDs = Set<String>()

    for (appID, controller) in controllers {
      if controller.consumeGeometryMismatch() {
        var recovery = geometryRecoveryByRuntimeID[appID] ?? GeometryRecoveryCoordinator()
        _ = recovery.signalMismatch(at: now)
        geometryRecoveryByRuntimeID[appID] = recovery
        if let index = appIndexMap[appID] ?? snapshot.apps.firstIndex(where: { $0.id == appID }) {
          snapshot.apps[index].routeHealthContext = .geometryRecoveryInProgress
          snapshot.apps[index].notes = "Audio geometry changed. Waves is rebuilding this route asynchronously."
          snapshot.updatedAt = .now
        }
      }
      if var recovery = geometryRecoveryByRuntimeID[appID],
        case .attempt = recovery.beginRecovery(at: now)
      {
        geometryRecoveryByRuntimeID[appID] = recovery
        routeIDsNeedingRebuild.insert(appID)
        geometryRecoveryRouteIDs.insert(appID)
      }

      guard controller.isActive else {
        routeIDsNeedingRebuild.insert(appID)
        continue
      }

      let (peak, rms) = controller.getCurrentLevels()

      if let index = appIndexMap[appID] ?? snapshot.apps.firstIndex(where: { $0.id == appID }) {
        let app = snapshot.apps[index]
        // A muted or volume-0 app emits silence, so its meters must read zero even
        // if the controller's last render cycle left a stale non-zero level (e.g.
        // the controller is gone, or a short-circuit branch raced the poll).
        // Only an EXPLICIT zero applied volume forces silence: a nil appliedVolume
        // means "unknown", not "muted" (e.g. an app first enrolled via the Boost
        // menu has a managed route but no assigned appliedVolume), and must not
        // zero its meters.
        let isVolumeZero = app.appliedVolume.map { $0 == 0 } ?? false
        if app.isMuted || isVolumeZero {
          snapshot.apps[index].peakLevel = 0
          snapshot.apps[index].rmsLevel = 0
        } else {
          snapshot.apps[index].peakLevel = peak
          snapshot.apps[index].rmsLevel = rms
        }

        // A controller's target objects disappear whenever the source app quits,
        // which is exactly when this check runs — so the tally absorbs those
        // instead of logging a warning per dead object per poll.
        var stale = StaleAudioObjectTally()
        let sourceIsRunningOutput = controller.targetProcessObjectIDs.contains {
          processObjectLivenessProvider?($0) ?? isProcessRunningOutput($0, stale: &stale)
        }
        // Liveness comes from the IO proc actually running, never from signal
        // level. Judging a route dead because it went quiet meant that any app
        // holding output IO open while emitting digital silence — a call with
        // nobody talking, a stream between cues, a paused game — got its process
        // tap and aggregate device torn down and rebuilt every 6 seconds,
        // forever, with an audible dropout each time and two device-change
        // notifications feeding back into route maintenance.
        let renderTick = controller.currentRenderTick()
        let isRendering = RouteLivenessJudgment.isRendering(
          currentTick: renderTick,
          previousTick: lastRenderTickByAppID[app.logicalID]
        )
        lastRenderTickByAppID[app.logicalID] = renderTick

        if app.routingState == .managed,
          !app.isMuted,
          !isVolumeZero,
          sourceIsRunningOutput,
          !isRendering
        {
          let ticks = (staleRouteTicks[app.logicalID] ?? 0) + 1
          staleRouteTicks[app.logicalID] = ticks
          if ticks >= staleRouteThresholdTicks {
            routeIDsNeedingRebuild.insert(app.logicalID)
          }
        } else {
          staleRouteTicks.removeValue(forKey: app.logicalID)
        }
      }
    }

    routeMaintenanceTick += 1
    routeIDsNeedingRebuild.formUnion(routerReleasedRouteIDs)
    if routeMaintenanceTick >= routeMaintenanceTickInterval || !routeIDsNeedingRebuild.isEmpty {
      routeMaintenanceTick = 0
      // A tap left behind by a failed teardown keeps its app muted, so keep
      // trying to release it rather than leaving the app silent for the session.
      retryOrphanedControllerDisposals()
      await performRouteMaintenance(
        forceRebuildIDs: routeIDsNeedingRebuild,
        geometryRecoveryIDs: geometryRecoveryRouteIDs,
        routerActivity: routerActivity
      )
    }
  }

  func addRouterObservationListeners() -> [CleanupDegradation] {
    guard !isShuttingDown else { return [] }
    let degradations = routerObservationListeners.install { [weak self] in
      Task { [weak self] in await self?.markRouterObservationDirty() }
    }
    if degradations.isEmpty, !routerObservationListeners.requiresFallbackReobservation {
      routerObservationListenerFailureDetail = nil
    } else if let degradation = degradations.first {
      routerObservationListenerFailureDetail =
        "Waves could not attach a router observation listener (OSStatus: \(degradation.nativeStatus ?? -1)). Re-observing every second until listeners attach."
    }
    refreshGlobalRouteHealth()
    return degradations
  }

  func removeRouterObservationListeners() -> [CleanupDegradation] {
    routerObservationListeners.remove()
  }

  private func performRouteMaintenance(
    forceRebuildIDs: Set<String> = [],
    geometryRecoveryIDs: Set<String> = [],
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) async {
    if let routeMaintenanceOverride {
      await routeMaintenanceOverride(forceRebuildIDs, geometryRecoveryIDs)
      return
    }
    await maintainManagedRoutes(
      forceRebuildIDs: forceRebuildIDs,
      geometryRecoveryIDs: geometryRecoveryIDs,
      routerActivity: routerActivity
    )
  }

  func markRouterObservationDirty() {
    routerObservationGeneration &+= 1
  }

  private func maintainManagedRoutes(
    forceRebuildIDs: Set<String> = [],
    geometryRecoveryIDs: Set<String> = [],
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) async {
    guard !isShuttingDown else { return }
    let managedIDs = snapshot.apps
      .filter { $0.routingState == .managed || forceRebuildIDs.contains($0.logicalID) || forceRebuildIDs.contains($0.id) }
      .map(\.logicalID)
    guard !managedIDs.isEmpty else { return }

    var changed = false
    var lastError: String?

    for appID in managedIDs {
      guard !isShuttingDown else { return }
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
        continue
      }

      let app = snapshot.apps[index]
      let shouldForceRebuild = forceRebuildIDs.contains(app.logicalID) || forceRebuildIDs.contains(app.id)

      do {
        let processTarget = try resolveProcessTarget(for: app)
        let processObjectIDs = processTarget.processObjectIDs
        if !shouldForceRebuild,
          let controller = controllers[app.id],
          controller.isActive,
          controller.covers(
            TargetProcessFamily(
              logicalID: app.logicalID,
              processObjectIDs: processObjectIDs,
              processLifetimeIdentities: processTarget.processLifetimeIdentities
            )
          )
        {
          continue
        }

        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted,
          forceRebuild: shouldForceRebuild,
          routerActivity: routerActivity
        )

        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
          snapshot.apps[currentIndex].routingState = .managed
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
          snapshot.apps[currentIndex].notes = nil
          snapshot.apps[currentIndex].routeHealthContext = nil
        }
        staleRouteTicks.removeValue(forKey: app.logicalID)
        lastRenderTickByAppID.removeValue(forKey: app.logicalID)
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          _ = recovery.finishRecovery(succeeded: true, at: monotonicRouteTime())
          geometryRecoveryByRuntimeID[app.id] = recovery
        }
        changed = true
      } catch {
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          let action = recovery.finishRecovery(succeeded: false, at: monotonicRouteTime())
          geometryRecoveryByRuntimeID[app.id] = recovery
          if case .exhausted = action {
            let exhaustion = BackendError.managedRouteUnavailable(
              "Audio route recovery failed after 3 attempts. Refresh the route or restart Waves."
            )
            if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
              markRouteError(at: currentIndex, error: exhaustion)
              snapshot.apps[currentIndex].routeHealthContext = .geometryRecoveryExhausted
            }
            lastError = exhaustion.localizedDescription
            changed = true
            continue
          }
        }
        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
          markRouteError(at: currentIndex, error: error)
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
        }
        staleRouteTicks.removeValue(forKey: app.logicalID)
        lastRenderTickByAppID.removeValue(forKey: app.logicalID)
        lastError = error.localizedDescription
        changed = true
      }
    }

    if changed {
      refreshGlobalRouteHealth(latestError: lastError)
      snapshot.updatedAt = .now
    }
  }

  private func monotonicRouteTime() -> Duration {
    .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
  }
}
