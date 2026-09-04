import AppKit
import Foundation
import WavesAudioCore

// MARK: - Complete app-intent transactions
//
// Every user-facing audio change flows through here as a generation-stamped
// transaction: construct the complete intent, project it optimistically, hand
// it to the coordinator, then reconcile the backend's result.

extension AppStore {
  func applyProfileEntries(
    _ profile: Profile,
    generation: UInt64,
    reason: AppRouteIntentReason
  ) async -> ProfileApplyResult {
    var rows: [ProfileRowApplyResult] = []
    rows.reserveCapacity(profile.entries.count)
    var backendStatus = session.backendStatus

    for (entryIndex, entry) in profile.entries.enumerated() {
      guard entry.hasLevels else {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .membershipOnly,
            resultingApp: nil
          )
        )
        continue
      }
      guard session.apps.contains(where: { $0.logicalID == entry.appID || $0.id == entry.appID }) else {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .unavailable,
            resultingApp: nil,
            detail: "The app is not available in the current audio session."
          )
        )
        continue
      }

      let intent = completeAppRouteIntent(
        forAppID: entry.appID,
        overrides: AppIntentOverrides(
          desiredVolume: entry.desiredVolume,
          isMuted: entry.isMuted,
          volumeBoost: entry.volumeBoost
        ),
        generation: generation,
        reason: reason
      )
      let result = await backend.applyAppIntent(intent)
      backendStatus = result.backendStatus
      rows.append(
        ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: ProfileRowApplyOutcome(appIntentOutcome: result.outcome),
          resultingApp: result.resultingApp,
          detail: result.detail
        )
      )
    }

    return ProfileApplyResult(rows: rows, backendStatus: backendStatus)
  }

  private func allocateAppIntentGeneration() -> UInt64 {
    appIntentCoordinator.allocateGeneration()
  }

  /// Reusable transaction boundary for direct controls today and profile /
  /// automation orchestration in the follow-up pass. Every request is complete,
  /// generated from confirmed runtime state plus explicit overrides.
  @discardableResult
  func applyAppIntent(
    forAppID appID: String,
    overrides: AppIntentOverrides = AppIntentOverrides(),
    reason: AppRouteIntentReason,
    persistencePolicy: AppIntentPersistencePolicy = .none,
    feedbackPolicy: AppIntentFeedbackPolicy = .none,
    optimistic: Bool = false
  ) async -> AppIntentApplyResult {
    guard requireAudioRunning() else {
      return AppIntentApplyResult(
        appID: appID,
        generation: 0,
        outcome: .failed,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: session.backendStatus,
        detail: "Finish setup before changing app audio."
      )
    }
    return await startAppIntentTransaction(
      forAppID: appID,
      overrides: overrides,
      reason: reason,
      persistencePolicy: persistencePolicy,
      feedbackPolicy: feedbackPolicy,
      optimistic: optimistic
    ).value
  }

  @discardableResult
  func startAppIntentTransaction(
    forAppID appID: String,
    overrides: AppIntentOverrides,
    reason: AppRouteIntentReason,
    persistencePolicy: AppIntentPersistencePolicy,
    feedbackPolicy: AppIntentFeedbackPolicy,
    optimistic: Bool
  ) -> Task<AppIntentApplyResult, Never> {
    guard startupState != .shuttingDown else {
      let result = AppIntentApplyResult(
        appID: appID,
        generation: 0,
        outcome: .failed,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: session.backendStatus,
        detail: "Waves is shutting down."
      )
      return Task { result }
    }
    let start = appIntentCoordinator.beginTransaction(
      appID: appID,
      sessionApp: session.apps.first(matchingAppKey: appID),
      persistedEqualizer: preferences.appAudioIntents[appID]?.equalizerSettings,
      legacyEqualizer: preferences.appEqualizerSettings[appID],
      isExcluded: preferences.excludedAppIDs.contains(appID),
      overrides: overrides,
      reason: reason,
      optimistic: optimistic
    )
    if let projection = start.projection {
      applyOptimisticProjection(projection, toAppID: appID)
    }

    let backend = backend
    let deviceIDAtSubmission = currentDeviceID
    let task = Task { @MainActor [weak self] in
      let backendResult = await backend.applyAppIntent(start.intent)
      guard let self else { return backendResult }
      defer { self.appIntentCoordinator.settleAppTask(token: start.token) }
      return await self.finishAppIntentTransaction(
        start: start,
        backendResult: backendResult,
        persistencePolicy: persistencePolicy,
        deviceIDAtSubmission: deviceIDAtSubmission,
        feedbackPolicy: feedbackPolicy
      )
    }
    appIntentCoordinator.registerAppTask(task, for: start)
    return task
  }

  func completeAppRouteIntent(
    forAppID appID: String,
    overrides: AppIntentOverrides,
    generation: UInt64,
    reason: AppRouteIntentReason
  ) -> AppRouteIntent {
    appIntentCoordinator.completeIntent(
      appID: appID,
      sessionApp: session.apps.first(matchingAppKey: appID),
      persistedEqualizer: preferences.appAudioIntents[appID]?.equalizerSettings,
      legacyEqualizer: preferences.appEqualizerSettings[appID],
      isExcluded: preferences.excludedAppIDs.contains(appID),
      overrides: overrides,
      generation: generation,
      reason: reason
    )
  }

  private func finishAppIntentTransaction(
    start: AppIntentTransactionStart,
    backendResult: AppIntentApplyResult,
    persistencePolicy: AppIntentPersistencePolicy,
    deviceIDAtSubmission: String?,
    feedbackPolicy: AppIntentFeedbackPolicy
  ) async -> AppIntentApplyResult {
    let intent = start.intent
    let appID = intent.appID
    switch appIntentCoordinator.completionDisposition(
      for: start,
      backendGeneration: backendResult.generation
    ) {
    case .stale:
      return AppIntentApplyResult(
        appID: appID,
        generation: intent.generation,
        outcome: .superseded,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: backendResult.backendStatus,
        detail: "A newer AppStore transaction superseded this result."
      )
    case .backendGenerationMismatch:
      let confirmedSnapshot = await backend.currentSnapshot()
      if appIntentCoordinator.isCurrent(intent.generation, for: appID) {
        session = mergedSession(with: confirmedSnapshot, cached: session)
        syncOnboarding(using: session)
        persistSessionSnapshot()
      }
      return AppIntentApplyResult(
        appID: appID,
        generation: intent.generation,
        outcome: .superseded,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: confirmedSnapshot.backendStatus,
        detail: "The backend returned a result for a different generation."
      )
    case .current:
      break
    }

    // A transaction that persists nothing — a slider nudge mid-drag, an
    // automation step, a startup restore row — is transient: the committing
    // transaction (or the caller's own pass) writes the session, refreshes
    // diagnostics, and re-syncs onboarding exactly once afterwards. Doing all
    // of that here too meant every 80 ms drag step rewrote session.json,
    // rebuilt the diagnostics checklist, and re-read the login item over XPC.
    let isTransient: Bool
    if case .none = persistencePolicy { isTransient = true } else { isTransient = false }

    reconcileAppIntentResult(
      backendResult,
      intent: intent,
      projectedMuteSource: start.projectedMuteSource,
      isTransient: isTransient
    )

    let persistenceResult: AcceptedIntentPersistenceResult
    if backendResult.outcome == .applied || backendResult.outcome == .noChange {
      appIntentCoordinator.recordConfirmedEqualizer(intent.equalizerSettings, for: appID)
      persistenceResult = await persistAcceptedAppIntent(
        intent,
        result: backendResult,
        policy: persistencePolicy,
        deviceIDAtSubmission: deviceIDAtSubmission
      )
    } else {
      persistenceResult = .notRequested
    }

    // Explicit diagnostics refreshes own the fresh capture probe; a control
    // change must never create a system-wide probe tap as a side effect.
    let refreshedDiagnostics =
      isTransient ? nil : await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
    let captureAuthorization = isTransient ? nil : await backend.captureAuthorizationResult()
    if appIntentCoordinator.isCurrent(intent.generation, for: appID) {
      if let refreshedDiagnostics, !Self.diagnosticsContentMatches(refreshedDiagnostics, diagnostics) {
        diagnostics = refreshedDiagnostics
      }
      if let captureAuthorization, onboarding.captureAuthorization != captureAuthorization {
        onboarding.captureAuthorization = captureAuthorization
      }
      if !isTransient {
        syncOnboarding(using: session)
      }
      presentAppIntentFeedback(
        backendResult,
        persistenceResult: persistenceResult,
        policy: feedbackPolicy
      )
      if backendResult.outcome == .applied || backendResult.outcome == .noChange,
        let acceptedApp = backendResult.resultingApp
          ?? session.apps.first(matchingAppKey: appID)
      {
        guidedMixerTourCoordinator.observe(
          .acceptedIntent(
            appID: appID,
            desiredVolume: acceptedApp.desiredVolume,
            isMuted: acceptedApp.isMuted
          )
        )
      }
    }
    return backendResult
  }

  private func reconcileAppIntentResult(
    _ result: AppIntentApplyResult,
    intent: AppRouteIntent,
    projectedMuteSource: MuteSource?,
    isTransient: Bool = false
  ) {
    let mutation = appIntentCoordinator.reconcileRuntime(
      result,
      intent: intent,
      projectedMuteSource: projectedMuteSource,
      cachedApp: session.apps.first(matchingAppKey: intent.appID),
      pinnedAppIDs: Set(preferences.pinnedAppIDs),
      excludedAppIDs: Set(preferences.excludedAppIDs)
    )
    session.backendStatus = mutation.backendStatus
    if var resultingApp = mutation.resultingApp {
      if mutation.shouldPresentAsExcluded {
        makeExcludedPresentation(&resultingApp)
      }
      if let index = session.apps.firstIndex(matchingAppKey: intent.appID) {
        session.apps[index] = resultingApp
      } else {
        session.apps.append(resultingApp)
      }
    } else if let removedAppID = mutation.removedAppID {
      session.apps.removeAll { $0.logicalID == removedAppID || $0.id == removedAppID }
    }
    applyPendingVolumeProjection(forAppID: intent.appID)
    guard !isTransient else { return }
    syncOnboarding(using: session)
    persistSessionSnapshot()
  }

  private func applyOptimisticProjection(
    _ projection: AppIntentProjection,
    toAppID appID: String
  ) {
    guard let index = session.apps.firstIndex(matchingAppKey: appID) else { return }
    if projection.intent.isExcluded {
      makeExcludedPresentation(&session.apps[index])
    } else {
      session.apps[index].desiredVolume = projection.intent.desiredVolume
      session.apps[index].isMuted = projection.intent.isMuted
      session.apps[index].volumeBoost = projection.intent.volumeBoost
      session.apps[index].targetDeviceUID = projection.intent.targetDeviceUID
      session.apps[index].muteSource = projection.muteSource ?? session.apps[index].muteSource
      if session.apps[index].routingState == .managed {
        session.apps[index].appliedVolume =
          projection.intent.isMuted
          ? 0
          : projection.intent.desiredVolume
      }
    }
  }

  private func applyPendingVolumeProjection(forAppID appID: String) {
    guard let target = appIntentCoordinator.pendingVolume(for: appID),
      let index = session.apps.firstIndex(matchingAppKey: appID),
      !preferences.excludedAppIDs.contains(appID)
    else { return }
    session.apps[index].desiredVolume = target
    if session.apps[index].routingState == .managed {
      session.apps[index].appliedVolume = session.apps[index].isMuted ? 0 : target
    }
  }

  func makeExcludedPresentation(_ app: inout AudioApp) {
    app.desiredVolume = 1
    app.appliedVolume = nil
    app.isMuted = false
    app.volumeBoost = 1
    app.muteSource = .user
    app.targetDeviceUID = nil
    app.routingState = .monitorOnly
    app.peakLevel = 0
    app.rmsLevel = 0
    app.notes = nil
  }

  private func persistAcceptedAppIntent(
    _ intent: AppRouteIntent,
    result: AppIntentApplyResult,
    policy: AppIntentPersistencePolicy,
    deviceIDAtSubmission: String?
  ) async -> AcceptedIntentPersistenceResult {
    guard case let .acceptedUserIntent(updateDevicePreset) = policy else {
      return .notRequested
    }

    let appID = intent.appID
    let acceptedApp = result.resultingApp
    let durableIntent = PersistedAppAudioIntent(
      appID: appID,
      desiredVolume: acceptedApp?.desiredVolume ?? intent.desiredVolume,
      isMuted: acceptedApp?.isMuted ?? intent.isMuted,
      volumeBoost: acceptedApp?.volumeBoost ?? intent.volumeBoost,
      equalizerSettings: intent.equalizerSettings,
      targetDeviceUID: acceptedApp?.targetDeviceUID ?? intent.targetDeviceUID
    )
    appIntentCoordinator.claimDurableMutation(for: appID, generation: intent.generation)
    preferences.appAudioIntents[appID] = durableIntent
    preferences.appEqualizerSettings[appID] = durableIntent.equalizerSettings
    do {
      try await savePreferencesDurably()
    } catch {
      if appIntentCoordinator.ownsDurableMutation(for: appID, generation: intent.generation) {
        if let savedIntent = durablySavedPreferences.appAudioIntents[appID] {
          preferences.appAudioIntents[appID] = savedIntent
        } else {
          preferences.appAudioIntents.removeValue(forKey: appID)
        }
        if let savedEqualizer = durablySavedPreferences.appEqualizerSettings[appID] {
          preferences.appEqualizerSettings[appID] = savedEqualizer
        } else {
          preferences.appEqualizerSettings.removeValue(forKey: appID)
        }
        appIntentCoordinator.releaseDurableMutation(for: appID, generation: intent.generation)
      }
      reportPersistenceFailure(store: .preferences, error: error, showWarning: false)
      return .settingsFailed(error.localizedDescription)
    }
    guard appIntentCoordinator.ownsDurableMutation(for: appID, generation: intent.generation) else {
      // A newer accepted transaction now owns durable and preset persistence.
      return .saved
    }
    appIntentCoordinator.releaseDurableMutation(for: appID, generation: intent.generation)

    guard updateDevicePreset,
      preferences.enablePerDeviceVolumePresets,
      let deviceID = deviceIDAtSubmission
    else {
      return .saved
    }

    let mutationKey = "\(deviceID)\u{0}\(appID)"
    appIntentCoordinator.claimDevicePresetMutation(
      key: mutationKey,
      generation: intent.generation
    )
    deviceVolumePresets.saveVolumeSettings(
      for: appID,
      deviceID: deviceID,
      settings: AppVolumeSettings(
        desiredVolume: durableIntent.desiredVolume,
        isMuted: durableIntent.isMuted,
        volumeBoost: durableIntent.volumeBoost
      )
    )
    do {
      try await saveDeviceVolumePresetsDurably()
    } catch {
      if appIntentCoordinator.ownsDevicePresetMutation(
        key: mutationKey,
        generation: intent.generation
      ) {
        if let savedPreset =
          durablySavedDeviceVolumePresets
          .getVolumeSettings(for: appID, deviceID: deviceID)
        {
          deviceVolumePresets.saveVolumeSettings(
            for: appID,
            deviceID: deviceID,
            settings: savedPreset
          )
        } else {
          deviceVolumePresets.deviceVolumes[deviceID]?.removeValue(forKey: appID)
          if deviceVolumePresets.deviceVolumes[deviceID]?.isEmpty == true {
            deviceVolumePresets.deviceVolumes.removeValue(forKey: deviceID)
          }
        }
        appIntentCoordinator.releaseDevicePresetMutation(
          key: mutationKey,
          generation: intent.generation
        )
      }
      reportPersistenceFailure(store: .deviceVolumePresets, error: error, showWarning: false)
      return .devicePresetFailed(error.localizedDescription)
    }
    if appIntentCoordinator.ownsDevicePresetMutation(
      key: mutationKey,
      generation: intent.generation
    ) {
      appIntentCoordinator.releaseDevicePresetMutation(
        key: mutationKey,
        generation: intent.generation
      )
    }
    return .saved
  }

  private func presentAppIntentFeedback(
    _ result: AppIntentApplyResult,
    persistenceResult: AcceptedIntentPersistenceResult,
    policy: AppIntentFeedbackPolicy
  ) {
    switch persistenceResult {
    case let .settingsFailed(detail):
      showToast(
        title: "Applied, but could not save",
        detail: detail,
        kind: .warning
      )
      return
    case let .devicePresetFailed(detail):
      showToast(
        title: "Applied, but device preset was not saved",
        detail: detail,
        kind: .warning
      )
      return
    case .notRequested, .saved:
      break
    }

    switch policy {
    case .none:
      return
    case let .directControl(successTitle, successDetail, failureTitle):
      switch result.outcome {
      case .applied, .noChange:
        guard result.resultingApp?.routingState == .managed else { return }
        if !successTitle.isEmpty {
          showToast(
            title: successTitle,
            detail: successDetail,
            kind: .success,
            duration: .seconds(1.2)
          )
        }
      case .superseded:
        return
      case .excluded:
        showToast(title: failureTitle, detail: "This app is excluded from Waves.", kind: .warning)
      case .unavailable:
        showToast(title: failureTitle, detail: result.detail ?? "The app is no longer available.", kind: .warning)
      case .unsupported:
        showToast(title: failureTitle, detail: result.detail, kind: .warning)
      case .failed:
        showToast(title: failureTitle, detail: result.detail, kind: .error)
      }
    case let .exclusion(appName, announce):
      guard announce else { return }
      if result.outcome == .excluded {
        showToast(
          title: "Excluded from Waves",
          detail: appName,
          kind: .info,
          duration: .seconds(1.4)
        )
      } else if result.outcome != .superseded {
        showToast(title: "Couldn’t exclude \(appName)", detail: result.detail, kind: .error)
      }
    case let .reinclusion(appName, announce):
      guard announce else { return }
      if (result.outcome == .applied || result.outcome == .noChange),
        result.resultingApp?.routingState == .managed
      {
        showToast(
          title: "Managed by Waves",
          detail: appName,
          kind: .success,
          duration: .seconds(1.4)
        )
      } else if result.outcome != .superseded {
        showToast(
          title: "Couldn’t manage \(appName)",
          detail: result.detail ?? "A managed audio route is not available.",
          kind: result.outcome == .failed ? .error : .warning
        )
      }
    }
  }

  func supersedeAppIntentWork(forAppID appID: String) {
    appIntentCoordinator.supersedeApp(appID)
  }

  func setDesiredVolume(_ value: Float, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    let appID = app.logicalID
    guard session.apps.firstIndex(matchingAppKey: appID) != nil else {
      showToast(
        title: "Volume change blocked",
        detail: BackendError.appNotFound(app.id).localizedDescription,
        kind: .warning
      )
      return
    }

    let clamped = max(0, min(1, value))
    appIntentCoordinator.setPendingVolume(clamped, for: appID)
    applyPendingVolumeProjection(forAppID: appID)
    scheduleVolumeTransaction(clamped, forAppID: appID)
  }

  /// Pushes an in-flight slider value to the audio engine while the drag is
  /// still happening.
  ///
  /// Without this, `setDesiredVolume` only moved the on-screen projection and
  /// nothing reached the backend until `commitDesiredVolume` fired on mouse-up —
  /// so the *sound* did not follow the handle, it jumped once the user let go.
  /// The equalizer already had this shape; volume, the far more frequently
  /// dragged control, did not.
  ///
  /// Three deliberate differences from `commitDesiredVolume`, which remains the
  /// only committing boundary:
  ///
  /// - Persists nothing. A drag is not a decision; the value the user settles on
  ///   is what gets written.
  /// - Shows no toast. One "Managed route active" per drag, not per frame.
  /// - Does not clear `pendingVolumeTargets`. That entry is what marks the app as
  ///   "being dragged right now" for the silent session refresh and for the
  ///   projection, and clearing it mid-drag would let a background refresh
  ///   overwrite the handle position.
  private func scheduleVolumeTransaction(_ value: Float, forAppID appID: String) {
    // Always retire the previous nudge, even when the route has stopped being
    // managed since the last slider event.
    appIntentCoordinator.cancelVolumeDebounce(for: appID)

    // Only nudge a route that already exists. Applying to an unmanaged app can
    // fall into the branch that builds a tap and an aggregate device — and if a
    // helper process appears mid-drag the same branch *rebuilds* them, which is
    // an audible dropout in the middle of the gesture. The commit does that work
    // once, at the end, where a brief interruption is expected.
    guard session.apps.first(matchingAppKey: appID)?.routingState == .managed else { return }

    let token = appIntentCoordinator.beginVolumeDebounce(for: appID)
    let coordinator = appIntentCoordinator
    let task = Task { @MainActor [weak self] in
      defer { coordinator.settleVolumeDebounce(token) }
      do {
        try await Task.sleep(for: Self.volumeDragInterval)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      let routeIsManaged =
        self.session.apps
        .first(matchingAppKey: appID)?.routingState == .managed
      guard coordinator.isCurrentVolumeDebounce(token, for: appID),
        coordinator.pendingVolume(for: appID) == value,
        routeIsManaged
      else {
        return
      }
      self.startAppIntentTransaction(
        forAppID: appID,
        overrides: AppIntentOverrides(desiredVolume: value),
        reason: .userEdit,
        persistencePolicy: .none,
        feedbackPolicy: .none,
        optimistic: false
      )
    }
    appIntentCoordinator.registerVolumeDebounce(task, token: token, appID: appID)
  }

  func commitDesiredVolume(for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    let appID = app.logicalID
    // The drag is over; no in-flight nudge should land after the commit and
    // reinstate an intermediate value.
    appIntentCoordinator.cancelVolumeDebounce(for: appID)
    let target =
      appIntentCoordinator.takePendingVolume(for: appID)
      ?? session.apps.first(matchingAppKey: appID)?.desiredVolume
      ?? app.desiredVolume
    startAppIntentTransaction(
      forAppID: appID,
      overrides: AppIntentOverrides(desiredVolume: target),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: true),
      feedbackPolicy: .directControl(
        successTitle: "Managed route active",
        successDetail: "\(app.displayName) set to \(Int(target * 100))%",
        failureTitle: "Volume change failed"
      ),
      optimistic: true
    )
  }

  func cleanupStaleEntries() {
    let currentAppIDs = Set(session.apps.map(\.logicalID))
    appIntentCoordinator.retainAppState(in: currentAppIDs)
  }

  func setMuted(_ isMuted: Bool, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    appIntentCoordinator.releaseAutomaticMute(for: app.logicalID)
    startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(isMuted: isMuted, muteSource: .user),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: true),
      feedbackPolicy: .directControl(
        successTitle: isMuted ? "App muted" : "App unmuted",
        successDetail: app.displayName,
        failureTitle: "Mute toggle failed"
      ),
      optimistic: true
    )
  }

  func setVolumeBoost(_ boost: Float, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    let clampedBoost = max(1, min(4, boost))
    startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(volumeBoost: clampedBoost),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: true),
      feedbackPolicy: .directControl(
        successTitle: "Boost updated",
        successDetail: "\(app.displayName): \(String(format: "%g", clampedBoost))x",
        failureTitle: "Boost update failed"
      ),
      optimistic: true
    )
  }
}
