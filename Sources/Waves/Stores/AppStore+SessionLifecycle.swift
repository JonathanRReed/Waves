import AppKit
import Foundation
import OSLog
import WavesAudioCore

// MARK: - Session lifecycle: device changes, restoration, shutdown, termination

extension AppStore {
  func observeDeviceChanges() {
    guard deviceChangeObserver == nil else { return }
    let events = backend.deviceChangeEvents
    deviceChangeObserver = Task { [weak self] in
      for await _ in events {
        guard let self else { return }
        self.handleDeviceChange()
      }
    }
  }

  func handleDeviceChange() {
    guard startupState == .running else { return }
    // Coalesce overlapping events instead of dropping them: a device-change in
    // flight already reassigns `session` and (optionally) walks
    // restoreDeviceVolumePresets across backend awaits; a second concurrent
    // pass would interleave those reassignments and restores. So we never run two
    // passes at once. But dropping the second event outright could leave the UI on the
    // earlier snapshot/device-list/onboarding (rapid dock/undock, Bluetooth
    // reconnect) until some unrelated refresh. Instead, record a pending rerun and
    // let the in-flight handler run exactly one more pass once it finishes.
    guard !isHandlingDeviceChange else {
      pendingDeviceChangeRerun = true
      return
    }
    isHandlingDeviceChange = true
    let started = startOwnedOperation { store in
      defer { store.isHandlingDeviceChange = false }
      repeat {
        store.pendingDeviceChangeRerun = false
        await store.performDeviceChangePass()
      } while !Task.isCancelled
        && store.startupState == .running
        && store.pendingDeviceChangeRerun
    }
    if !started {
      isHandlingDeviceChange = false
    }
  }

  private func performDeviceChangePass() async {
    // The lightweight refresh below must run on EVERY device-change event:
    // session.currentDevice, the device list, diagnostics, and onboarding would
    // otherwise go stale (picker label / checkmark stuck on the old device)
    // until some unrelated event refreshes them. This shared state sync is
    // unconditional; only per-device preset restore is gated, on its own toggle.
    //
    // The backend has already re-established managed routes before emitting the
    // event, so read the current snapshot rather than restoring again.
    let previousDeviceID = currentDeviceID
    // Merge cached-only fields (like the .autoConferencing muteSource tag,
    // which the backend never knows about) instead of reassigning wholesale
    // — a bare reassignment resets muteSource to .user, so auto-paused
    // media could never auto-resume after a device change.
    let backendSnapshot = await backend.currentSnapshot()
    guard !Task.isCancelled, startupState == .running else { return }
    session = mergedSession(with: backendSnapshot, cached: session)
    // Per-device preset restore additionally requires "Auto-restore device" —
    // it IS the auto-restore behavior for saved per-app volumes, so honoring
    // the per-device-presets toggle alone while ignoring the opt-out would
    // restore levels the user explicitly asked Waves not to apply automatically.
    if preferences.enablePerDeviceVolumePresets, preferences.autoRestoreDevice,
      let newDeviceID = currentDeviceID, previousDeviceID != newDeviceID
    {
      await restoreDeviceVolumePresets(for: newDeviceID)
    }

    persistSessionSnapshot()
    // A device change is not a reason to re-probe capture authorization: the
    // probe is a system-wide tap, and every Waves route rebuild produces a
    // device-change event of its own, so a forced probe here would compound
    // exactly the churn other audio clients are most sensitive to.
    diagnostics = await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
    onboarding.captureAuthorization = await backend.captureAuthorizationResult()
    availableDevices = await backend.availableOutputDevices()
    syncOnboarding(using: session)
    let didDefaultDeviceChange = previousDeviceID != currentDeviceID

    // Suppress the info toast when this change was triggered by our own
    // selectOutputDevice (which already showed an "Output switched" success
    // toast). Clearing the flag here makes it one-shot, so the next genuinely
    // external device change still announces itself.
    let wasSelfInitiated = deviceChangeSuppression.consumeIfMatching(
      deviceID: currentDeviceID,
      didChange: didDefaultDeviceChange
    )
    if didDefaultDeviceChange && !wasSelfInitiated {
      showToast(
        title: "Output device changed",
        detail: currentDeviceName,
        kind: .info,
        duration: .seconds(1.5)
      )
    }
  }

