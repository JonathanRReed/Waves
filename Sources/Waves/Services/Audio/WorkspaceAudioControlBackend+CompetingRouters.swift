import Foundation
import WavesAudioCore

// MARK: - Competing-router arbitration and the Wave Link bridge
//
// While a verified audio router (Wave Link) owns output, Waves must never
// create a second renderer for an ordinary app. These members decide when a
// route yields, when the Wave Link bridge may control the app instead, and how
// suspended routes are presented and released. See
// docs/superpowers/specs/2026-08-25-wave-link-controller-design.md.

extension WorkspaceAudioControlBackend {
  func shouldControlThroughWaveLink(
    _ app: AudioApp,
    conflict: VerifiedRouterConflict
  ) -> Bool {
    waveLinkCompatibilityEnabled
      && perAppAudioController == .waves
      && waveLinkController != nil
      && conflict.supportsBridgeControl
      && app.bundleID?.isEmpty == false
      && conflict.kind != .routerMixedOutput
  }

  func applyIntentThroughWaveLink(
    _ intent: AppRouteIntent,
    logicalID: String,
    acceptedIndex: Int,
    conflict: VerifiedRouterConflict
  ) async -> AppIntentApplyResult {
    let previousApp = snapshot.apps[acceptedIndex]
    suspendManagedRouteForConflict(at: acceptedIndex, conflict: conflict)
    snapshot.apps[acceptedIndex].routeHealthContext = .waveLinkBridge
    snapshot.apps[acceptedIndex].notes =
      "Waves is controlling this app through Wave Link without creating a second audio route."

    let generationContext = IntentGenerationContext(
      logicalID: logicalID,
      generation: intent.generation,
      lifecycleEpoch: lifecycleEpoch
    )

    // Wave Link's channel protocol carries only volume and mute. A change that
    // is purely boost, equalizer, or output routing must be refused honestly
    // instead of reported as applied.
    let dspChangeRequested =
      intent.volumeBoost != previousApp.volumeBoost
      || intent.targetDeviceUID != previousApp.targetDeviceUID
    let audioChangeRequested =
      intent.desiredVolume != previousApp.desiredVolume
      || intent.isMuted != previousApp.isMuted
    if dspChangeRequested, !audioChangeRequested {
      snapshot.apps[acceptedIndex].notes =
        "Boost, equalizer, and output routing are unavailable while Wave Link owns this app's audio. Adjust them in Wave Link, or disable Wave Link compatibility in Settings."
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unavailable,
        resultingApp: snapshot.apps[acceptedIndex],
        backendStatus: snapshot.backendStatus,
        detail: snapshot.apps[acceptedIndex].notes
      )
    }

    do {
      guard let bundleIdentifier = previousApp.bundleID, let waveLinkController else {
        throw WaveLinkControlBridgeError.invalidBundleIdentifier
      }

      // Bridge applies are strictly serialized. Concurrent sequences on the
      // shared control socket can consume each other's replies, and a stale
      // write finishing after a newer one would desynchronize Wave Link from
      // the state Waves reports.
      let previousApply = waveLinkApplyQueueTail
      let (applyFinished, applyFinishedContinuation) = AsyncStream<Void>.makeStream()
      waveLinkApplyQueueTail = Task { for await _ in applyFinished {} }
      defer { applyFinishedContinuation.finish() }
      if let previousApply {
        await previousApply.value
      }

      try ensureGenerationCurrent(generationContext)
      let confirmation = try await waveLinkController.apply(
        bundleIdentifier: bundleIdentifier,
        volume: intent.desiredVolume,
        isMuted: intent.isMuted
      )
      try ensureGenerationCurrent(generationContext)

      guard let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) else {
        clearStagedIntentIfCurrent(intent, logicalID: logicalID)
        return AppIntentApplyResult(
          appID: intent.appID,
          generation: intent.generation,
          outcome: .unavailable,
          resultingApp: nil,
          backendStatus: snapshot.backendStatus,
          detail: "The app left the current audio session before Wave Link confirmed the change."
        )
      }

