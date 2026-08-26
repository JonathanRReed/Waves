import AppKit
import Foundation
import WavesAudioCore

// MARK: - Automatic behaviors: settings toggles, auto-pause, conferencing

extension AppStore {
  /// Updates the auto-pause preference. Toggling in either direction resets the
  /// frontmost guard and re-evaluates immediately (the pass short-circuits while
  /// frontmost is unchanged): turning it ON must pause for a conferencing app
  /// that is *already* frontmost, and turning it OFF must resume anything still
  /// auto-paused right away — every other resume path runs inside the auto-pause
  /// pass, so without this the toggle would strand auto-paused apps muted.
  func setAutoPauseMusicEnabled(_ enabled: Bool) {
    guard requireAudioRunning() else { return }
    let wasEnabled = preferences.autoPauseMusicForConferencing
    preferences.autoPauseMusicForConferencing = enabled
    if enabled {
      // Full muting and speech ducking are mutually exclusive. Preserve the
      // loudness layer when Both was selected, otherwise turn Adaptive Mix off.
      switch preferences.adaptiveMixMode {
      case .speechFocus:
        preferences.adaptiveMixMode = .off
        restartAdaptiveMixing()
      case .both:
        preferences.adaptiveMixMode = .loudnessBalance
        // Record the downgrade as the mode to restore, so switching Adaptive
        // Mix off and on again brings back Loudness Balance — what the user was
        // last actually shown — rather than resurrecting Both, which would turn
        // straight around and clear this auto-pause setting again.
        lastActiveAdaptiveMixMode = .loudnessBalance
        restartAdaptiveMixing()
      case .off, .loudnessBalance:
        break
      }
    }
    persistPreferences()
    if enabled != wasEnabled {
      previousFrontmostApp = nil
      checkAutoPauseMusic()
    }
  }

  /// Updates the auto-restore-device preference. Read directly by
  /// `performDeviceChangePass`/`start`/`refresh` wherever per-device volume
  /// presets are restored — the backend itself always re-establishes managed
  /// routes on a device change regardless of this preference (route recovery
  /// is core functionality, not the optional convenience this toggle covers).
  func setAutoRestoreDeviceEnabled(_ enabled: Bool) {
    guard requireAudioRunning() else { return }
    preferences.autoRestoreDevice = enabled
    persistPreferences()
  }

  /// Updates how long a just-quiet app stays in Live. Existing pending removals
  /// are rebuilt with the new timing so the control takes effect immediately.
  func setLiveListLinger(_ linger: LiveListLinger) {
    guard startupState != .shuttingDown else { return }
    guard preferences.liveListLinger != linger else { return }
    preferences.liveListLinger = linger
    persistPreferences()
    for task in lingerRemovalTasks.values { task.cancel() }
    lingerRemovalTasks.removeAll()
    refreshLiveLinger()
  }

  func setPerAppAudioController(_ controller: PerAppAudioController) {
    guard startupState != .shuttingDown else { return }
    guard preferences.perAppAudioController != controller else { return }
    preferences.perAppAudioController = controller
    persistPreferences()
    applyWaveLinkSettingsAndRecoverRoutes()
  }

  func setWaveLinkCompatibilityEnabled(_ isEnabled: Bool) {
    guard startupState != .shuttingDown else { return }
    guard preferences.waveLinkCompatibilityEnabled != isEnabled else { return }
    preferences.waveLinkCompatibilityEnabled = isEnabled
    persistPreferences()
    applyWaveLinkSettingsAndRecoverRoutes()
  }

  private func applyWaveLinkSettingsAndRecoverRoutes() {
    waveLinkSettingsGeneration &+= 1
    let generation = waveLinkSettingsGeneration
    let compatibilityEnabled = preferences.waveLinkCompatibilityEnabled
    let controller = preferences.perAppAudioController
    startOwnedOperation { store in
      await store.backend.setWaveLinkCompatibilityEnabled(compatibilityEnabled)
      await store.backend.setPerAppAudioController(controller)
      guard !Task.isCancelled else { return }
      guard generation == store.waveLinkSettingsGeneration else {
        await store.backend.setWaveLinkCompatibilityEnabled(
          store.preferences.waveLinkCompatibilityEnabled
        )
        await store.backend.setPerAppAudioController(store.preferences.perAppAudioController)
        return
      }
      if store.startupState == .running {
        store.pendingWaveLinkRouteRecovery = true
        store.requestWaveLinkRouteRecoveryIfNeeded()
      } else if store.startupState == .startingAudio
        || store.startupState == .savingPrivacyConsent
      {
        store.pendingWaveLinkRouteRecovery = true
      }
    }
  }

  func requestWaveLinkRouteRecoveryIfNeeded() {
    guard pendingWaveLinkRouteRecovery, startupState == .running else { return }
    guard !isRecovering else { return }
    pendingWaveLinkRouteRecovery = false
    recoverRoutes()
  }

