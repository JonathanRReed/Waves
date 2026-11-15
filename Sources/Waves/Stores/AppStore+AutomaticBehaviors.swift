import AppKit
import Foundation
import WavesAudioCore

// MARK: - Automatic behaviors: settings toggles, muting media during calls

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
    syncMicrophoneCallMonitoring()
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
    // With the preference off the pass still runs as an unmute-only sweep (see
    // setAutoPauseMusicEnabled) — every other unmute path lives inside this
    // pass, so bailing outright would strand automatically muted apps.
    guard preferences.autoPauseMusicForConferencing else {
      guard session.apps.contains(where: { $0.isMuted && $0.muteSource == .autoConferencing }) else { return }
      await applyAutomaticConferencingTransition(isConferencingActive: false)
      return
    }

    switch preferences.callDetectionMode {
    case .microphoneInUse:
      // Act only on edges, like the frontmost mode below: an app the user
      // unmutes by hand during a call stays unmuted until the next call.
      let isCallActive = microphoneCall.isActive
      let chosenAppAdded = microphoneCall.chosenAppAdded
      microphoneCall.chosenAppAdded = false
      guard isCallActive != microphoneCall.lastApplied else {
        // Mid-call, a newly chosen call app is unmuted if an automatic mute
        // caught it. Nothing new is muted, so manual unmutes still stand.
        if isCallActive, chosenAppAdded {
          await applyAutomaticConferencingTransition(
            isConferencingActive: true,
            sparing: Set(callDetectionAppIDs),
            mutesMedia: false
          )
        }
        return
      }
      microphoneCall.lastApplied = isCallActive
      await applyAutomaticConferencingTransition(
        isConferencingActive: isCallActive,
        sparing: Set(callDetectionAppIDs)
      )
    case .frontmostCallApp:
      // Detect conferencing from the live frontmost application rather than the
      // session snapshot, whose `isActive` flags are only refreshed periodically.
      let frontmost = NSWorkspace.shared.frontmostApplication
      let currentFrontmostApp = frontmost?.bundleIdentifier
      guard currentFrontmostApp != previousFrontmostApp else { return }
      previousFrontmostApp = currentFrontmostApp

      let frontmostCategory = frontmost.map {
        AppDiscoveryPolicy.inferCategory(bundleID: $0.bundleIdentifier, displayName: $0.localizedName ?? "")
      }
      await applyAutomaticConferencingTransition(
        isConferencingActive: frontmostCategory == .conferencing
      )
    }
  }

  /// Applies the automatic conferencing transition through the same complete,
  /// generation-aware intent boundary as direct controls. Kept internal so focused
  /// tests can drive the deterministic transition without changing the OS frontmost
  /// application. Automation never requests durable intent or device-preset saves.
  ///
  /// `sparing` names the call apps themselves: never muted by this, and
  /// unmuted if an earlier automatic mute caught one.
  ///
  /// `mutesMedia` is false for a pass that only releases spared apps.
  func applyAutomaticConferencingTransition(
    isConferencingActive: Bool,
    sparing sparedAppIDs: Set<String> = [],
    mutesMedia: Bool = true
  ) async {
    guard requireAudioRunning() else { return }
    var mutedNames: [String] = []
    var unmutedNames: [String] = []

    if isConferencingActive, mutesMedia {
      let musicApps = visibleApps.filter {
        $0.category == .media && !$0.isMuted && !isExcluded($0)
          && !sparedAppIDs.contains($0.logicalID)
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
            "Call mute did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
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
        mutedNames.append(app.displayName)
        logger.info("Muted media app for a call: \(app.displayName, privacy: .public)")
      }
    }

    let resumable = visibleApps.filter {
      $0.isMuted
        && $0.muteSource == .autoConferencing
        && appIntentCoordinator.ownsAutomaticMute(for: $0.logicalID)
        && !isExcluded($0)
        && (!isConferencingActive || sparedAppIDs.contains($0.logicalID))
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
          "Call unmute did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
        )
        continue
      }
      if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
        session.apps[index].muteSource = .user
      }
      appIntentCoordinator.releaseAutomaticMute(for: app.logicalID)
      unmutedNames.append(app.displayName)
      logger.info("Unmuted media app after a call: \(app.displayName, privacy: .public)")
    }

    guard !mutedNames.isEmpty || !unmutedNames.isEmpty else { return }
    persistSessionSnapshot()
    syncOnboarding(using: session)

    if !mutedNames.isEmpty {
      let detail =
        mutedNames.count == 1
        ? "\(mutedNames[0]) is muted until the call ends."
        : "\(mutedNames.count) apps are muted until the call ends."
      showToast(
        title: "Muted for your call",
        detail: detail,
        kind: .info,
        duration: .seconds(2.4)
      )
    } else {
      let detail =
        unmutedNames.count == 1
        ? "\(unmutedNames[0]) is unmuted."
        : "\(unmutedNames.count) apps are unmuted."
      showToast(
        title: "Unmuted after your call",
        detail: detail,
        kind: .info,
        duration: .seconds(2.0)
      )
    }
  }
}
