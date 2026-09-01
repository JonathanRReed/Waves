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
      "Sending this change to Wave Link…"

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
        "Boost, EQ, and output routing stay in Wave Link while it owns this app's audio. Change them there, or turn off Wave Link compatibility in Settings › Mixer."
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
      // Only a person's own gesture may re-route an app inside Wave Link.
      // Automation (conferencing auto-pause) can mute an app that already has
      // its own channel, and is refused honestly otherwise.
      let confirmation = try await waveLinkController.apply(
        bundleIdentifier: bundleIdentifier,
        volume: intent.desiredVolume,
        isMuted: intent.isMuted,
        allowsChannelRelocation: intent.reason != .automation
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

      if let reclaimed = reclaimedRouteResultSupersedingBridgeApply(
        intent,
        logicalID: logicalID,
        currentIndex: currentIndex
      ) {
        return reclaimed
      }

      snapshot.apps[currentIndex].desiredVolume = intent.desiredVolume
      snapshot.apps[currentIndex].isMuted = intent.isMuted
      snapshot.apps[currentIndex].appliedVolume = intent.isMuted ? 0 : confirmation.appliedVolume
      snapshot.apps[currentIndex].routingState = .monitorOnly
      snapshot.apps[currentIndex].hasNoAudioCapability = false
      snapshot.apps[currentIndex].routeHealthContext = .waveLinkBridge
      snapshot.apps[currentIndex].notes =
        confirmation.relocated
        ? "Moved to Wave Link channel \(confirmation.channelName) so it can have its own level. Boost, EQ, and output routing stay in Wave Link."
        : "Volume and mute go through Wave Link channel \(confirmation.channelName). Boost, EQ, and output routing stay in Wave Link."
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
        if let reclaimed = reclaimedRouteResultSupersedingBridgeApply(
          intent,
          logicalID: logicalID,
          currentIndex: currentIndex
        ) {
          return reclaimed
        }
        snapshot.apps[currentIndex].desiredVolume = previousApp.desiredVolume
        snapshot.apps[currentIndex].isMuted = previousApp.isMuted
        snapshot.apps[currentIndex].appliedVolume = nil
        snapshot.apps[currentIndex].routingState = .monitorOnly
        snapshot.apps[currentIndex].routeHealthContext = .waveLinkBridge
        snapshot.apps[currentIndex].notes = Self.waveLinkFailureNote(error, app: previousApp)
      }
      let detail = Self.waveLinkFailureNote(error, app: previousApp)
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth(latestError: detail)
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: snapshot.apps.first(where: { $0.logicalID == logicalID }),
        backendStatus: snapshot.backendStatus,
        detail: detail
      )
    }
  }

  /// The row note for a failed bridge apply. Channel-layout problems name the
  /// app the way the user knows it rather than by bundle identifier.
  static func waveLinkFailureNote(_ error: Error, app: AudioApp) -> String {
    switch error as? WaveLinkControlBridgeError {
    case .dedicatedChannelRequired:
      return
        "Every Wave Link software channel already holds an app, so \(app.displayName) cannot get its own level. Free up an empty software channel in Wave Link, or give \(app.displayName) one of its own, then try again."
    case .relocationNotPermitted:
      return
        "\(app.displayName) shares a Wave Link channel with other apps, so Waves left it alone. Move it to its own Wave Link channel, or change its level here yourself, to control it from Waves."
    default:
      return error.localizedDescription
    }
  }

  func waveLinkBridgeStatus() async -> WaveLinkBridgeStatus? {
    guard let waveLinkController else { return nil }
    return await waveLinkController.currentStatus()
  }

  func probeWaveLinkBridge() async -> WaveLinkBridgeStatus? {
    guard let waveLinkController else { return nil }
    return await waveLinkController.inspect()
  }

  /// Resolves the race where the verified router quits while a bridge apply is
  /// suspended awaiting Wave Link: conflict release can promote the row back to
  /// `.managed` and recreate a Waves tap before the bridge call returns.
  ///
  /// The reclaimed tap is the newer ownership decision, so the stale bridge
  /// result yields to it — overwriting the row with a bridge label here would
  /// leave a live tap rendering under a row that claims Wave Link owns it. If
  /// a live tap coexists with a *still-active* conflict instead, the tap is the
  /// intruder and yields exactly like any conflicted route.
  private func reclaimedRouteResultSupersedingBridgeApply(
    _ intent: AppRouteIntent,
    logicalID: String,
    currentIndex: Int
  ) -> AppIntentApplyResult? {
    let app = snapshot.apps[currentIndex]
    guard controllers[app.id]?.isActive == true else { return nil }
    if let conflict = competingAudioRouterConflict(
      for: app,
      routerActivity: verifiedRouterActivityProvider?()
    ) {
      suspendManagedRouteForConflict(at: currentIndex, conflict: conflict)
      snapshot.updatedAt = .now
      return nil
    }
    clearStagedIntentIfCurrent(intent, logicalID: logicalID)
    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: .superseded,
      resultingApp: snapshot.apps[currentIndex],
      backendStatus: snapshot.backendStatus,
      detail: "The router released this route while Wave Link was confirming the change, so Waves reclaimed the app with its own route."
    )
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
        "Wave Link is mixing this app. Volume and mute from Waves go through its Wave Link channel; boost, EQ, and output routing stay in Wave Link."
    } else {
      snapshot.apps[index].routeHealthContext =
        switch conflict.kind {
        case .publicTapMembership: .verifiedRouterOwnership
        case .unattributableTapFallback: .unattributableRouterFallback
        case .routerMixedOutput: .routerMixedOutput
        }
    }
  }

  /// `routerActivity` is evaluated only when a conflict verdict is actually
  /// needed: on a re-observation tick, or when a debounced activation lands.
  /// Quiet ticks advance the debouncers without touching Core Audio or
  /// Security at all.
  func observeCompetingRouterConflicts(
    at now: Duration,
    routerActivity: () -> VerifiedRouterActivitySnapshot?
  ) -> Set<String> {
    var recoveredRouteIDs = Set<String>()
    var changed = false
    let reobserve = routerObservationGeneration != consumedRouterObservationGeneration
    for index in snapshot.apps.indices {
      let app = snapshot.apps[index]
      var observation = routerConflictObservationByRuntimeID[app.id] ?? RouterConflictObservationDebouncer()
      var conflict: VerifiedRouterConflict?
      var evaluatedConflict = false
      let action: RouterConflictObservationAction
      if reobserve {
        conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity())
        evaluatedConflict = true
        action = observation.observe(conflictIsActive: conflict != nil, at: now)
      } else {
        action = observation.advance(to: now)
      }
      routerConflictObservationByRuntimeID[app.id] = observation

      switch action {
      case .conflictActivated:
        guard app.routingState == .managed || controllers[app.id] != nil else { continue }
        if !evaluatedConflict {
          conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity())
        }
        guard let conflict else { continue }
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
    // Debouncers are keyed by runtime ID, which changes every time an app
    // relaunches. Drop the ones whose app is gone so the table tracks the live
    // session instead of accumulating one entry per launch for the process.
    if routerConflictObservationByRuntimeID.count > snapshot.apps.count {
      let liveRuntimeIDs = Set(snapshot.apps.map(\.id))
      routerConflictObservationByRuntimeID = routerConflictObservationByRuntimeID.filter {
        liveRuntimeIDs.contains($0.key)
      }
    }
    if changed { snapshot.updatedAt = .now }
    return recoveredRouteIDs
  }
}