  func checkAutoPauseMusic() {
    guard requireAudioRunning() else { return }
    // Coalesce overlapping passes (mirroring handleDeviceChange) so two never
    // run at once. Frontmost detection happens inside each pass, so the
    // coalesced rerun reads the *then-current* frontmost app — the latest app
    // switch always wins and none are dropped.
    guard !isRunningAutoPausePass else {
      pendingAutoPausePassRerun = true
      return
    }
    isRunningAutoPausePass = true
    let started = startOwnedOperation { store in
      defer { store.isRunningAutoPausePass = false }
      repeat {
        store.pendingAutoPausePassRerun = false
        await store.performAutoPausePass()
      } while !Task.isCancelled
        && store.startupState == .running
        && store.pendingAutoPausePassRerun
    }
    if !started {
      isRunningAutoPausePass = false
    }
  }

  private func performAutoPausePass() async {
    let enabled = preferences.autoPauseMusicForConferencing
    // With the preference off the pass still runs as a resume-only sweep (see
    // setAutoPauseMusicEnabled) — every other resume path lives inside this
    // pass, so bailing outright would strand auto-paused apps muted.
    if !enabled {
      guard session.apps.contains(where: { $0.isMuted && $0.muteSource == .autoConferencing }) else { return }
    }

    // Detect conferencing from the live frontmost application rather than the
    // session snapshot, whose `isActive` flags are only refreshed periodically.
    let frontmost = NSWorkspace.shared.frontmostApplication
    let currentFrontmostApp = frontmost?.bundleIdentifier
    guard currentFrontmostApp != previousFrontmostApp else { return }
    previousFrontmostApp = currentFrontmostApp

    let frontmostCategory = frontmost.map {
      AppDiscoveryPolicy.inferCategory(bundleID: $0.bundleIdentifier, displayName: $0.localizedName ?? "")
    }
    let isConferencingAppActive = enabled && frontmostCategory == .conferencing

    await applyAutomaticConferencingTransition(
      isConferencingActive: isConferencingAppActive
    )
  }

  /// Applies the automatic conferencing transition through the same complete,
  /// generation-aware intent boundary as direct controls. Kept internal so focused
  /// tests can drive the deterministic transition without changing the OS frontmost
  /// application. Automation never requests durable intent or device-preset saves.
  func applyAutomaticConferencingTransition(
    isConferencingActive: Bool
  ) async {
    guard requireAudioRunning() else { return }
    var pausedNames: [String] = []
    var resumedNames: [String] = []

    if isConferencingActive {
      let musicApps = visibleApps.filter {
        $0.category == .media && !$0.isMuted && !isExcluded($0)
      }
      for app in musicApps {
        let result = await applyAppIntent(
          forAppID: app.logicalID,
          overrides: AppIntentOverrides(
            isMuted: true,
            muteSource: .autoConferencing
          ),
          reason: .automation,
          persistencePolicy: .none,
          feedbackPolicy: .none,
          optimistic: false
        )
        guard (result.outcome == .applied || result.outcome == .noChange),
          result.resultingApp?.isMuted == true,
          session.apps.first(matchingAppKey: app.logicalID)?.isMuted == true,
          appIntentCoordinator.isCurrent(result.generation, for: app.logicalID)
        else {
          logger.error(
            "Auto-pause did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
          )
          continue
        }
        if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[index].muteSource = .autoConferencing
        }
        guard
          appIntentCoordinator.claimAutomaticMute(
            for: app.logicalID,
            generation: result.generation
          )
        else { continue }
        pausedNames.append(app.displayName)
        logger.info("Auto-paused music app: \(app.displayName, privacy: .public)")
      }
    } else {
      let resumable = visibleApps.filter {
        $0.isMuted
          && $0.muteSource == .autoConferencing
          && appIntentCoordinator.ownsAutomaticMute(for: $0.logicalID)
          && !isExcluded($0)
      }
      for app in resumable {
        let result = await applyAppIntent(
          forAppID: app.logicalID,
          overrides: AppIntentOverrides(isMuted: false, muteSource: .user),
          reason: .automation,
          persistencePolicy: .none,
          feedbackPolicy: .none,
          optimistic: false
        )
        guard (result.outcome == .applied || result.outcome == .noChange),
          result.resultingApp?.isMuted == false,
          session.apps.first(matchingAppKey: app.logicalID)?.isMuted == false,
          appIntentCoordinator.isCurrent(result.generation, for: app.logicalID)
        else {
          logger.error(
            "Auto-resume did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
          )
          continue
        }
        if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[index].muteSource = .user
        }
        appIntentCoordinator.releaseAutomaticMute(for: app.logicalID)
        resumedNames.append(app.displayName)
        logger.info("Auto-resumed music app: \(app.displayName, privacy: .public)")
      }
    }

    guard !pausedNames.isEmpty || !resumedNames.isEmpty else { return }
    persistSessionSnapshot()
    syncOnboarding(using: session)

    if !pausedNames.isEmpty {
      let detail =
        pausedNames.count == 1
        ? "\(pausedNames[0]) muted for your call."
        : "\(pausedNames.count) apps muted for your call."
      showToast(
        title: "Auto-paused media",
        detail: detail,
        kind: .info,
        duration: .seconds(2.4)
      )
    } else {
      let detail =
        resumedNames.count == 1
        ? "\(resumedNames[0]) resumed."
        : "\(resumedNames.count) apps resumed."
      showToast(
        title: "Resumed media",
        detail: detail,
        kind: .info,
        duration: .seconds(2.0)
      )
    }
  }
}
