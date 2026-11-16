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
    for (offset, repairContext) in targets.enumerated() {
      // Between routes, never inside one handoff: a handoff may block the
      // actor for up to `handoffSilenceMaxPolls` pauses, and a batch of them
      // must not hold off a user's edit for the whole batch.
      if offset > 0 { await Task.yield() }
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
      } catch let error as HandoffSilenceUnconfirmedError where controllers[app.id]?.isActive == true {
        // The incumbent still plays the app at its level. A move it did not
        // make is left pending, and maintenance retries it.
        if mode == .rehome { recordPendingRepair(.wrongDevice, runtimeID: app.id) }
        publishRouteHolds()
        lastError = error.localizedDescription
      } catch {
        var reported = error
        if mode == .rehome {
          reported = failedMoveError(for: app, error)
          releaseUnrepairedRoute(logicalID: logicalID, runtimeID: app.id, error: reported)
        } else if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          markRouteError(at: index, error: reported)
          // A retry spent from a fail-open record keeps the newest reason.
          failOpenReleases[logicalID]?.adoptExplanation(of: snapshot.apps[index])
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

  /// What a route that was known not to work, and could not be rebuilt,
  /// reports once it has been released.
  func failedRepairError(for app: AudioApp, _ error: Error) -> Error {
    switch error {
    case BackendError.noActiveAudioStream, BackendError.noAudioCapability:
      return error
    default:
      return BackendError.managedRouteUnavailable(
        "Waves couldn't rebuild the audio route for \(app.displayName), so it now plays at its own volume. \(error.localizedDescription)"
      )
    }
  }

  /// Releases a route that automatic repair could not rebuild: fail open, so
  /// the app plays at its own level, and the row says why. The explanation
  /// survives refreshes, and the repair is retried under the authorization
  /// the app has now (see `FailOpenRelease`). A route whose tap would not
  /// let the app go keeps playing it at the user's level instead, and says so.
  func releaseUnrepairedRoute(logicalID: String, runtimeID: String, error: Error) {
    guard releaseRoute(runtimeID: runtimeID, reason: error.localizedDescription) == .released else { return }
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID || $0.id == runtimeID }) else {
      return
    }
    markRouteError(at: index, error: error)
    snapshot.apps[index].appliedVolume = nil
    snapshot.apps[index].peakLevel = 0
    snapshot.apps[index].rmsLevel = 0
    let app = snapshot.apps[index]
    failOpenReleases[app.logicalID] = FailOpenRelease(
      context: makeRepairContext(for: app),
      routingState: app.routingState,
      notes: app.notes,
      hasNoAudioCapability: app.hasNoAudioCapability,
      attemptsRemaining: FailOpenRelease.maximumAttempts
    )
    publishRouteHolds()
  }

  /// Puts back what a refresh would otherwise lose: why an app has no route,
  /// or why the route it has is not the one Waves meant to leave.
  /// - A live route a managed release could not hand back says so.
  /// - A row a parked tap holds silent says so.
  /// - A row released by a failed repair keeps its explanation, and its
  ///   applied level stays unknown, until a route is installed or the user
  ///   changes something.
  /// Any other live route explains itself, so its row is left alone.
  func applyStickyRouteNotes(to apps: inout [AudioApp]) {
    let held = heldSilentRuntimeIDs(in: apps)
    appsHeldSilentByParkedTaps = held
    for index in apps.indices {
      let wasHeld = apps[index].isHeldSilentByWaves
      apps[index].isHeldSilentByWaves = held.contains(apps[index].id)
      if wasHeld, !apps[index].isHeldSilentByWaves, apps[index].notes == Self.heldSilentNote(for: apps[index]) {
        // No longer held: the app plays at its own level again.
        apps[index].notes = nil
        if apps[index].routeHealthContext == nil, apps[index].routingState == .error {
          apps[index].routingState = .monitorOnly
        }
      }
      let app = apps[index]
      // An identity collision explains the row; nothing recorded for an
      // earlier process may replace that.
      if app.hasAmbiguousIdentity { continue }
      if let controller = controllers[app.id], controller.isActive {
        if let unreleased = unreleasedRoutes[app.id], unreleased.controller == ObjectIdentifier(controller) {
          apps[index].routingState = .error
          apps[index].notes = unreleased.note
          apps[index].hasNoAudioCapability = false
          apps[index].appliedVolume = app.isMuted ? 0 : app.desiredVolume
        } else if let reason = pendingRepair(for: app.id) {
          // Still playing at the user's level, but not healthy: say what is
          // wrong and that the rebuild is still to come.
          apps[index].routingState = .error
          apps[index].notes = Self.pendingRepairNote(
            appName: app.displayName,
            reason: reason,
            rebuildsPaused: isRouteRebuildCeilingActive
          )
          apps[index].hasNoAudioCapability = false
          apps[index].appliedVolume = app.isMuted ? 0 : app.desiredVolume
        }
        continue
      }
      if app.isHeldSilentByWaves {
        apps[index].notes = Self.heldSilentNote(for: app)
        apps[index].appliedVolume = nil
        apps[index].peakLevel = 0
        apps[index].rmsLevel = 0
        // A row another router holds keeps its own state, so the router's
        // release can still hand it back; only the note changes.
        if app.routeHealthContext == nil {
          apps[index].routingState = .error
          apps[index].hasNoAudioCapability = false
        }
      } else if let release = failOpenReleases[app.logicalID], release.context.runtimeID == app.id,
        release.context.processLifetime == app.runtimeIdentity?.lifetime
      {
        apps[index].routingState = release.routingState
        apps[index].notes = release.notes
        apps[index].hasNoAudioCapability = release.hasNoAudioCapability
        apps[index].appliedVolume = nil
      }
    }
  }

  /// Retries the repairs `failOpenReleases` records. An attempt is made only
  /// when it can work: automatic rebuilds are not paused, the app's output
  /// device reports a usable format, and the app is producing audio (a paused
  /// app may have no process to tap). Runs on every maintenance pass, so each
  /// of those coming true is acted on within one pass. Bounded per release.
  func retryFailOpenReleases(routerActivity: VerifiedRouterActivitySnapshot?) async {
    var changed = false
    for logicalID in failOpenReleases.keys.sorted() {
      guard !isShuttingDown else { return }
      guard let release = failOpenReleases[logicalID] else { continue }
      guard isRepairCurrent(release.context),
        let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID })
      else {
        failOpenReleases.removeValue(forKey: logicalID)
        continue
      }
      let app = snapshot.apps[index]
      guard release.attemptsRemaining > 0, !isRouteRebuildCeilingActive,
        hasUsableOutputDevice(app), isProducingAudio(app)
      else { continue }
      if let conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity) {
        suspendManagedRouteForConflict(at: index, conflict: conflict)
        changed = true
        continue
      }
      guard consumeAutomaticAttachAttempt(for: app, isFreshEvent: false) else { continue }
      do {
        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted,
          repairContext: release.context,
          origin: .automatic,
          routerActivity: routerActivity
        )
        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          snapshot.apps[currentIndex].routingState = .managed
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
          snapshot.apps[currentIndex].notes = nil
          snapshot.apps[currentIndex].hasNoAudioCapability = false
          snapshot.apps[currentIndex].routeHealthContext = nil
        }
        changed = true
      } catch is IntentBackendStoppedError {
        return
      } catch {
        // Superseded, or failed again: the row keeps its explanation.
        continue
      }
    }
    if changed {
      refreshGlobalRouteHealth()
      snapshot.updatedAt = .now
    }
  }

  /// The one allowance every automatic attempt to attach a released route
  /// spends, whichever path makes it: the maintenance retry, or a device-list
  /// change that finds the route's pinned output available. Returns whether
  /// an attempt may run now, and counts it.
  ///
  /// The allowance (`FailOpenRelease.maximumAttempts`) is reset only by a
  /// meaningful new event about the route's destination (`isFreshEvent`:
  /// its pinned output has just appeared), by newer user intent (which ends
  /// the record), or by Recover Routes. A route with no record gets one
  /// from a fresh event, and nothing otherwise, so an unrelated device-list
  /// change never retries a route whose allowance is spent.
  func consumeAutomaticAttachAttempt(for app: AudioApp, isFreshEvent: Bool) -> Bool {
    if var release = failOpenReleases[app.logicalID], isRepairCurrent(release.context) {
      if isFreshEvent { release.attemptsRemaining = FailOpenRelease.maximumAttempts }
      guard release.attemptsRemaining > 0 else {
        failOpenReleases[app.logicalID] = release
        return false
      }
      release.attemptsRemaining -= 1
      failOpenReleases[app.logicalID] = release
      return true
    }
    failOpenReleases.removeValue(forKey: app.logicalID)
    guard isFreshEvent else { return false }
    failOpenReleases[app.logicalID] = FailOpenRelease(
      context: makeRepairContext(for: app),
      routingState: app.routingState,
      notes: app.notes,
      hasNoAudioCapability: app.hasNoAudioCapability,
      attemptsRemaining: FailOpenRelease.maximumAttempts - 1
    )
    return true
  }

  private func hasUsableOutputDevice(_ app: AudioApp) -> Bool {
    guard let deviceUID = expectedOutputDeviceUID(for: app),
      case .alive = deviceFormatObservation(uid: deviceUID)
    else { return false }
    return true
  }

  private func isProducingAudio(_ app: AudioApp) -> Bool {
    guard let processTarget = try? resolveProcessTarget(for: app) else { return false }
    var stale = StaleAudioObjectTally()
    return processTarget.processObjectIDs.contains {
      processObjectLivenessProvider?($0) ?? isProcessRunningOutput($0, stale: &stale)
    }
  }

  /// Releases an app's installed route (by default as a managed release,
  /// which leaves the app audible one way or the other) and forgets its
  /// per-route bookkeeping. A route still routing keeps its bookkeeping:
  /// it is still the app's route. `reason` is why it was released, for the
  /// row of a route that could not be.
  @discardableResult
  func releaseRoute(
    runtimeID: String,
    kind: PerAppTapController.DisposalKind = .managedRelease,
    reason: String? = nil
  ) -> RouteReleaseOutcome {
    guard releaseInstalledController(runtimeID: runtimeID, kind: kind, reason: reason) == .released else {
      return .stillRouting
    }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
    staleRouteTicks.removeValue(forKey: runtimeID)
    lastRenderTickByAppID.removeValue(forKey: runtimeID)
    geometryRecoveryByRuntimeID.removeValue(forKey: runtimeID)
    routeOutputBindingByRuntimeID.removeValue(forKey: runtimeID)
    return .released
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
        await runMaintenancePass(routerActivity: routerActivity(), now: now)
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
            guard releaseRoute(runtimeID: appID, reason: recovery.exhaustedDetail) == .released else {
              snapshot.updatedAt = .now
              continue
            }
            markRouteError(
              at: index,
              error: BackendError.managedRouteUnavailable(recovery.exhaustedDetail)
            )
            snapshot.apps[index].routeHealthContext = .geometryRecoveryExhausted
            snapshot.apps[index].appliedVolume = nil
            snapshot.apps[index].peakLevel = 0
            snapshot.apps[index].rmsLevel = 0
            publishRouteHolds()
            refreshGlobalRouteHealth(latestError: recovery.exhaustedDetail)
            snapshot.updatedAt = .now
            continue
          case .scheduleRecovery, .none, .attempt, .verifying, .recovered:
            // Only while a rebuild is really coming; spent recovery stays spent.
            guard recovery.hasPendingRecoveryWork else { break }
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
            recordPendingRepair(.stalled, runtimeID: app.id)
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
      await runMaintenancePass(routerActivity: routerActivity(), now: now)
      await performRouteMaintenance(
        forceRebuildIDs: routeIDsNeedingRebuild,
        geometryRecoveryIDs: geometryRecoveryRouteIDs,
        routerActivity: routerActivity(),
        now: now
      )
    }
  }

  /// The work every maintenance pass does besides rebuilding managed routes:
  /// parked controllers, routes released by a failed repair, and routes whose
  /// rebuild after a format change was refused by the rebuild budget (they
  /// still render, so they were kept; this rebuilds them once it allows).
  private func runMaintenancePass(routerActivity: VerifiedRouterActivitySnapshot?, now: Duration) async {
    retryParkedControllers()
    await retryFailOpenReleases(routerActivity: routerActivity)
    guard !isShuttingDown, !isRouteRebuildCeilingActive else { return }
    await revalidateRouteFormats(now: now)
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
    // A route with a pending repair is rebuilt on every pass the rebuild
    // budget allows, until a rebuild for it succeeds or it changes hands.
    // While the budget refuses, it is not attempted at all.
    let pendingIDs: Set<String> = isRouteRebuildCeilingActive ? [] : Set(snapshot.apps.map(\.id).filter { pendingRepair(for: $0) != nil })
    let forceRebuildIDs = forceRebuildIDs.union(pendingIDs)
    // Authorization is captured per route at selection, as in
    // `reattachRoutes`: an app excluded or yielded while an earlier route in
    // this pass was suspended must not be rebuilt from its changed row.
    let selected = snapshot.apps
      .filter { $0.routingState == .managed || forceRebuildIDs.contains($0.logicalID) || forceRebuildIDs.contains($0.id) }
      .map { (appID: $0.logicalID, context: makeRepairContext(for: $0)) }
    guard !selected.isEmpty else { return }
    // One verified-router view for the whole pass, as `reattachRoutes` takes.
    let routerActivity = routerActivity ?? verifiedRouterActivityProvider?()

    var changed = false
    var lastError: String?

    for (offset, (appID, repairContext)) in selected.enumerated() {
      // Between routes only; see `reattachRoutes(_:origin:mode:)`.
      if offset > 0 { await Task.yield() }
      guard !isShuttingDown else { return }
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
        continue
      }

      let app = snapshot.apps[index]
      let shouldForceRebuild = forceRebuildIDs.contains(app.logicalID) || forceRebuildIDs.contains(app.id)
      // A live route bound to a device it should no longer play on, such as
      // the old default after a move that newer work overtook, is moved here.
      let isMisbound = controllers[app.id] != nil && !isRouteOnItsExpectedDevice(app)
      if isMisbound { recordPendingRepair(.wrongDevice, runtimeID: app.id) }

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
        // Another router owns the app now: yield to it. Ownership is not a
        // failed repair, so it never takes the managed fallback below.
        if let conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity) {
          suspendManagedRouteForConflict(at: index, conflict: conflict)
          changed = true
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
      } catch is HandoffSilenceUnconfirmedError
        where controllers[app.id]?.isActive == true && !isKnownUnableToRender(app.id)
      {
        // The incumbent still plays the app; whatever this rebuild was for
        // is retried on the next pass. It proved nothing about the route.
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          _ = recovery.abandonRecovery(at: now)
          geometryRecoveryByRuntimeID[app.id] = recovery
        }
        publishRouteHolds()
        continue
      } catch {
        let isGeometryAttempt = geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id)
        // A route forced into a rebuild while it had a controller may not
        // work as built: its device's format changed or the device came back
        // after not being alive (its aggregate may be dead), it stopped
        // rendering while its app plays, its controller is inactive, or it
        // renders to the wrong device. After a rebuild that failed, keeping
        // that controller could leave its tap muting the app while nothing
        // plays. Same policy as a failed move: release it so the app is
        // audible, say why, and retry later. A rebuild the budget refused
        // proved nothing, so a route that still renders on its own device is
        // kept: its repair stays pending, its row says so, and it is rebuilt
        // once the budget allows. Geometry attempts keep their own bounded
        // retries, which end in the same release.
        if isMisbound || (shouldForceRebuild && repairContext.incumbent != nil && !isGeometryAttempt) {
          if error is RouteRebuildCeilingError, !isMisbound,
            controllers[app.id]?.isActive == true, staleRouteTicks[app.logicalID] == nil,
            pendingRepair(for: app.id) != .stalled
          {
            publishRouteHolds()
            continue
          }
          let reported = isMisbound ? failedMoveError(for: app, error) : failedRepairError(for: app, error)
          releaseUnrepairedRoute(logicalID: app.logicalID, runtimeID: app.id, error: reported)
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
            let outcome = releaseRoute(runtimeID: app.id, reason: recovery.exhaustedDetail)
            if outcome == .released,
              let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID })
            {
              markRouteError(at: currentIndex, error: exhaustion)
              snapshot.apps[currentIndex].routeHealthContext = .geometryRecoveryExhausted
              snapshot.apps[currentIndex].appliedVolume = nil
              snapshot.apps[currentIndex].peakLevel = 0
              snapshot.apps[currentIndex].rmsLevel = 0
              publishRouteHolds()
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

  /// Remembers that `runtimeID`'s live route needs rebuilding. A stalled
  /// route stays stalled: a later, milder reason must not let a refused
  /// rebuild keep a route that has stopped playing.
  func recordPendingRepair(_ reason: RouteRepairReason, runtimeID: String) {
    guard let controller = controllers[runtimeID] else { return }
    let reason = pendingRepair(for: runtimeID) == .stalled ? .stalled : reason
    pendingRouteRepairs[runtimeID] = PendingRouteRepair(reason: reason, controller: ObjectIdentifier(controller))
  }

  /// The repair `runtimeID`'s live route still needs, if any. One recorded
  /// for a controller that is no longer installed (rebuilt, released, or
  /// replaced) is forgotten: the route changed hands.
  func pendingRepair(for runtimeID: String) -> RouteRepairReason? {
    guard let pending = pendingRouteRepairs[runtimeID] else { return nil }
    guard let controller = controllers[runtimeID], ObjectIdentifier(controller) == pending.controller else {
      pendingRouteRepairs.removeValue(forKey: runtimeID)
      return nil
    }
    return pending.reason
  }

  static func pendingRepairNote(appName: String, reason: RouteRepairReason, rebuildsPaused: Bool) -> String {
    let what = "Waves needs to rebuild the audio route for \(appName) because \(reason.explanation)."
    guard rebuildsPaused else {
      return "\(what) It keeps playing at the level you set until then."
    }
    return
      "\(what) Automatic rebuilds are paused for a moment, so it keeps playing at the level you set until they resume. Recover Routes rebuilds it now."
  }
}

