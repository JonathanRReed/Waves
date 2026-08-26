import AppKit
import Foundation
import WavesAudioCore

// MARK: - Per-app equalizer and adaptive mixing

extension AppStore {
  func equalizerSettings(for app: AudioApp) -> EqualizerSettings {
    if let pending = appIntentCoordinator.pendingEqualizer(for: app.logicalID) {
      return pending
    }
    if let projection = appIntentCoordinator.currentProjection(for: app.logicalID) {
      return projection.intent.equalizerSettings
    }
    return appIntentCoordinator.confirmedEqualizer(for: app.logicalID)
      ?? preferences.appAudioIntents[app.logicalID]?.equalizerSettings
      ?? preferences.appEqualizerSettings[app.logicalID]
      ?? EqualizerSettings()
  }

  func setEqualizerEnabled(_ enabled: Bool, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.isEnabled = enabled
    }
  }

  func setEqualizerMode(_ mode: EqualizerMode, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.mode = mode
    }
  }

  func setEqualizerGain(_ gainDB: Float, at index: Int, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.isEnabled = true
      settings.setGain(gainDB, at: index)
    }
  }

  func applyEqualizerPreset(_ preset: EqualizerPreset, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.isEnabled = true
      settings.applyPreset(preset)
    }
  }

  func resetEqualizer(for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.resetActiveMode()
    }
  }

  func setManagedAudioEqualizerEnabled(_ enabled: Bool) {
    updateManagedAudioEqualizer { settings in
      settings.isEnabled = enabled
    }
  }

  func setManagedAudioEqualizerMode(_ mode: EqualizerMode) {
    updateManagedAudioEqualizer { settings in
      settings.mode = mode
    }
  }

  func setManagedAudioEqualizerGain(_ gainDB: Float, at index: Int) {
    updateManagedAudioEqualizer { settings in
      settings.isEnabled = true
      settings.setGain(gainDB, at: index)
    }
  }

  func applyManagedAudioEqualizerPreset(_ preset: EqualizerPreset) {
    updateManagedAudioEqualizer { settings in
      settings.isEnabled = true
      settings.applyPreset(preset)
    }
  }

  func resetManagedAudioEqualizer() {
    updateManagedAudioEqualizer { settings in
      settings.resetActiveMode()
    }
  }

  private func updateManagedAudioEqualizer(
    mutation: (inout GlobalEqualizerSettings) -> Void
  ) {
    guard requireAudioRunning() else { return }
    mutation(&preferences.managedAudioEqualizer)
    let settings = preferences.managedAudioEqualizer
    persistPreferences()
    startOwnedOperation { store in
      await store.backend.setManagedAudioEqualizer(settings)
    }
  }

  func setAdaptiveRole(_ role: AdaptiveAppRole, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.adaptiveRole = role
    }
  }

  /// The policy for an app: the stored one, or the deterministic default derived
  /// from its legacy role and category.
  ///
  /// Deliberately pure. This is read from view bodies (the Sound workspace's
  /// per-app controls) and from the adaptive coordinator's per-pass input build,
  /// and it used to write the derived value into `preferences` and schedule a
  /// persist as a side effect of being read — mutating observed state during a
  /// SwiftUI view update, and queueing a preferences write from inside the
  /// render pass. The derivation is deterministic, so not storing it changes no
  /// answer; the value is persisted the moment the user actually edits it.
  func adaptivePolicy(for app: AudioApp) -> AdaptiveAppPolicy {
    if let policy = preferences.adaptiveAppPolicies[app.logicalID] {
      return policy
    }
    return AdaptiveAppPolicy.migrating(
      legacyRole: equalizerSettings(for: app).adaptiveRole,
      category: app.category,
      bundleIdentifier: app.bundleID,
      displayName: app.displayName
    )
  }

  func setAdaptiveContentType(_ contentType: AdaptiveContentType, for app: AudioApp) {
    var policy = adaptivePolicy(for: app)
    policy.contentType = contentType
    setAdaptivePolicy(policy, for: app)
  }

  func setAdaptivePriority(_ priority: AdaptivePriority, for app: AudioApp) {
    var policy = adaptivePolicy(for: app)
    policy.priority = priority
    setAdaptivePolicy(policy, for: app)
  }

  func applyAdaptiveStrategy(_ strategy: AdaptiveStrategy) {
    guard requireAudioRunning() else { return }
    for app in visibleApps {
      let current = adaptivePolicy(for: app)
      preferences.adaptiveAppPolicies[app.logicalID] = AdaptiveMixing.policy(
        for: strategy,
        contentType: current.contentType,
        existingPolicy: current
      )
    }
    preferences.adaptiveStrategy = strategy
    persistPreferences()
    restartAdaptiveMixing()
  }

  private func setAdaptivePolicy(_ policy: AdaptiveAppPolicy, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    preferences.adaptiveAppPolicies[app.logicalID] = policy
    preferences.adaptiveStrategy = .custom
    persistPreferences()
    restartAdaptiveMixing()
  }

  /// Turns Adaptive Mix on or off without discarding *which* mode the user
  /// chose. The boolean toggles in Sound, Settings, and Onboarding used to write
  /// `.both` on enable, so anyone who had deliberately picked Speech Focus or
  /// Loudness Balance got silently switched to both the next time they flipped
  /// the switch off and on.
  func setAdaptiveMixEnabled(_ isEnabled: Bool) {
    setAdaptiveMixMode(isEnabled ? lastActiveAdaptiveMixMode : .off)
  }

  func setAdaptiveMixMode(_ mode: AdaptiveMixMode) {
    guard requireAudioRunning() else { return }
    guard preferences.adaptiveMixMode != mode else { return }
    if mode != .off { lastActiveAdaptiveMixMode = mode }
    preferences.adaptiveMixMode = mode
    if mode.usesSpeechFocus {
      // The legacy frontmost-app behavior fully mutes media. It cannot run at
      // the same time as speech ducking without defeating the new mix.
      preferences.autoPauseMusicForConferencing = false
      previousFrontmostApp = nil
      checkAutoPauseMusic()
    }
    persistPreferences()
    restartAdaptiveMixing()
    showToast(
      title: "Adaptive Mix",
      detail: mode.displayName,
      kind: mode == .off ? .info : .success,
      duration: .seconds(1.4)
    )
  }

  func setAdaptiveFocusMode(_ mode: AdaptiveFocusMode) {
    guard requireAudioRunning() else { return }
    guard preferences.adaptiveFocusMode != mode else { return }
    preferences.adaptiveFocusMode = mode
    persistPreferences()
    restartAdaptiveMixing()
    showToast(
      title: "Sidechain Focus",
      detail: mode.displayName,
      kind: .success,
      duration: .seconds(1.4)
    )
  }

  private func updateEqualizerSettings(
    for app: AudioApp,
    mutation: (inout EqualizerSettings) -> Void
  ) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    var settings = equalizerSettings(for: app)
    mutation(&settings)
    appIntentCoordinator.setPendingEqualizer(settings, for: app.logicalID)
    scheduleEqualizerTransaction(settings, for: app)
  }

  private func scheduleEqualizerTransaction(_ settings: EqualizerSettings, for app: AudioApp) {
    let appID = app.logicalID
    let token = appIntentCoordinator.beginEqualizerDebounce(for: appID)
    let coordinator = appIntentCoordinator
    let task = Task { @MainActor [weak self] in
      defer { coordinator.settleEqualizerDebounce(token) }
      do {
        try await Task.sleep(for: .milliseconds(80))
      } catch {
        return
      }
      guard let self, !Task.isCancelled,
        coordinator.isCurrentEqualizerDebounce(token, for: appID),
        coordinator.pendingEqualizer(for: appID) == settings
      else { return }
      _ = coordinator.takePendingEqualizer(for: appID)
      self.startAppIntentTransaction(
        forAppID: appID,
        overrides: AppIntentOverrides(equalizerSettings: settings),
        reason: .userEdit,
        persistencePolicy: .acceptedUserIntent(updateDevicePreset: false),
        feedbackPolicy: .directControl(
          successTitle: "",
          successDetail: nil,
          failureTitle: "EQ not active"
        ),
        optimistic: true
      )
    }
    appIntentCoordinator.registerEqualizerDebounce(task, token: token, appID: appID)
  }

  func restartAdaptiveMixing() {
    guard startupState == .running else { return }
    adaptiveMixCoordinator.restart(
      isEnabled: preferences.adaptiveMixMode != .off,
      activeInterval: adaptiveMixInterval,
      idleInterval: adaptiveMixIdleInterval,
      performPass: { [weak self] in
        await self?.performAdaptiveMixPassIfNeeded() ?? false
      },
      reset: { [weak self] in
        guard let self else { return }
        self.adaptiveGainsDBByAppID = [:]
        await self.backend.setAdaptiveGains([:])
      }
    )
  }

  /// The apps Adaptive Mix is allowed to act on: everything in the session that
  /// the user has not excluded.
  ///
  /// Deliberately *not* `visibleApps`. That list is sorted for display and
  /// filtered by presentation preferences like "show system processes", so
  /// feeding it to the mixer meant a display toggle could change which streams
  /// got ducked — and made the 10 Hz coordinator pay for a full sort of the app
  /// list on every pass.
  private var adaptiveCandidateApps: [AudioApp] {
    session.apps.filter { !preferences.excludedAppIDs.contains($0.logicalID) }
  }

  /// Runs one adaptive pass when there is something to adjust. Returns whether
  /// real work happened, which selects the next sleep interval.
  ///
  /// Adaptive Mix can only act on streams Waves actually owns, so with no
  /// managed route the whole pass — the backend analysis, the policy update, the
  /// gain write — is guaranteed to be a no-op. Skipping it is a single scan of
  /// the candidate list.
  private func performAdaptiveMixPassIfNeeded() async -> Bool {
    guard startupState == .running else { return false }
    let mode = preferences.adaptiveMixMode
    let apps = adaptiveCandidateApps
    let hasManagedRoute = apps.contains { $0.routingState == .managed }
    let analysis = hasManagedRoute ? await backend.adaptiveAnalysis() : [:]
    guard !Task.isCancelled, startupState == .running,
      preferences.adaptiveMixMode == mode,
      mode != .off
    else { return false }

    let frontmostAppID = frontmostManagedAppIDForAdaptiveMix(in: apps)
    let output = adaptiveMixCoordinator.evaluate(
      AdaptiveMixPassInput(
        mode: mode,
        focusMode: preferences.adaptiveFocusMode,
        apps: apps.map { app in
          AdaptiveMixAppInput(
            app: app,
            policy: adaptivePolicy(for: app),
            levels: analysis[app.logicalID],
            isFrontmost: app.logicalID == frontmostAppID
          )
        }
      ))

    guard !Task.isCancelled, startupState == .running,
      preferences.adaptiveMixMode == mode
    else { return false }
    if output.visibleGains != adaptiveGainsDBByAppID {
      adaptiveGainsDBByAppID = output.visibleGains
    }
    if let backendGains = output.backendGains {
      await backend.setAdaptiveGains(backendGains)
    }
    return output.didWork
  }

  func togglePinned(_ app: AudioApp) {
    guard requireAudioRunning() else { return }
    let appName = app.displayName
    let appKey = app.logicalID
    let willPin = !preferences.pinnedAppIDs.contains(appKey)

    // Pin state lives in preferences (authoritative + persisted), so it survives
    // the app quitting/relaunching and a full relaunch of Waves.
    if willPin {
      preferences.pinnedAppIDs.append(appKey)
    } else {
      preferences.pinnedAppIDs.removeAll { $0 == appKey }
    }
    persistPreferences()

    // Optimistically mirror onto the session row for immediate feedback (and so
    // any code reading session.apps directly agrees); visibleApps reconciles too.
    if let index = session.apps.firstIndex(matchingAppKey: appKey) {
      session.apps[index].isPinned = willPin
    }

    // Keep the backend snapshot in step on a best-effort basis; preferences
    // remains the source of truth, so a backend failure can't lose the pin.
    startOwnedOperation { store in
      try? await store.backend.pinApp(willPin, appID: appKey)
      guard !Task.isCancelled, store.startupState == .running else { return }
      store.persistSessionSnapshot()
    }

    showToast(
      title: willPin ? "Pinned to top" : "Unpinned",
      detail: appName,
      kind: .info,
      duration: .seconds(1.2)
    )
  }
}