  func effectiveRestorationOverrides(
    forAppID appID: String,
    deviceID: String?,
    includeDevicePreset: Bool
  ) -> AppIntentOverrides? {
    guard let durable = preferences.appAudioIntents[appID] else { return nil }
    var desiredVolume = durable.desiredVolume
    var isMuted = durable.isMuted
    var volumeBoost = durable.volumeBoost
    if includeDevicePreset,
      let deviceID,
      let preset = deviceVolumePresets.getVolumeSettings(for: appID, deviceID: deviceID)
    {
      desiredVolume = preset.desiredVolume
      isMuted = preset.isMuted
      volumeBoost = preset.volumeBoost
    }
    return AppIntentOverrides(
      desiredVolume: desiredVolume,
      isMuted: isMuted,
      volumeBoost: volumeBoost,
      equalizerSettings: durable.equalizerSettings,
      targetDeviceUID: durable.targetDeviceUID,
      replacesTargetDevice: true,
      isExcluded: false,
      muteSource: .user
    )
  }

  func restoreConfiguredApp(
    appID: String,
    defaultReason: AppRouteIntentReason,
    deviceID: String?,
    includeDevicePreset: Bool
  ) async -> AppIntentApplyResult? {
    guard !preferences.excludedAppIDs.contains(appID),
      session.apps.contains(where: { $0.logicalID == appID }),
      let overrides = effectiveRestorationOverrides(
        forAppID: appID,
        deviceID: deviceID,
        includeDevicePreset: includeDevicePreset
      )
    else { return nil }
    let hasPreset =
      includeDevicePreset
      && deviceID.map {
        deviceVolumePresets.getVolumeSettings(for: appID, deviceID: $0) != nil
      } == true
    return await startAppIntentTransaction(
      forAppID: appID,
      overrides: overrides,
      reason: hasPreset ? .devicePresetRestore : defaultReason,
      persistencePolicy: .none,
      feedbackPolicy: .none,
      optimistic: false
    ).value
  }

  func reapplyRestoredAudioState() async {
    // Automatic conferencing mutes are session-only. Startup restoration always
    // begins from the committed durable user intent instead.
    for index in session.apps.indices where session.apps[index].muteSource == .autoConferencing {
      session.apps[index].muteSource = .user
    }
    appIntentCoordinator.clearAutomaticMuteOwners()

    let deviceID = currentDeviceID
    let includePreset =
      preferences.enablePerDeviceVolumePresets
      && preferences.autoRestoreDevice
    var failedPinnedAppIDs: [String] = []
    for appID in session.apps.map(\.logicalID) {
      guard
        let result = await restoreConfiguredApp(
          appID: appID,
          defaultReason: .startupRestore,
          deviceID: deviceID,
          includeDevicePreset: includePreset
        )
      else { continue }
      let accepted = result.outcome == .applied || result.outcome == .noChange
      if !accepted, preferences.appAudioIntents[appID]?.targetDeviceUID != nil {
        failedPinnedAppIDs.append(appID)
      }
    }

    if !failedPinnedAppIDs.isEmpty {
      let count = failedPinnedAppIDs.count
      showToast(
        title: "Some pinned routes could not be restored",
        detail: count == 1
          ? "1 app couldn't be re-pinned to its saved output device."
          : "\(count) apps couldn't be re-pinned to their saved output devices.",
        kind: .error
      )
    }
  }

  func restoreNewlyAppearedConfiguredApps(excluding knownAppIDs: Set<String>) async {
    let newAppIDs = session.apps.map(\.logicalID).filter { !knownAppIDs.contains($0) }
    guard !newAppIDs.isEmpty else { return }
    let includePreset =
      preferences.enablePerDeviceVolumePresets
      && preferences.autoRestoreDevice
    for appID in newAppIDs {
      _ = await restoreConfiguredApp(
        appID: appID,
        defaultReason: .startupRestore,
        deviceID: currentDeviceID,
        includeDevicePreset: includePreset
      )
    }
  }

  private func restoreDeviceVolumePresets(for deviceID: String) async {
    for appID in session.apps.map(\.logicalID) {
      _ = await restoreConfiguredApp(
        appID: appID,
        defaultReason: .deviceChange,
        deviceID: deviceID,
        includeDevicePreset: true
      )
    }
  }

  private struct ShutdownSettlingTasks {
    let mutationTasks: [Task<Void, Never>]
    let appIntentTasks: [Task<AppIntentApplyResult, Never>]
    let persistenceTasks: [Task<Void, Never>]
  }