/// Why a live route needs rebuilding.
enum RouteRepairReason: Equatable, Sendable {
  /// Its output device changed sample rate or stream layout.
  case formatChanged
  /// Its output device disconnected and came back; its aggregate may not
  /// have survived.
  case deviceReturned
  /// It renders to a device it should no longer play on.
  case wrongDevice
  /// It stopped rendering while its app plays.
  case stalled

  var explanation: String {
    switch self {
    case .formatChanged: "its output device changed format"
    case .deviceReturned: "its output device disconnected and came back"
    case .wrongDevice: "it is playing on a device it should no longer use"
    case .stalled: "it stopped playing"
    }
  }
}

/// A repair a live route still needs. Tied to the controller it was
/// recorded for, so a rebuild, a release, or any other change of hands ends
/// it; a rebuild the budget refuses does not, so the route is rebuilt once
/// the budget allows instead of being forgotten.
struct PendingRouteRepair: Sendable {
  let reason: RouteRepairReason
  let controller: ObjectIdentifier
}

/// A handoff could not confirm that the app's other renderers were silent:
/// a callback queued ahead of the mute may still play. The replacement was
/// discarded and the incumbent kept; the move is retried later.
struct HandoffSilenceUnconfirmedError: LocalizedError {
  let appName: String
  var errorDescription: String? {
    "Waves couldn't confirm the previous audio route for \(appName) had gone quiet, so it kept that route and will try again."
  }
}

