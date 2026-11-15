import AudioToolbox
import Foundation
import WavesAudioCore

// MARK: - Route health, reattachment, and periodic maintenance

extension WorkspaceAudioControlBackend {

  /// The one definition of "route recovery is healthy".
  ///
  /// `refreshGlobalRouteHealth` and `buildSnapshot` both publish this flag. When
  /// each spelled the conditions out, the snapshot rebuild left out the router
  /// listener, so a refresh could report Ready beside a listener failure.
  func isRouteRecoveryHealthy(deviceIsReady: Bool, hasRouteErrors: Bool) -> Bool {
    supportsPerAppRouting
      && captureAuthorization == .authorized
      && deviceIsReady
      && !hasRouteErrors
      && routerObservationListenerFailureDetail == nil
  }

  /// Recompute global route readiness from authorization, the confirmed current
  /// output device, and every app route. A successful app apply cannot erase an
  /// authorization/device query failure or another app's route error.
  func refreshGlobalRouteHealth(latestError: String? = nil) {
    let hasRouteErrors = hasBlockingRouteErrors(in: snapshot.apps)
    let deviceIsReady = snapshot.currentDevice != nil
    snapshot.backendStatus.hasRequiredPermissions = captureAuthorization == .authorized
    snapshot.backendStatus.isRouteRecoveryHealthy = isRouteRecoveryHealthy(
      deviceIsReady: deviceIsReady,
      hasRouteErrors: hasRouteErrors
    )

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

  enum ReattachMode {
    /// Build a route where one is missing or no longer covers the app.
    case attach
    /// Rebuild every route on the current default output (make before break).
    /// A route that cannot be rebuilt is released rather than left on the old
    /// device: the 1.7.0 policy is that a failed recovery restores the app's
    /// own audibility and says why.
    case rehome
  }

  func reattachRoutes(
    forLogicalIDs logicalIDs: Set<String>,
    origin: RouteWorkOrigin,
    mode: ReattachMode = .attach
  ) async {
    await reattachRoutes(repairContexts(forLogicalIDs: logicalIDs), origin: origin, mode: mode)
  }

  /// Reattaches the routes `targets` describe. Each context is the route's
  /// authorization, captured by the caller before its own first suspension
  /// and before any route in the batch suspends. A route whose app was
  /// excluded, yielded to another router, or otherwise changed meanwhile
  /// fails its context check and is skipped; building a fresh context at its
  /// turn would have authorized it from the changed row.
  func reattachRoutes(
    _ targets: [RouteRepairContext],
    origin: RouteWorkOrigin,
    mode: ReattachMode = .attach
  ) async {
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
    for repairContext in targets {
      let logicalID = repairContext.logicalID
      guard !isShuttingDown else { return }
      guard isRepairCurrent(repairContext),
        let app = snapshot.apps.first(where: { $0.logicalID == logicalID })
      else { continue }

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
          forceRebuild: mode == .rehome,
          repairContext: repairContext,
          origin: origin,
          routerActivity: routerActivity
        )
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          snapshot.apps[index].routingState = .managed
          snapshot.apps[index].appliedVolume =
            snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
          snapshot.apps[index].notes = nil
          snapshot.apps[index].routeHealthContext = nil
        }
      } catch is IntentSupersededError {
        // Newer intent or route work for this app landed while the reattach
        // was suspended; that work owns the route now.
        continue
      } catch is IntentBackendStoppedError {
        return
      } catch {
        var reported = error
        if mode == .rehome {
          releaseRoute(runtimeID: app.id)
          reported = failedMoveError(for: app, error)
        }
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          markRouteError(at: index, error: reported)
          if mode == .rehome {
            snapshot.apps[index].appliedVolume = nil
            snapshot.apps[index].peakLevel = 0
            snapshot.apps[index].rmsLevel = 0
          }
        }
        lastError = reported.localizedDescription
      }
    }

    // Health is "no errors anywhere", not "any route recovered": a partial
    // reattach that leaves some apps in .error must keep the badge red.
    refreshGlobalRouteHealth(latestError: lastError)
    snapshot.updatedAt = .now
  }

  /// What a route that could not be moved to its new output reports once it
  /// has been released.
  func failedMoveError(for app: AudioApp, _ error: Error) -> Error {
    switch error {
    case BackendError.noActiveAudioStream, BackendError.noAudioCapability:
      // Not a route failure: the app has nothing to tap right now, and
      // markRouteError already classifies these.
      return error
    default:
      return BackendError.managedRouteUnavailable(
        "Waves couldn't move \(app.displayName) to the new output device, so it now plays at its own volume. \(error.localizedDescription)"
      )
    }
  }

  /// Disposes an app's controller and forgets its per-route bookkeeping.
  func releaseRoute(runtimeID: String) {
    if let controller = controllers.removeValue(forKey: runtimeID) {
      retainCleanupDegradations(disposeController(controller))
    }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
    staleRouteTicks.removeValue(forKey: runtimeID)
    lastRenderTickByAppID.removeValue(forKey: runtimeID)
    geometryRecoveryByRuntimeID.removeValue(forKey: runtimeID)
    routeOutputBindingByRuntimeID.removeValue(forKey: runtimeID)
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
    // The verified-router view reads every Core Audio process object and runs
    // a Security check on each router candidate. Only the ticks that re-observe
    // conflicts (after a process- or tap-list change) or run route maintenance
    // need it, so it is built lazily and at most once per tick rather than four
    // times a second for the life of the process.
    var memoizedRouterActivity: VerifiedRouterActivitySnapshot??
    func routerActivity() -> VerifiedRouterActivitySnapshot? {
      if let memoized = memoizedRouterActivity { return memoized }
      let activity = verifiedRouterActivityProvider?()
      memoizedRouterActivity = .some(activity)
      return activity
    }
    // Geometry-recovery state belongs to a live controller. Any path that
    // retired the controller (exclusion, router yield, app quit) retires its
    // coordinator too, so a relaunched app or a rebuilt route never inherits
    // a spent recovery budget.
    if geometryRecoveryByRuntimeID.keys.contains(where: { controllers[$0] == nil }) {
      geometryRecoveryByRuntimeID = geometryRecoveryByRuntimeID.filter { controllers[$0.key] != nil }
    }
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
          routerActivity: routerActivity(),
          now: now
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
      // Close an elapsed verification window before reading this tick's
      // mismatch flag, so a mismatch that arrives after a clean window is a
      // fresh event rather than a failure of the previous rebuild.
      if var recovery = geometryRecoveryByRuntimeID[appID],
        case .recovered = recovery.advance(to: now)
      {
        geometryRecoveryByRuntimeID[appID] = recovery
      }
      if controller.consumeGeometryMismatch() {
        var recovery = geometryRecoveryByRuntimeID[appID] ?? GeometryRecoveryCoordinator()
        let action = recovery.signalMismatch(at: now)
        geometryRecoveryByRuntimeID[appID] = recovery
        if let index = appIndexMap[appID] ?? snapshot.apps.firstIndex(where: { $0.id == appID }) {
          switch action {
          case .exhausted:
            // The rebuilt route keeps mismatching. Its tap mutes the app while
            // the callback renders silence, so keeping it alive would leave the
            // app inaudible; release it and report the failure instead.
            releaseRoute(runtimeID: appID)
            markRouteError(
              at: index,
              error: BackendError.managedRouteUnavailable(recovery.exhaustedDetail)
            )
            snapshot.apps[index].routeHealthContext = .geometryRecoveryExhausted
            snapshot.apps[index].appliedVolume = nil
            snapshot.apps[index].peakLevel = 0
            snapshot.apps[index].rmsLevel = 0
            refreshGlobalRouteHealth(latestError: recovery.exhaustedDetail)
            snapshot.updatedAt = .now
            continue
          case .scheduleRecovery, .none, .attempt, .verifying, .recovered:
            snapshot.apps[index].routeHealthContext = .geometryRecoveryInProgress
            snapshot.apps[index].notes = "Audio geometry changed. Waves is rebuilding this route asynchronously."
            snapshot.updatedAt = .now
          }
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
        routerActivity: routerActivity(),
        now: now
      )
    }
  }

  func addRouterObservationListeners() -> [CleanupDegradation] {
    guard !isShuttingDown else { return [] }
    let mailbox = routerObservationMailbox
    if routerObservationTask == nil {
      routerObservationTask = Task { [weak self, mailbox] in
        for await _ in mailbox.wakeups {
          guard !Task.isCancelled else { break }
          if mailbox.takePending().contains(.routerObservation) {
            await self?.markRouterObservationDirty()
          }
          await Task.yield()
        }
      }
    }
    let degradations = routerObservationListeners.install {
      mailbox.enqueue(.routerObservation)
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

  /// `now` is the same clock the level tick used for its debouncers and
  /// recovery decisions, so a rebuild's verification window is measured on
  /// the tick clock rather than a second, unrelated one.
  func performRouteMaintenance(
    forceRebuildIDs: Set<String> = [],
    geometryRecoveryIDs: Set<String> = [],
    routerActivity: VerifiedRouterActivitySnapshot? = nil,
    now: Duration
  ) async {
    if let routeMaintenanceOverride {
      await routeMaintenanceOverride(forceRebuildIDs, geometryRecoveryIDs)
      return
    }
    await maintainManagedRoutes(
      forceRebuildIDs: forceRebuildIDs,
      geometryRecoveryIDs: geometryRecoveryIDs,
      routerActivity: routerActivity,
      now: now
    )
  }

  func markRouterObservationDirty() {
    routerObservationGeneration &+= 1
  }

  private func maintainManagedRoutes(
    forceRebuildIDs: Set<String> = [],
    geometryRecoveryIDs: Set<String> = [],
    routerActivity: VerifiedRouterActivitySnapshot? = nil,
    now: Duration
  ) async {
    guard !isShuttingDown else { return }
    // Authorization is captured per route at selection, as in
    // `reattachRoutes`: an app excluded or yielded while an earlier route in
    // this pass was suspended must not be rebuilt from its changed row.
    let selected = snapshot.apps
      .filter { $0.routingState == .managed || forceRebuildIDs.contains($0.logicalID) || forceRebuildIDs.contains($0.id) }
      .map { (appID: $0.logicalID, context: makeRepairContext(for: $0)) }
    guard !selected.isEmpty else { return }

    var changed = false
    var lastError: String?

    for (appID, repairContext) in selected {
      guard !isShuttingDown else { return }
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
        continue
      }

      let app = snapshot.apps[index]
      let shouldForceRebuild = forceRebuildIDs.contains(app.logicalID) || forceRebuildIDs.contains(app.id)
      // A live route bound to a device it should no longer play on, such as
      // the old default after a move that newer work overtook, is moved here.
      let isMisbound = controllers[app.id] != nil && !isRouteOnItsExpectedDevice(app)

      do {
        // Overtaken while an earlier route in this pass was suspended.
        guard isRepairCurrent(repairContext) else { throw IntentSupersededError() }
        let processTarget = try resolveProcessTarget(for: app)
        let processObjectIDs = processTarget.processObjectIDs
        if !shouldForceRebuild,
          !isMisbound,
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
          forceRebuild: shouldForceRebuild || isMisbound,
          repairContext: repairContext,
          preservesGeometryRecovery: geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          origin: .automatic,
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
          _ = recovery.finishRecovery(succeeded: true, at: now)
          geometryRecoveryByRuntimeID[app.id] = recovery
        }
        changed = true
      } catch is IntentSupersededError {
        // A user edit, an exclusion, or an output change overtook this repair
        // while it was suspended. It proved nothing about the route, so a
        // geometry attempt is handed back rather than counted.
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          _ = recovery.abandonRecovery(at: now)
          geometryRecoveryByRuntimeID[app.id] = recovery
        }
        continue
      } catch is IntentBackendStoppedError {
        return
      } catch {
        if isMisbound {
          // Same policy as a failed move on a default-output change: release
          // the route so the app is audible, and say why.
          releaseRoute(runtimeID: app.id)
          let reported = failedMoveError(for: app, error)
          if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
            markRouteError(at: currentIndex, error: reported)
            snapshot.apps[currentIndex].appliedVolume = nil
            snapshot.apps[currentIndex].peakLevel = 0
            snapshot.apps[currentIndex].rmsLevel = 0
          }
          lastError = reported.localizedDescription
          changed = true
          continue
        }
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          let action = recovery.finishRecovery(succeeded: false, at: now)
          geometryRecoveryByRuntimeID[app.id] = recovery
          if case .exhausted = action {
            let exhaustion = BackendError.managedRouteUnavailable(recovery.exhaustedDetail)
            // Same outcome as a mismatch that exhausts on the level tick: the
            // controller that kept mismatching mutes the app while rendering
            // silence, so release it (the app is audible again) and drop the
            // spent coordinator so the next controller starts with a full one.
            releaseRoute(runtimeID: app.id)
            if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
              markRouteError(at: currentIndex, error: exhaustion)
              snapshot.apps[currentIndex].routeHealthContext = .geometryRecoveryExhausted
              snapshot.apps[currentIndex].appliedVolume = nil
              snapshot.apps[currentIndex].peakLevel = 0
              snapshot.apps[currentIndex].rmsLevel = 0
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
    Self.monotonicRouteTime()
  }

  @Sendable static func monotonicRouteTime() -> Duration {
    .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
  }

  /// Gate for every native controller creation attempt. User-initiated work is
  /// counted and always allowed; automatic work is refused while the
  /// backend-wide ceiling is active (see `RouteRebuildBudget`).
  func spendRouteRebuildBudget(_ origin: RouteWorkOrigin) throws {
    guard
      routeRebuildBudget.request(
        origin,
        liveRouteCount: controllers.count,
        at: routeBudgetClock()
      )
    else { throw RouteRebuildCeilingError() }
  }

  var routeRebuildBudgetSummary: String {
    routeRebuildBudget.diagnosticsSummary(liveRouteCount: controllers.count, at: routeBudgetClock())
  }

  var isRouteRebuildCeilingActive: Bool {
    routeRebuildBudget.isCeilingActive(liveRouteCount: controllers.count, at: routeBudgetClock())
  }
}

/// Automatic route work was refused by the backend-wide rebuild ceiling.
struct RouteRebuildCeilingError: LocalizedError {
  var errorDescription: String? {
    "Waves paused automatic audio route rebuilds because too many happened in a short time. Use Recover Routes to try again now."
  }
}