  func shutdown() async -> AppShutdownResult {
    if let shutdownResult { return shutdownResult }
    if let shutdownTask { return await shutdownTask.value }

    // The lifecycle transition and cancellation publication are synchronous on
    // MainActor. Every public audio/profile/device/automation gate observes this
    // state before this method reaches its first suspension.
    startupState = .shuttingDown
    let settlingTasks = prepareForShutdown()
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return AppShutdownResult(
          persistenceDegradations: ["AppStore was released before shutdown could be verified."]
        )
      }
      return await self.performShutdown(settlingTasks: settlingTasks)
    }
    shutdownTask = task
    return await task.value
  }

  private func prepareForShutdown() -> ShutdownSettlingTasks {
    if let frontmostAppObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
      self.frontmostAppObserver = nil
    }
    if let appTerminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
      self.appTerminationObserver = nil
    }

    let persistenceTasks = persistenceCoordinator.beginShutdown()
    let intentTasks = appIntentCoordinator.shutdown()
    let adaptiveTask = adaptiveMixCoordinator.shutdown()
    let suppressionTasks = deviceChangeSuppression.beginShutdown()
    automationParser.shutdown()
    urlInvocationLimiter.reset()
    let appTransactions = intentTasks.appTransactions
    var mutationTasks = [
      privacySetupTask,
      audioStartupTask,
      deviceChangeObserver,
      sessionMaintenanceTask,
      levelPollTask,
    ].compactMap { $0 }
    if let adaptiveTask { mutationTasks.append(adaptiveTask) }
    mutationTasks.append(contentsOf: suppressionTasks)
    mutationTasks.append(contentsOf: intentTasks.mutations)
    mutationTasks.append(contentsOf: ownedOperationTasks.values)
    mutationTasks.append(contentsOf: toastDismissals.values)
    mutationTasks.append(contentsOf: lingerRemovalTasks.values)

    for task in mutationTasks { task.cancel() }
    for task in appTransactions { task.cancel() }
    for task in persistenceTasks { task.cancel() }

    privacySetupTask = nil
    audioStartupTask = nil
    deviceChangeObserver = nil
    sessionMaintenanceTask = nil
    levelPollTask = nil
    activeLevelPollInterval = nil
    ownedOperationTasks.removeAll()
    toastDismissals.removeAll()
    lingerRemovalTasks.removeAll()
    pendingDeviceChangeRerun = false
    pendingAutoPausePassRerun = false
    liveLevelsRefcount = 0
    liveLevels.removeAll()
    recentlyLiveIDs.removeAll()

    return ShutdownSettlingTasks(
      mutationTasks: mutationTasks,
      appIntentTasks: appTransactions,
      persistenceTasks: persistenceTasks
    )
  }

  private func performShutdown(
    settlingTasks: ShutdownSettlingTasks
  ) async -> AppShutdownResult {
    for task in settlingTasks.mutationTasks {
      await task.value
    }
    for task in settlingTasks.appIntentTasks {
      _ = await task.value
    }
    for task in settlingTasks.persistenceTasks {
      await task.value
    }

    isRefreshing = false
    isRecovering = false
    isLoading = false
    isHandlingDeviceChange = false
    isRunningSessionMaintenance = false
    isRunningAutoPausePass = false

    if hasStartedAudioBackend {
      await backend.setAdaptiveGains([:])
      let confirmed = await backend.currentSnapshot()
      session = mergedSession(with: confirmed, cached: session)
      syncOnboarding(using: session)
    }

    let failureMarker = persistenceCoordinator.failureHistory.count
    persistenceCoordinator.beginFinalization()
    enqueuePreferencesPersistence(preferences)
    enqueueProfilesPersistence(profiles)
    if preferences.hasCompletedPrivacySetup {
      enqueueSessionPersistence(session)
    }
    enqueueDevicePresetsPersistence(deviceVolumePresets)
    // Non-throwing: each store reports its own failure, so none can suppress
    // another's flush.
    await drainAndFlushPersistence()
    persistenceCoordinator.endFinalization()
    let persistenceDegradations = Array(
      persistenceCoordinator.failureHistory.dropFirst(failureMarker)
    )

    let backendResult: BackendShutdownResult?
    if hasStartedAudioBackend {
      backendResult = await backend.shutdownWithResult()
      hasStartedAudioBackend = false
    } else {
      backendResult = nil
    }

    let result = AppShutdownResult(
      persistenceDegradations: persistenceDegradations,
      backendResult: backendResult
    )
    persistenceCoordinator.finishShutdown()
    shutdownResult = result
    if result.completion == .clean {
      logger.info("Shutdown completed cleanly")
    } else {
      logger.error(
        "Shutdown completed with \(persistenceDegradations.count, privacy: .public) persistence degradation(s) and backend status \(String(describing: backendResult?.completion), privacy: .public)"
      )
    }
    return result
  }

  func observeFrontmostAppChanges() {
    guard frontmostAppObserver == nil else { return }
    frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.checkAutoPauseMusic()
      }
    }
  }

  func observeAppTermination() {
    guard appTerminationObserver == nil else { return }
    appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      let pid = app.processIdentifier
      MainActor.assumeIsolated {
        self?.handleAppTermination(pid: pid)
      }
    }
  }

  func handleAppTermination(pid: Int32) {
    guard startupState == .running else { return }
    guard runtimeProcessProbe(pid) == nil else {
      // The workspace notification carries only a reusable PID, not the
      // lifetime that generated the event. Any process currently holding that
      // PID makes immediate teardown ambiguous, even if the refreshed session
      // already describes that live replacement. Maintenance remains the
      // non-destructive fallback.
      return
    }
    let matchingRows = session.apps.filter { $0.pid == pid }
    guard matchingRows.count == 1,
      let storedIdentity = matchingRows[0].runtimeIdentity,
      storedIdentity.lifetime.pid == pid
    else {
      // A legacy or ambiguous row is not safe immediate-teardown authority.
      // The ordinary maintenance refresh remains the non-destructive fallback.
      return
    }

    // Release the quit app's tap/aggregate device promptly instead of waiting
    // for the next refresh. Termination must NOT clear the user's saved mute.
    startOwnedOperation { store in
      await store.backend.releaseControllers(
        forRuntimeIdentity: storedIdentity,
        clearMuteState: false
      )
    }

    // Reflect the termination in the UI immediately.
    // Every session row matching the quit process — collected BEFORE the
    // routing-state guard below — so linger cleanup covers an app that had
    // already gone quiet (its row sits in Live only via the linger set, with a
    // routingState already dropped to .monitorOnly) and would otherwise miss the
    // guard and ghost in Live until its timer fires.
    var matchedIDs: [String] = []
    for index in session.apps.indices {
      let app = session.apps[index]
      guard app.runtimeIdentity == storedIdentity else { continue }
      matchedIDs.append(app.logicalID)
      if app.isActive || app.routingState == .managed || app.routingState == .live {
        session.apps[index].isActive = false
        session.apps[index].routingState = .monitorOnly
        session.apps[index].appliedVolume = nil
        session.apps[index].peakLevel = 0
        session.apps[index].rmsLevel = 0
      }
    }
    appIntentCoordinator.retainAutomaticMuteOwners(
      in: Set(session.apps.map(\.logicalID))
    )
    // A quit app must not keep lingering as "live": cancel its pending linger drop
    // and remove it from the set now, so its row leaves the Live list at once
    // rather than ghosting there for the linger window after the process is gone.
    for id in matchedIDs {
      if let task = lingerRemovalTasks.removeValue(forKey: id) { task.cancel() }
      appIntentCoordinator.clearPendingEqualizer(for: id)
      appIntentCoordinator.cancelEqualizerDebounce(for: id)
      appIntentCoordinator.clearPendingVolume(for: id)
      appIntentCoordinator.cancelVolumeDebounce(for: id)
      supersedeAppIntentWork(forAppID: id)
      appIntentCoordinator.releaseAutomaticMute(for: id)
    }
    if !matchedIDs.isEmpty {
      let next = recentlyLiveIDs.subtracting(matchedIDs)
      if next != recentlyLiveIDs { recentlyLiveIDs = next }
    }
    // Resume hook for the quit (not switched-away-from) case: resume is normally
    // driven by didActivateApplication, but if a conferencing app quits/crashes
    // and macOS doesn't promptly activate another app, no resume pass fires and
    // auto-paused media stays muted. If any .autoConferencing-tagged mutes
    // remain, re-evaluate directly instead of waiting for the next activation.
    // Resetting previousFrontmostApp defeats checkAutoPauseMusic's
    // unchanged-frontmost short-circuit so the resume branch can run now.
    let hasAutoPausedRemaining = session.apps.contains {
      $0.isMuted && $0.muteSource == .autoConferencing
    }
    if hasAutoPausedRemaining {
      previousFrontmostApp = nil
      checkAutoPauseMusic()
    }
  }
}