      snapshot.apps[currentIndex].desiredVolume = intent.desiredVolume
      snapshot.apps[currentIndex].isMuted = intent.isMuted
      snapshot.apps[currentIndex].appliedVolume = intent.isMuted ? 0 : confirmation.appliedVolume
      snapshot.apps[currentIndex].routingState = .monitorOnly
      snapshot.apps[currentIndex].hasNoAudioCapability = false
      snapshot.apps[currentIndex].routeHealthContext = .waveLinkBridge
      snapshot.apps[currentIndex].notes =
        "Controlled through Wave Link channel \(confirmation.channelName). Boost, equalizer, and output routing are paused while Wave Link owns audio."
      if intent.isMuted {
        snapshot.apps[currentIndex].peakLevel = 0
        snapshot.apps[currentIndex].rmsLevel = 0
      }
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth()
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .applied,
        resultingApp: snapshot.apps[currentIndex],
        backendStatus: snapshot.backendStatus,
        detail: snapshot.apps[currentIndex].notes
      )
    } catch is IntentSupersededError {
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      return supersededResult(for: intent, logicalID: logicalID)
    } catch is IntentBackendStoppedError {
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: snapshot.apps.first(where: { $0.logicalID == logicalID }),
        backendStatus: snapshot.backendStatus,
        detail: "The audio backend stopped before Wave Link confirmed the intent."
      )
    } catch {
      guard isGenerationCurrent(generationContext) else {
        clearStagedIntentIfCurrent(intent, logicalID: logicalID)
        return supersededResult(for: intent, logicalID: logicalID)
      }
      if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
        snapshot.apps[currentIndex].desiredVolume = previousApp.desiredVolume
        snapshot.apps[currentIndex].isMuted = previousApp.isMuted
        snapshot.apps[currentIndex].appliedVolume = nil
        snapshot.apps[currentIndex].routingState = .monitorOnly
        snapshot.apps[currentIndex].routeHealthContext = .waveLinkBridge
        snapshot.apps[currentIndex].notes = error.localizedDescription
      }
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth(latestError: error.localizedDescription)
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: snapshot.apps.first(where: { $0.logicalID == logicalID }),
        backendStatus: snapshot.backendStatus,
        detail: error.localizedDescription
      )
    }
  }

  func setPerAppAudioController(_ controller: PerAppAudioController) async {
    guard perAppAudioController != controller else { return }
    perAppAudioController = controller
    refreshCompetingRouterControlPresentation()
    markRouterObservationDirty()
  }

  func setWaveLinkCompatibilityEnabled(_ isEnabled: Bool) async {
    guard waveLinkCompatibilityEnabled != isEnabled else { return }
    waveLinkCompatibilityEnabled = isEnabled
    if isEnabled { refreshCompetingRouterControlPresentation() }
    markRouterObservationDirty()
  }

  func refreshCompetingRouterControlPresentation() {
    let routerActivity = verifiedRouterActivityProvider?()
    var changed = false
    for index in snapshot.apps.indices {
      // Restamp only rows the route machinery already owns: managed routes,
      // live controllers, and rows previously suspended for a router conflict.
      // Stamping a router context on an untouched or excluded row would later
      // let conflict release or route recovery promote it to a managed tap the
      // user never asked for.
      let app = snapshot.apps[index]
      guard
        Self.isRouteRecoveryCandidate(
          app,
          hasActiveController: controllers[app.id]?.isActive == true,
          reclaimMixedOutput: true
        )
      else { continue }
      guard
        let conflict = competingAudioRouterConflict(
          for: app,
          routerActivity: routerActivity
        )
      else { continue }
      suspendManagedRouteForConflict(at: index, conflict: conflict)
      changed = true
    }
    if changed {
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth()
    }
  }

  func competingAudioRouterConflict(
    for app: AudioApp,
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) -> VerifiedRouterConflict? {
    let conflict: VerifiedRouterConflict?
    if let routerActivity {
      conflict = routerActivity.conflict(for: app)
    } else {
      conflict = verifiedRouterConflictProvider?(app)
    }
    return CompetingRouterPolicy.conflict(
      for: app,
      verifiedConflict: conflict,
      controller: perAppAudioController,
      compatibilityEnabled: waveLinkCompatibilityEnabled
    )
  }

  func suspendManagedRouteForConflict(at index: Int, conflict: VerifiedRouterConflict) {
    let app = snapshot.apps[index]
    if let controller = controllers.removeValue(forKey: app.id) {
      retainCleanupDegradations(disposeController(controller))
    }
    controllerGenerationByRuntimeID.removeValue(forKey: app.id)
    staleRouteTicks.removeValue(forKey: app.logicalID)
    lastRenderTickByAppID.removeValue(forKey: app.logicalID)
    snapshot.apps[index].routingState = .monitorOnly
    snapshot.apps[index].appliedVolume = nil
    snapshot.apps[index].peakLevel = 0
    snapshot.apps[index].rmsLevel = 0
    snapshot.apps[index].notes = conflict.detail
    if shouldControlThroughWaveLink(app, conflict: conflict) {
      snapshot.apps[index].routeHealthContext = .waveLinkBridge
      snapshot.apps[index].notes =
        "Waves can control this app through Wave Link without creating a second audio route."
    } else {
      snapshot.apps[index].routeHealthContext =
        switch conflict.kind {
        case .publicTapMembership: .verifiedRouterOwnership
        case .unattributableTapFallback: .unattributableRouterFallback
        case .routerMixedOutput: .routerMixedOutput
        }
    }
  }

  func observeCompetingRouterConflicts(
    at now: Duration,
    routerActivity: VerifiedRouterActivitySnapshot?
  ) -> Set<String> {
    var recoveredRouteIDs = Set<String>()
    var changed = false
    for index in snapshot.apps.indices {
      let app = snapshot.apps[index]
      let conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity)
      var observation = routerConflictObservationByRuntimeID[app.id] ?? RouterConflictObservationDebouncer()
      let action: RouterConflictObservationAction
      if routerObservationGeneration != consumedRouterObservationGeneration {
        action = observation.observe(conflictIsActive: conflict != nil, at: now)
      } else {
        action = observation.advance(to: now)
      }
      routerConflictObservationByRuntimeID[app.id] = observation

      switch action {
      case .conflictActivated:
        guard app.routingState == .managed || controllers[app.id] != nil,
          let conflict
        else { continue }
        suspendManagedRouteForConflict(at: index, conflict: conflict)
        changed = true
      case .conflictReleased:
        guard snapshot.apps[index].routingState == .monitorOnly else { continue }
        switch snapshot.apps[index].routeHealthContext {
        case .verifiedRouterOwnership, .unattributableRouterFallback, .routerMixedOutput,
          .waveLinkBridge:
          break
        default:
          continue
        }
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].notes = nil
        snapshot.apps[index].routeHealthContext = nil
        recoveredRouteIDs.insert(snapshot.apps[index].logicalID)
        changed = true
      case .none:
        break
      }
    }
    consumedRouterObservationGeneration = routerObservationGeneration
    if changed { snapshot.updatedAt = .now }
    return recoveredRouteIDs
  }
}