/// Automatic route work was refused by the backend-wide rebuild ceiling.
struct RouteRebuildCeilingError: LocalizedError {
  var errorDescription: String? {
    "Waves paused automatic audio route rebuilds because too many happened in a short time. Use Recover Routes to try again now."
  }
}

/// A route Waves released fail open because an automatic repair failed or was
/// refused. It keeps the row's explanation through refreshes, and authorizes
/// a bounded number of automatic retries (`retryFailOpenReleases`) under the
/// intent generation, output device and router state the app had when it was
/// released. Exclusion, a yield to another router and any newer intent end
/// it; so does a route being installed for the app, or the app going away.
struct FailOpenRelease: Sendable {
  static let maximumAttempts = 3

  let context: WorkspaceAudioControlBackend.RouteRepairContext
  private(set) var routingState: RoutingState
  private(set) var notes: String?
  private(set) var hasNoAudioCapability: Bool
  var attemptsRemaining: Int

  init(
    context: WorkspaceAudioControlBackend.RouteRepairContext,
    routingState: RoutingState,
    notes: String?,
    hasNoAudioCapability: Bool,
    attemptsRemaining: Int
  ) {
    self.context = context
    self.routingState = routingState
    self.notes = notes
    self.hasNoAudioCapability = hasNoAudioCapability
    self.attemptsRemaining = attemptsRemaining
  }

  /// Keeps the row's newest explanation after a retry that failed again.
  mutating func adoptExplanation(of app: AudioApp) {
    routingState = app.routingState
    notes = app.notes
    hasNoAudioCapability = app.hasNoAudioCapability
  }
}

/// An installed route that a managed release could not hand back: its tap's
/// mute would not release, so it was put back to the user's level and left
/// installed rather than leaving the app silent. Tied to that controller: a
/// later release, a replacement, or route work that succeeds on it ends it.
struct UnreleasedRoute: Sendable {
  let controller: ObjectIdentifier
  let note: String
}
