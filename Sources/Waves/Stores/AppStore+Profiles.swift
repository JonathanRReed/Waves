import AppKit
import Foundation
import OSLog
import WavesAudioCore

// MARK: - Profiles
//
// Ordered-batch profile application with generation checks and row-level
// reconciliation, plus profile CRUD, import/export, the mix restore point,
// and the startup default profile.

extension AppStore {
  /// Why a profile batch is being applied. Reset and startup applies reuse the
  /// whole ordered-batch pipeline but must not re-capture a restore point,
  /// focus a synthesized profile, or announce themselves as a user apply.
  enum ProfileApplyPurpose: Sendable {
    case userProfile
    case automation
    case mixReset
    case defaultAtStartup

    var routeIntentReason: AppRouteIntentReason {
      self == .automation ? .automation : .profileApply
    }
  }

  func applyProfile(_ profile: Profile) {
    applyProfile(profile, purpose: .userProfile)
  }

  /// `allowsOutputChanges` is false for a `waves://` link. Anything that can
  /// open a URL can send one, so a link sets levels and EQ but never moves an
  /// app's audio to another device.
  func applyProfile(
    _ profile: Profile,
    purpose: ProfileApplyPurpose,
    allowsOutputChanges: Bool = true
  ) {
    guard requireAudioRunning() else { return }
    // Remember the mix as it stands so the user can come back to it when the
    // session ends. Only a deliberate, level-changing apply creates one, and an
    // existing restore point is kept — chaining Meeting → Focus still resets to
    // the original mix, not to Meeting.
    if purpose == .userProfile, profile.carriesLevels, mixRestorePoint == nil {
      captureMixRestorePoint(before: profile)
    }
    let excludedAppIDsAtSubmission = Set(preferences.excludedAppIDs)
    // A saved EQ restores the sound, not the app's Adaptive Mix role, which
    // lives in the same settings value.
    var submittedProfile = profile
    submittedProfile.entries = profile.entries.map { entry in
      guard var equalizer = entry.equalizer else { return entry }
      equalizer.adaptiveRole = currentEqualizer(forAppID: entry.appID).adaptiveRole
      var entry = entry
      entry.equalizer = equalizer
      return entry
    }
    let liveAppIDs = Set(session.apps.map(\.logicalID))
    let affectedLiveAppIDs = Set(
      submittedProfile.entries.compactMap { entry in
        entry.hasLevels && liveAppIDs.contains(entry.appID) ? entry.appID : nil
      })
    // A profile the user chose becomes their settings; automation's and the
    // default applied at launch do not need saving if Waves quits first.
    let userEntries =
      purpose == .userProfile || purpose == .mixReset
      ? submittedProfile.entries.filter { !excludedAppIDsAtSubmission.contains($0.appID) } : []
    let generation = appIntentCoordinator.beginProfile(
      affectedAppIDs: affectedLiveAppIDs,
      userEntries: userEntries
    )

    // Preserve the immediate group-selection behavior for pure membership
    // profiles while still sending every source row through the ordered result API.
    // Only a user-chosen profile takes focus — a mix reset applies a synthesized
    // profile that doesn't exist in `profiles` and must not become "active".
    if !profile.carriesLevels, purpose == .userProfile {
      focusProfile(profile.id)
    }

    let backend = backend
    let task = Task { @MainActor [weak self, submittedProfile] in
      guard let self else { return }
      var plannedProfile = submittedProfile
      // Never route an app to a device that isn't connected: leave that app's
      // output alone, apply the rest of its row, and say so afterwards.
      var skippedOutputs: [SkippedProfileOutput] = []
      if !allowsOutputChanges {
        plannedProfile.entries = plannedProfile.entries.map { entry in
          guard let output = entry.output else { return entry }
          let current = self.session.apps.first(matchingAppKey: entry.appID)?.targetDeviceUID
          if current != output.deviceUID, !excludedAppIDsAtSubmission.contains(entry.appID) {
            skippedOutputs.append(
              SkippedProfileOutput(appID: entry.appID, deviceName: nil, withheldFromLink: true))
          }
          var entry = entry
          entry.output = nil
          return entry
        }
      }
      if plannedProfile.entries.contains(where: { $0.output?.deviceUID != nil }) {
        let connectedUIDs = Set(await backend.availableOutputDevices().map(\.id))
        plannedProfile.entries = plannedProfile.entries.map { entry in
          guard let uid = entry.output?.deviceUID, !connectedUIDs.contains(uid) else { return entry }
          if !excludedAppIDsAtSubmission.contains(entry.appID) {
            skippedOutputs.append(
              SkippedProfileOutput(appID: entry.appID, deviceName: entry.output?.deviceName))
          }
          var entry = entry
          entry.output = nil
          return entry
        }
      }
      var backendProfile = plannedProfile
      // Keep every source row in its original slot, but neutralize an excluded
      // row's audio fields before the batch reaches a backend that may not retain
      // AppStore-owned exclusion preferences. The coordinator maps that same row
      // back to `.excluded` below, so identity/order are preserved without even a
      // transient re-tap of an app the user told Waves to leave alone.
      backendProfile.entries = plannedProfile.entries.map { entry in
        excludedAppIDsAtSubmission.contains(entry.appID) && entry.hasLevels
          ? ProfileEntry(appID: entry.appID)
          : entry
      }
      let backendResult: ProfileApplyResult
      // A row that also restores EQ or output goes out as one complete intent
      // per app, so its level, EQ, and route change together and never pass
      // through a louder in-between state. Older level-only profiles keep the
      // backend's batch path.
      if purpose == .automation || backendProfile.entries.contains(where: \.restoresSound) {
        backendResult = await applyProfileEntries(
          backendProfile,
          generation: generation,
          reason: purpose.routeIntentReason
        )
      } else {
        backendResult = await backend.applyProfileWithResults(backendProfile, generation: generation)
      }
      defer { self.appIntentCoordinator.settleProfileTask(generation: generation) }
      await self.finishProfileApplication(
        plannedProfile,
        purpose: purpose,
        generation: generation,
        affectedLiveAppIDs: affectedLiveAppIDs,
        excludedAppIDsAtSubmission: excludedAppIDsAtSubmission,
        skippedOutputs: skippedOutputs,
        backendResult: backendResult
      )
    }
    appIntentCoordinator.registerProfileTask(task, generation: generation)
  }

  /// The EQ Waves would send for `appID` right now.
  private func currentEqualizer(forAppID appID: String) -> EqualizerSettings {
    appIntentCoordinator.confirmedEqualizer(for: appID)
      ?? preferences.appAudioIntents[appID]?.equalizerSettings
      ?? preferences.appEqualizerSettings[appID]
      ?? EqualizerSettings()
  }

  private func finishProfileApplication(
    _ profile: Profile,
    purpose: ProfileApplyPurpose,
    generation: UInt64,
    affectedLiveAppIDs: Set<String>,
    excludedAppIDsAtSubmission: Set<String>,
    skippedOutputs: [SkippedProfileOutput],
    backendResult: ProfileApplyResult
  ) async {
    var result = await normalizedProfileResult(
      profile,
      generation: generation,
      excludedAppIDsAtSubmission: excludedAppIDsAtSubmission,
      reason: purpose.routeIntentReason,
      backendResult: backendResult
    )

    // A newer profile owns focus, persistence, diagnostics, and feedback. The old
    // backend call may still unwind, but it cannot publish any store state.
    guard appIntentCoordinator.isCurrentProfile(generation) else { return }

    reconcileProfileRuntime(
      result,
      profile: profile,
      generation: generation,
      affectedLiveAppIDs: affectedLiveAppIDs
    )
    let persistenceResult = await persistProfileRows(
      result,
      profile: profile,
      generation: generation
    )

    // Persistence and diagnostics are suspension points. A direct edit started
    // after the profile must own that app's final row and must not be described as
    // though the profile remained current for it.
    result = profileResultMarkingNewerAppTransactionsSuperseded(
      result,
      profile: profile,
      generation: generation
    )
    guard appIntentCoordinator.isCurrentProfile(generation) else { return }

    lastProfileApplyResult = result
    lastProfileSettingsSaveFailed = persistenceResult.settingsError != nil
    for row in result.rows {
      let detail = row.detail ?? "No additional detail."
      logger.info(
        "Profile row \(row.entryIndex, privacy: .public) \(row.appID, privacy: .public): \(String(describing: row.outcome), privacy: .public). \(detail, privacy: .public)"
      )
    }

    if profile.carriesLevels, purpose == .userProfile {
      focusProfile(profile.id)
    }
    diagnostics = await backend.diagnosticsReport()
    onboarding.captureAuthorization = await backend.captureAuthorizationResult()
    guard appIntentCoordinator.isCurrentProfile(generation) else { return }
    // A direct transaction may have refreshed backendStatus while diagnostics was
    // in flight; keep that newer session truth instead of restoring the batch's
    // older aggregate status here.
    syncOnboarding(using: session)
    persistSessionSnapshot()
    let soundNotes = profileSoundNotes(
      profile,
      result: result,
      skippedOutputs: skippedOutputs
    )
    lastProfileSoundSkippedAppIDs = soundNotes.affectedAppIDs
    switch purpose {
    case .userProfile, .automation:
      presentProfileFeedback(
        profile,
        result: result,
        persistenceResult: persistenceResult,
        soundNotes: soundNotes
      )
    case .mixReset:
      if profileFeedbackIndicatesSuccess(result, persistenceResult: persistenceResult) {
        mixRestorePoint = nil
        activeProfileID = nil
        showToast(
          title: "Mix reset",
          detail: "Levels are back to how they were before \(profile.name).",
          kind: .success,
          duration: .seconds(1.8)
        )
      } else {
        presentQuietProfileProblems(
          profile,
          result: result,
          persistenceResult: persistenceResult,
          soundNotes: soundNotes,
          failureTitle: "Some levels didn't reset"
        )
      }
    case .defaultAtStartup:
      if profileFeedbackIndicatesSuccess(result, persistenceResult: persistenceResult),
        soundNotes.isEmpty
      {
        showToast(
          title: "Default profile applied",
          detail: profile.name,
          kind: .info,
          duration: .seconds(1.8)
        )
      } else {
        presentQuietProfileProblems(
          profile,
          result: result,
          persistenceResult: persistenceResult,
          soundNotes: soundNotes,
          failureTitle: "Default profile partly applied"
        )
      }
    }
  }

  /// True when every actionable row landed and persisted cleanly. An
  /// `.unavailable` row counts as landed: the app isn't running, so its levels
  /// were saved as durable intent and apply on its next launch — the right
  /// outcome for both a reset and a startup default, not a problem to warn about.
  private func profileFeedbackIndicatesSuccess(
    _ result: ProfileApplyResult,
    persistenceResult: ProfilePersistenceResult
  ) -> Bool {
    let actionable = result.rows.filter { $0.outcome != .membershipOnly }
    let landed = actionable.count {
      $0.outcome == .applied || $0.outcome == .noChange || $0.outcome == .unavailable
    }
    return landed == actionable.count && persistenceResult.isFullySaved
  }

  /// Problem-only feedback for applies that already announced themselves
  /// (mix reset) or shouldn't celebrate (startup default): stays silent on
  /// success, warns with a row summary otherwise.
  private func presentQuietProfileProblems(
    _ profile: Profile,
    result: ProfileApplyResult,
    persistenceResult: ProfilePersistenceResult,
    soundNotes: ProfileSoundNotes = ProfileSoundNotes(),
    failureTitle: String
  ) {
    guard
      !profileFeedbackIndicatesSuccess(result, persistenceResult: persistenceResult)
        || !soundNotes.isEmpty
    else {
      return
    }
    let actionable = result.rows.filter { $0.outcome != .membershipOnly }
    let problems = actionable.count {
      $0.outcome != .applied && $0.outcome != .noChange && $0.outcome != .unavailable
    }
    var parts: [String] = []
    if problems == 1 {
      parts.append("1 app couldn't be set. It may have quit or lost its route.")
    } else if problems > 1 {
      parts.append("\(problems) apps couldn't be set. They may have quit or lost their routes.")
    }
    if let settingsError = persistenceResult.settingsError {
      parts.append("Settings not saved: \(settingsError)")
    }
    parts += soundNotes.sentences
    guard !parts.isEmpty else { return }
    let onlySkippedOutputs =
      profileFeedbackIndicatesSuccess(result, persistenceResult: persistenceResult)
      && !soundNotes.routerHeldSound
    showToast(
      title: failureTitle,
      detail: parts.joined(separator: " "),
      kind: onlySkippedOutputs ? .info : .warning
    )
  }

  private func normalizedProfileResult(
    _ profile: Profile,
    generation: UInt64,
    excludedAppIDsAtSubmission: Set<String>,
    reason: AppRouteIntentReason,
    backendResult: ProfileApplyResult
  ) async -> ProfileApplyResult {
    let rowsByIndex = Dictionary(grouping: backendResult.rows, by: \.entryIndex)
    var backendStatus = backendResult.backendStatus
    var rows: [ProfileRowApplyResult] = []
    rows.reserveCapacity(profile.entries.count)

    for (entryIndex, entry) in profile.entries.enumerated() {
      guard entry.hasLevels else {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .membershipOnly,
            resultingApp: nil
          ))
        continue
      }

      if !appIntentCoordinator.isCurrentProfile(generation)
        || appIntentCoordinator.hasNewerGeneration(than: generation, for: entry.appID)
      {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .superseded,
            resultingApp: nil,
            detail: "A newer AppStore transaction superseded this profile row."
          ))
        continue
      }

      guard let backendRow = rowsByIndex[entryIndex]?.first,
        backendRow.appID == entry.appID
      else {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .failed,
            resultingApp: nil,
            detail: "The backend did not return the matching ordered profile row."
          ))
        continue
      }
      guard backendRow.generation == generation else {
        rows.append(
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .superseded,
            resultingApp: nil,
            detail: "The backend returned this profile row for a different generation."
          ))
        continue
      }

      var row = backendRow
      if (row.outcome == .applied || row.outcome == .noChange), row.resultingApp == nil {
        row.outcome = .failed
        row.detail = "The backend reported success without a confirmed resulting app state."
      }
      // `.unavailable` means the app isn't running, so its row is saved for its
      // next launch. A running app reported unavailable was refused instead —
      // a router such as Wave Link owns the boost, EQ, or output this row
      // asked for — and must be reported as not applied, not saved for later.
      if row.outcome == .unavailable, row.resultingApp != nil {
        row.outcome = .unsupported
      }

      // Excluded rows stayed in the ordered batch but reached the backend as
      // membership-only no-ops. Reassert the exclusion with the SAME generation
      // so the final row carries backend-confirmed excluded runtime state.
      if excludedAppIDsAtSubmission.contains(entry.appID), row.outcome != .excluded {
        let exclusionIntent = completeAppRouteIntent(
          forAppID: entry.appID,
          overrides: AppIntentOverrides(isExcluded: true, muteSource: .user),
          generation: generation,
          reason: reason
        )
        let repaired = await backend.applyAppIntent(exclusionIntent)
        backendStatus = repaired.backendStatus
        guard appIntentCoordinator.isCurrentProfile(generation),
          appIntentCoordinator.isCurrent(generation, for: entry.appID)
        else {
          rows.append(
            ProfileRowApplyResult(
              entryIndex: entryIndex,
              appID: entry.appID,
              generation: generation,
              outcome: .superseded,
              resultingApp: nil,
              detail: "A newer transaction superseded exclusion restoration for this profile row."
            ))
          continue
        }
        if repaired.generation == generation, repaired.outcome == .excluded {
          row = ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .excluded,
            resultingApp: repaired.resultingApp,
            detail: "This app is excluded from Waves; its profile levels were not retained."
          )
        } else {
          row = ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: repaired.outcome == .superseded ? .superseded : .failed,
            resultingApp: repaired.resultingApp,
            detail: repaired.detail ?? "Waves could not restore this app's exclusion after profile application."
          )
        }
      }
      rows.append(row)
    }

    return ProfileApplyResult(rows: rows, backendStatus: backendStatus)
  }

  private func reconcileProfileRuntime(
    _ result: ProfileApplyResult,
    profile: Profile,
    generation: UInt64,
    affectedLiveAppIDs: Set<String>
  ) {
    session.backendStatus = result.backendStatus

    for (entry, row) in zip(profile.entries, result.rows) {
      switch row.outcome {
      case .membershipOnly, .superseded:
        continue
      case .unavailable:
        if affectedLiveAppIDs.contains(entry.appID),
          appIntentCoordinator.isCurrent(generation, for: entry.appID)
        {
          session.apps.removeAll { $0.logicalID == entry.appID || $0.id == entry.appID }
          appIntentCoordinator.removeConfirmedApp(for: entry.appID)
        }
      case .applied, .noChange, .excluded, .unsupported, .failed:
        guard var resultingApp = row.resultingApp else { continue }
        if entry.isMuted != nil {
          appIntentCoordinator.releaseAutomaticMute(for: entry.appID)
        }
        let cachedMuteSource = session.apps
          .first(matchingAppKey: entry.appID)?.muteSource
        appIntentCoordinator.recordConfirmedApp(resultingApp)
        // The next volume nudge builds its intent from the confirmed EQ, so a
        // restored EQ must be recorded or that nudge would send the old one.
        if let equalizer = entry.equalizer,
          Self.profileRowRestoredSound(entry, row: row)
        {
          appIntentCoordinator.recordConfirmedEqualizer(equalizer, for: entry.appID)
        }
        resultingApp.isPinned = preferences.pinnedAppIDs.contains(resultingApp.logicalID)
        if row.outcome == .excluded || preferences.excludedAppIDs.contains(resultingApp.logicalID) {
          makeExcludedPresentation(&resultingApp)
        } else if resultingApp.isMuted {
          resultingApp.muteSource =
            entry.isMuted != nil
            ? .user
            : (cachedMuteSource == .autoConferencing ? .autoConferencing : resultingApp.muteSource)
        } else {
          resultingApp.muteSource = .user
        }
        if let index = session.apps.firstIndex(matchingAppKey: entry.appID) {
          session.apps[index] = resultingApp
        } else {
          session.apps.append(resultingApp)
        }
      }
    }

    syncOnboarding(using: session)
    persistSessionSnapshot()
  }

  private func persistProfileRows(
    _ result: ProfileApplyResult,
    profile: Profile,
    generation: UInt64
  ) async -> ProfilePersistenceResult {
    var preferenceAppIDs = Set<String>()
    var devicePresetKeys: [(deviceID: String, appID: String)] = []
    let deviceID = preferences.enablePerDeviceVolumePresets ? currentDeviceID : nil

    for (entry, row) in zip(profile.entries, result.rows) {
      guard entry.hasLevels,
        row.outcome == .applied || row.outcome == .noChange || row.outcome == .unavailable,
        appIntentCoordinator.isCurrentProfile(generation),
        appIntentCoordinator.isCurrentOrUnowned(generation, for: entry.appID),
        let durableIntent = durableIntent(for: entry, row: row)
      else { continue }

      appIntentCoordinator.claimDurableMutation(for: entry.appID, generation: generation)
      preferences.appAudioIntents[entry.appID] = durableIntent
      preferences.appEqualizerSettings[entry.appID] = durableIntent.equalizerSettings
      preferenceAppIDs.insert(entry.appID)

      if let deviceID {
        var preset =
          deviceVolumePresets.getVolumeSettings(
            for: entry.appID,
            deviceID: deviceID
          )
          ?? AppVolumeSettings(
            desiredVolume: durableIntent.desiredVolume,
            isMuted: durableIntent.isMuted,
            volumeBoost: durableIntent.volumeBoost
          )
        if entry.desiredVolume != nil { preset.desiredVolume = durableIntent.desiredVolume }
        if entry.isMuted != nil { preset.isMuted = durableIntent.isMuted }
        if entry.volumeBoost != nil { preset.volumeBoost = durableIntent.volumeBoost }
        let mutationKey = "\(deviceID)\u{0}\(entry.appID)"
        appIntentCoordinator.claimDevicePresetMutation(
          key: mutationKey,
          generation: generation
        )
        deviceVolumePresets.saveVolumeSettings(
          for: entry.appID,
          deviceID: deviceID,
          settings: preset
        )
        if !devicePresetKeys.contains(where: { $0.deviceID == deviceID && $0.appID == entry.appID }) {
          devicePresetKeys.append((deviceID, entry.appID))
        }
      }
    }
    var persistenceResult = ProfilePersistenceResult()
    if !preferenceAppIDs.isEmpty {
      do {
        try await savePreferencesDurably()
        for appID in preferenceAppIDs
        where appIntentCoordinator.ownsDurableMutation(for: appID, generation: generation) {
          appIntentCoordinator.releaseDurableMutation(for: appID, generation: generation)
        }
      } catch {
        for appID in preferenceAppIDs
        where appIntentCoordinator.ownsDurableMutation(for: appID, generation: generation) {
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
          appIntentCoordinator.releaseDurableMutation(for: appID, generation: generation)
        }
        reportPersistenceFailure(store: .preferences, error: error, showWarning: false)
        persistenceResult.settingsError = error.localizedDescription
      }
    }

    if !devicePresetKeys.isEmpty {
      do {
        try await saveDeviceVolumePresetsDurably()
        for key in devicePresetKeys {
          let mutationKey = "\(key.deviceID)\u{0}\(key.appID)"
          if appIntentCoordinator.ownsDevicePresetMutation(
            key: mutationKey,
            generation: generation
          ) {
            appIntentCoordinator.releaseDevicePresetMutation(
              key: mutationKey,
              generation: generation
            )
          }
        }
      } catch {
        for key in devicePresetKeys {
          let mutationKey = "\(key.deviceID)\u{0}\(key.appID)"
          guard
            appIntentCoordinator.ownsDevicePresetMutation(
              key: mutationKey,
              generation: generation
            )
          else { continue }
          if let savedPreset = durablySavedDeviceVolumePresets.getVolumeSettings(
            for: key.appID,
            deviceID: key.deviceID
          ) {
            deviceVolumePresets.saveVolumeSettings(
              for: key.appID,
              deviceID: key.deviceID,
              settings: savedPreset
            )
          } else {
            deviceVolumePresets.deviceVolumes[key.deviceID]?.removeValue(forKey: key.appID)
            if deviceVolumePresets.deviceVolumes[key.deviceID]?.isEmpty == true {
              deviceVolumePresets.deviceVolumes.removeValue(forKey: key.deviceID)
            }
          }
          appIntentCoordinator.releaseDevicePresetMutation(
            key: mutationKey,
            generation: generation
          )
        }
        reportPersistenceFailure(store: .deviceVolumePresets, error: error, showWarning: false)
        persistenceResult.devicePresetError = error.localizedDescription
      }
    }

    return persistenceResult
  }

  private func durableIntent(
    for entry: ProfileEntry,
    row: ProfileRowApplyResult
  ) -> PersistedAppAudioIntent? {
    let existing = preferences.appAudioIntents[entry.appID]
    let existingEqualizer =
      existing?.equalizerSettings
      ?? appIntentCoordinator.confirmedEqualizer(for: entry.appID)
      ?? preferences.appEqualizerSettings[entry.appID]
      ?? EqualizerSettings()

    switch row.outcome {
    case .applied, .noChange:
      guard let app = row.resultingApp else { return nil }
      // The backend's resulting app is the confirmed complete state used to fill
      // fields the source row omitted. The sole exception is an automatic
      // conferencing mute: a volume/boost-only profile must never make that
      // transient mute durable.
      let isAutomaticMute =
        entry.isMuted == nil
        && session.apps.first(matchingAppKey: entry.appID)?.muteSource == .autoConferencing
      let restoredEqualizer = Self.profileRowRestoredSound(entry, row: row) ? entry.equalizer : nil
      return PersistedAppAudioIntent(
        appID: entry.appID,
        desiredVolume: app.desiredVolume,
        isMuted: isAutomaticMute ? (existing?.isMuted ?? false) : app.isMuted,
        volumeBoost: app.volumeBoost,
        equalizerSettings: restoredEqualizer ?? existingEqualizer,
        targetDeviceUID: app.targetDeviceUID
      )
    case .unavailable:
      return PersistedAppAudioIntent(
        appID: entry.appID,
        desiredVolume: entry.desiredVolume ?? existing?.desiredVolume ?? 1,
        isMuted: entry.isMuted ?? existing?.isMuted ?? false,
        volumeBoost: entry.volumeBoost ?? existing?.volumeBoost ?? 1,
        equalizerSettings: entry.equalizer ?? existingEqualizer,
        targetDeviceUID: entry.output.map(\.deviceUID) ?? existing?.targetDeviceUID
      )
    case .membershipOnly, .superseded, .excluded, .unsupported, .failed:
      return nil
    }
  }

  private func profileResultMarkingNewerAppTransactionsSuperseded(
    _ result: ProfileApplyResult,
    profile: Profile,
    generation: UInt64
  ) -> ProfileApplyResult {
    let rows = zip(profile.entries, result.rows).map { entry, row in
      guard entry.hasLevels,
        appIntentCoordinator.hasNewerGeneration(than: generation, for: entry.appID)
      else {
        return row
      }
      return ProfileRowApplyResult(
        entryIndex: row.entryIndex,
        appID: row.appID,
        generation: row.generation,
        outcome: .superseded,
        resultingApp: nil,
        detail: "A newer direct app transaction superseded this profile row."
      )
    }
    return ProfileApplyResult(rows: rows, backendStatus: result.backendStatus)
  }

  /// Whether a landed row really restored its EQ and output. Both live in
  /// Waves' own route, so a row that landed while another router (Wave Link)
  /// controls the app changed its level there but not its EQ or output.
  static func profileRowRestoredSound(
    _ entry: ProfileEntry,
    row: ProfileRowApplyResult
  ) -> Bool {
    guard row.outcome == .applied || row.outcome == .noChange,
      let app = row.resultingApp, app.routingState == .managed
    else { return false }
    if let output = entry.output, app.targetDeviceUID != output.deviceUID { return false }
    return true
  }

  /// Plain sentences for the EQ and output parts of a profile that did not
  /// apply: outputs left alone because their device is not connected, and apps
  /// whose EQ or output another router controls.
  private func profileSoundNotes(
    _ profile: Profile,
    result: ProfileApplyResult,
    skippedOutputs: [SkippedProfileOutput]
  ) -> ProfileSoundNotes {
    var notes = ProfileSoundNotes()
    notes.affectedAppIDs.formUnion(skippedOutputs.map(\.appID))
    let withheldFromLink = skippedOutputs.filter(\.withheldFromLink)
    if !withheldFromLink.isEmpty {
      let appNames = withheldFromLink.map { profileAppName(for: $0.appID) }
      notes.sentences.append(
        "Links can't move apps to another output, so \(Self.listPhrase(appNames))"
          + (appNames.count == 1 ? " kept its output." : " kept their outputs.")
      )
    }
    let skippedOutputs = skippedOutputs.filter { !$0.withheldFromLink }
    if !skippedOutputs.isEmpty {
      var deviceNames: [String] = []
      for name in skippedOutputs.map({ $0.deviceName ?? "a saved output device" })
      where !deviceNames.contains(name) {
        deviceNames.append(name)
      }
      let appNames = skippedOutputs.map { profileAppName(for: $0.appID) }
      let devices = Self.listPhrase(deviceNames)
      notes.sentences.append(
        devices.prefix(1).uppercased() + devices.dropFirst()
          + (deviceNames.count == 1 ? " isn't" : " aren't")
          + " connected, so \(Self.listPhrase(appNames))"
          + (appNames.count == 1 ? " kept its output." : " kept their outputs.")
      )
    }

    var heldElsewhere: [(appID: String, viaWaveLink: Bool)] = []
    var heldParts: Set<String> = []
    for (entry, row) in zip(profile.entries, result.rows) where entry.restoresSound {
      guard row.outcome == .applied || row.outcome == .noChange || row.outcome == .unsupported,
        let app = row.resultingApp,
        !Self.profileRowRestoredSound(entry, row: row),
        !preferences.excludedAppIDs.contains(entry.appID)
      else { continue }
      heldElsewhere.append((entry.appID, app.routeHealthContext == .waveLinkBridge))
      notes.affectedAppIDs.insert(entry.appID)
      if entry.equalizer != nil { heldParts.insert("EQ") }
      if entry.output != nil { heldParts.insert("output") }
    }
    if !heldElsewhere.isEmpty {
      let names = Self.listPhrase(heldElsewhere.map { profileAppName(for: $0.appID) })
      let parts = heldParts.count == 2 ? "EQ and output" : heldParts.first ?? "EQ"
      let possessive = heldElsewhere.count == 1 ? "its" : "their"
      let verb = heldParts.count == 2 ? "weren't" : "wasn't"
      let controller =
        heldElsewhere.allSatisfy(\.viaWaveLink)
        ? "Wave Link controls \(names)"
        : "Waves isn't routing \(names) right now"
      notes.sentences.append("\(controller), so \(possessive) \(parts) \(verb) changed.")
      notes.routerHeldSound = true
    }
    return notes
  }

  private func profileAppName(for appID: String) -> String {
    session.apps.first(matchingAppKey: appID)?.displayName
      ?? FriendlyAppName.resolve(appID, in: session.apps)
  }

  /// "A", "A and B", "A, B, and C", or "A, B, and 2 more". Waves' copy is
  /// English-only, so this does not follow the system's list style.
  nonisolated static func listPhrase(_ items: [String]) -> String {
    let shown = items.count > 3 ? Array(items.prefix(2)) + ["\(items.count - 2) more"] : items
    switch shown.count {
    case 0: return ""
    case 1: return shown[0]
    case 2: return "\(shown[0]) and \(shown[1])"
    default: return shown.dropLast().joined(separator: ", ") + ", and " + shown[shown.count - 1]
    }
  }

  private func presentProfileFeedback(
    _ profile: Profile,
    result: ProfileApplyResult,
    persistenceResult: ProfilePersistenceResult,
    soundNotes: ProfileSoundNotes
  ) {
    let actionableRows = zip(profile.entries, result.rows).filter { entry, _ in entry.hasLevels }
    guard !actionableRows.isEmpty else {
      // Dropping every unconnected output can leave nothing to apply; the
      // skipped devices still have to be named.
      guard soundNotes.isEmpty else {
        showToast(
          title: "Profile partly applied",
          detail: soundNotes.sentences.joined(separator: " "),
          kind: soundNotes.routerHeldSound ? .warning : .info,
          duration: .seconds(4)
        )
        return
      }
      showToast(
        title: "Profile selected",
        detail: "\(profile.name) — \(profile.entries.count) \(profile.entries.count == 1 ? "app" : "apps")",
        kind: .info,
        duration: .seconds(1.4)
      )
      return
    }

    func count(_ outcome: ProfileRowApplyOutcome) -> Int {
      actionableRows.count { $0.1.outcome == outcome }
    }
    let appliedCount = count(.applied) + count(.noChange)
    let unavailableCount = count(.unavailable)
    let excludedCount = count(.excluded)
    let failedCount = count(.failed)
    let unsupportedCount = count(.unsupported)
    let supersededCount = count(.superseded)
    let hasOutcomeWarning = excludedCount + failedCount + unsupportedCount + supersededCount > 0
    let levelsFullyApplied =
      appliedCount == actionableRows.count
      && unavailableCount == 0
      && !hasOutcomeWarning
      && persistenceResult.isFullySaved

    if levelsFullyApplied, soundNotes.isEmpty {
      showToast(
        title: "Profile applied",
        detail: profile.name,
        kind: .success,
        duration: .seconds(1.4)
      )
      return
    }
    if levelsFullyApplied {
      // A device that isn't plugged in is ordinary; a router holding the
      // app's EQ or output is worth a warning.
      showToast(
        title: "Profile partly applied",
        detail: soundNotes.sentences.joined(separator: " "),
        kind: soundNotes.routerHeldSound ? .warning : .info,
        duration: .seconds(4)
      )
      return
    }

    var summary: [String] = []
    if appliedCount > 0 { summary.append("\(appliedCount) applied") }
    if unavailableCount > 0, persistenceResult.settingsError == nil {
      summary.append("\(unavailableCount) saved for later")
    } else if unavailableCount > 0 {
      summary.append("\(unavailableCount) unavailable")
    }
    if excludedCount > 0 { summary.append("\(excludedCount) excluded") }
    if failedCount > 0 { summary.append("\(failedCount) failed") }
    if unsupportedCount > 0 { summary.append("\(unsupportedCount) unsupported") }
    if supersededCount > 0 { summary.append("\(supersededCount) superseded") }
    if let settingsError = persistenceResult.settingsError {
      summary.append("settings not saved: \(settingsError)")
    }
    if let devicePresetError = persistenceResult.devicePresetError {
      summary.append("device preset not saved: \(devicePresetError)")
    }

    let title: String
    let kind: AppToast.Kind
    if failedCount > 0 || persistenceResult.settingsError != nil {
      title =
        appliedCount == 0 && unavailableCount == 0
        ? "Profile apply failed"
        : "Profile applied with errors"
      kind = .error
    } else if hasOutcomeWarning || persistenceResult.devicePresetError != nil {
      title = "Profile partly applied"
      kind = .warning
    } else if appliedCount > 0 && unavailableCount > 0 {
      title = "Profile partly applied"
      kind = .info
    } else if unavailableCount > 0 {
      title = "Profile saved for later"
      kind = .info
    } else {
      title = "Profile not applied"
      kind = .warning
    }
    showToast(
      title: title,
      detail: soundNotes.isEmpty
        ? summary.joined(separator: ", ")
        : ([summary.joined(separator: ", ") + "."] + soundNotes.sentences).joined(separator: " "),
      kind: kind,
      duration: soundNotes.isEmpty ? .seconds(2.8) : .seconds(4)
    )
  }

  /// Discards every saved per-device volume/mute/boost preset — the escape
  /// hatch for Settings > Mixer's "Clear All Saved Levels", for a user who
  /// wants to start over rather than have Waves keep re-applying old levels
  /// per device. Does not touch the `enablePerDeviceVolumePresets` preference
  /// itself, only the accumulated data.
  func clearDeviceVolumePresets() {
    deviceVolumePresets = DeviceVolumePresets()
    persistDeviceVolumePresets()
  }

  // MARK: - Profiles

  /// Visible apps that belong to `profile`, in the current sort order.
  func apps(in profile: Profile) -> [AudioApp] {
    let ids = Set(profile.appIDs)
    return visibleApps.filter { ids.contains($0.logicalID) }
  }

  /// The mute the user chose for `app`, with an automatic conferencing mute set
  /// aside.
  ///
  /// An automatic mute is session-only. A capture that copied `app.isMuted`
  /// while a call had media muted would save that mute into a profile or a
  /// restore point, and applying either later would mute the app for good.
  func userMute(for app: AudioApp) -> Bool {
    guard app.isMuted, app.muteSource == .autoConferencing else { return app.isMuted }
    return preferences.appAudioIntents[app.logicalID]?.isMuted ?? false
  }

  // MARK: - Mix restore point ("Reset Mix")

  /// Snapshots the current volume/mute/boost of every visible app, taken right
  /// before `profile` changes the mix. Covers ALL visible apps, not just the
  /// profile's members: restoring only member levels would leave any app the
  /// user tweaked mid-session stranded at its session value.
  private func captureMixRestorePoint(before profile: Profile) {
    let entries = visibleApps.map { app -> ProfileEntry in
      // Only apps whose mix Waves actually owns get a level-bearing entry.
      //
      // Capturing levels for every visible app made Reset Mix a mass-enrollment
      // button: a level-bearing entry has `hasLevels == true`, so applying the
      // restore point sent a route intent for every running app — building a
      // process tap, a private aggregate device, and a live IOProc for each one,
      // for apps the user had never touched. Worse, `persistProfileRows` then
      // wrote a durable intent for each, so every subsequent launch replayed the
      // whole set. Untouched apps still need a membership-only entry so the
      // restore point remembers they were present, but nothing about their
      // levels needs restoring — they were never changed.
      let isOwned =
        app.routingState == .managed
        || preferences.appAudioIntents[app.logicalID] != nil
      guard isOwned else { return ProfileEntry(appID: app.logicalID) }
      return ProfileEntry(
        appID: app.logicalID,
        desiredVolume: app.desiredVolume,
        isMuted: userMute(for: app),
        volumeBoost: app.volumeBoost
      )
    }
    guard entries.contains(where: \.hasLevels) else { return }
    mixRestorePoint = MixRestorePoint(
      profileName: profile.name,
      entries: entries,
      capturedAt: .now
    )
  }

  /// Puts every app back to the levels it had before the last profile apply,
  /// then clears the restore point and the active-profile highlight after the
  /// restored levels and their durable intents have both succeeded. The
  /// "meeting's over" button: apply Meeting, take the call, Reset Mix, and
  /// everything is where it was.
  func resetMix() {
    guard requireAudioRunning() else { return }
    guard let restorePoint = mixRestorePoint else { return }
    // An app that call automation has muted right now keeps that mute, and
    // automation keeps ownership of it so it still resumes when the call ends.
    // Sending the restore point's "not muted" as an explicit unmute would play
    // media over a call that is still in progress. Dropping the mute from the
    // row leaves the automatic mute alone and restores the rest of the row.
    let entries = restorePoint.entries.map { entry -> ProfileEntry in
      guard entry.isMuted == false,
        let app = session.apps.first(matchingAppKey: entry.appID),
        app.isMuted, app.muteSource == .autoConferencing
      else { return entry }
      var entry = entry
      entry.isMuted = nil
      return entry
    }
    let restoreProfile = Profile(
      name: restorePoint.profileName,
      entries: entries
    )
    applyProfile(restoreProfile, purpose: .mixReset)
  }

  /// Drops the restore point without applying it — for a user who decides the
  /// new mix IS the mix now.
  func discardMixRestorePoint() {
    mixRestorePoint = nil
  }

  // MARK: - Default profile

  /// The profile applied automatically when audio starts, if it still exists.
  var defaultProfile: Profile? {
    guard let id = preferences.defaultProfileID else { return nil }
    return profiles.first { $0.id == id }
  }

  /// Marks `profile` as the startup default (or clears it with nil). The
  /// default is applied once per launch when the audio backend reaches
  /// `.running`, so the user's baseline mix comes up without a manual apply.
  func setDefaultProfile(_ profile: Profile?) {
    preferences.defaultProfileID = profile?.id
    persistPreferences()
    if let profile {
      showToast(
        title: "Default profile set",
        detail: "\(profile.name) is applied when Waves starts.",
        kind: .success,
        duration: .seconds(1.8)
      )
    }
  }

  /// Applies the saved default profile once audio is running. Called from
  /// startup only; a reset-purpose apply so it never creates a restore point
  /// (there is no "before" mix worth returning to at launch).
  func applyDefaultProfileAtStartupIfNeeded() {
    guard let profile = defaultProfile, profile.carriesLevels else { return }
    applyProfile(profile, purpose: .defaultAtStartup)
  }

  /// Marks a profile as the active one and signals the main window to focus it.
  private func focusProfile(_ id: UUID) {
    activeProfileID = id
    profileFocusToken &+= 1
  }

  /// Creates or updates a profile from a chosen set of apps. When `captureLevels`
  /// is true, each app's current volume/mute/boost is baked into its entry;
  /// otherwise the entries are membership-only (a pure grouping). Pass an `id`
  /// to edit an existing profile in place (so a rename keeps its identity);
  /// otherwise a new profile is appended and duplicate names are rejected.
  @discardableResult
  func saveProfile(
    id: UUID? = nil,
    named name: String,
    appIDs: [String],
    captureLevels: Bool,
    includeEqualizer: Bool = false,
    includeOutput: Bool = false
  ) -> ProfileSaveResult {
    guard startupState != .shuttingDown else { return .unavailableDuringShutdown }
    // Mid-apply, an app's row still shows its old levels while its restored EQ
    // is already confirmed; capturing then would save a mix that never existed.
    if captureLevels, appIntentCoordinator.currentProfileTask != nil {
      return .profileStillApplying
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return .blankName }
    guard trimmedName.count <= 100 else { return .nameTooLong(maximum: 100) }

    // An explicit id identifies an edit. A create request must never replace an
    // existing same-named profile silently; callers receive a typed duplicate
    // result and can keep their editor state intact.
    let targetIndex = id.flatMap { id in profiles.firstIndex(where: { $0.id == id }) }

    if let collision = profiles.firstIndex(where: {
      $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
    }), collision != targetIndex {
      return .duplicateName(profiles[collision].name)
    }

    // Never bake an excluded app into a profile — applying it later would re-tap
    // an app the user explicitly told Waves to leave alone. Preserve the chosen
    // order while removing duplicates.
    let excluded = Set(preferences.excludedAppIDs)
    let appByID = Dictionary(session.apps.map { ($0.logicalID, $0) }, uniquingKeysWith: { first, _ in first })
    // When editing without re-capturing, keep each existing member's stored
    // levels rather than discarding them — so adding one app to "Focus" doesn't
    // wipe the saved mix. Only an explicit "Capture current levels" re-snapshots.
    let existingEntries: [String: ProfileEntry] =
      targetIndex.map {
        Dictionary(profiles[$0].entries.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
      } ?? [:]
    var seen = Set<String>()
    let entries: [ProfileEntry] =
      appIDs
      .filter { !excluded.contains($0) && seen.insert($0).inserted }
      .map { appID in
        if captureLevels, let app = appByID[appID] {
          return ProfileEntry(
            appID: appID,
            desiredVolume: app.desiredVolume,
            isMuted: userMute(for: app),
            volumeBoost: app.volumeBoost,
            equalizer: includeEqualizer ? equalizerSettings(for: app) : nil,
            output: includeOutput
              ? ProfileOutput(deviceUID: app.targetDeviceUID, deviceName: targetDevice(for: app)?.name)
              : nil
          )
        }
        // Preserve a previously-saved level for an existing member; otherwise the
        // entry is membership-only.
        return existingEntries[appID] ?? ProfileEntry(appID: appID)
      }

    guard !entries.isEmpty else { return .noEligibleApps }

    let savedProfileID: UUID
    if let targetIndex {
      var replacement = profiles[targetIndex]
      replacement.name = trimmedName
      replacement.entries = entries
      replacement.updatedAt = .now
      profiles[targetIndex] = replacement
      focusProfile(replacement.id)
      savedProfileID = replacement.id
    } else {
      let profile = Profile(name: trimmedName, entries: entries)
      profiles.append(profile)
      focusProfile(profile.id)
      savedProfileID = profile.id
    }
    persistProfilesWithFeedback(
      profiles,
      successTitle: "Profile saved",
      successDetail: trimmedName,
      failureTitle: "Profile not saved"
    )
    return .saved(savedProfileID)
  }

  /// The apps "Save Current Mix" captures: visible apps whose sound Waves is
  /// managing or has saved settings for. Untouched apps are left out — a level
  /// for each of them would make applying the profile take over every running
  /// app, the same mass-enrollment trap the Reset Mix restore point avoids.
  var currentMixAppIDs: [String] {
    let excluded = Set(preferences.excludedAppIDs)
    return visibleApps.compactMap { app in
      guard !excluded.contains(app.logicalID),
        app.routingState == .managed || preferences.appAudioIntents[app.logicalID] != nil
      else { return nil }
      return app.logicalID
    }
  }

  /// Saves what the user hears now as a new profile in one step: the current
  /// levels of every app in `currentMixAppIDs`, plus each app's EQ and output
  /// when asked.
  @discardableResult
  func saveCurrentMix(
    named name: String,
    includeEqualizer: Bool,
    includeOutput: Bool
  ) -> ProfileSaveResult {
    let result = saveProfile(
      named: name,
      appIDs: currentMixAppIDs,
      captureLevels: true,
      includeEqualizer: includeEqualizer,
      includeOutput: includeOutput
    )
    return result == .noEligibleApps ? .noMixToSave : result
  }

  /// Asks the main window to show the Save Current Mix sheet. Same
  /// request/token shape as the mute-shortcut request: the menu bar can raise
  /// this while the main window does not exist yet.
  func requestSaveCurrentMix() {
    saveCurrentMixRequested = true
    saveCurrentMixToken &+= 1
  }

  func consumeSaveCurrentMixRequest() -> Bool {
    defer { saveCurrentMixRequested = false }
    return saveCurrentMixRequested
  }

  func deleteProfiles(at offsets: IndexSet) {
    guard startupState != .shuttingDown else { return }
    let removedIDs = offsets.map { profiles[$0].id }
    profiles.remove(atOffsets: offsets)
    if let active = activeProfileID, removedIDs.contains(active) {
      activeProfileID = nil
    }
    // A deleted profile can't stay the startup default.
    if let defaultID = preferences.defaultProfileID, removedIDs.contains(defaultID) {
      preferences.defaultProfileID = nil
      persistPreferences()
    }
    if !offsets.isEmpty {
      persistProfilesWithFeedback(
        profiles,
        successTitle: "Profile removed",
        successDetail: "Removed from your profiles.",
        failureTitle: "Profile removal not saved",
        successKind: .info,
        duration: .seconds(1.1)
      )
    }
  }

  func exportProfile(_ profile: Profile) {
    guard startupState != .shuttingDown else { return }
    startOwnedOperation { store in
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        // Write the same versioned, array-shaped envelope as profiles.json
        // (VersionedPayload<[Profile]>) so the share file is self-describing
        // (carries schemaVersion for forward-compat) and interchangeable with
        // the persisted format. decodeImportedProfiles accepts this shape.
        let data = try PersistedSchema.encode([profile], using: encoder)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(profile.name).json"
        savePanel.canCreateDirectories = true

        // Anchor to the window hosting the control (the Settings window when it
        // is frontmost), not the mixer window. Settings can be opened from the
        // menu bar with the mixer window closed, leaving NSApp.mainWindow nil.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
          store.showToast(title: "Export failed", detail: "No window available.", kind: .error)
          return
        }

        let response = await savePanel.beginSheetModal(for: window)
        guard !Task.isCancelled, store.startupState != .shuttingDown else { return }
        if response == .OK, let url = savePanel.url {
          try data.write(to: url, options: .atomic)
          store.showToast(
            title: "Profile exported",
            detail: "Saved to \(url.lastPathComponent)",
            kind: .success,
            duration: .seconds(2.0)
          )
        }
      } catch {
        store.showToast(title: "Export failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func importProfiles() {
    guard startupState != .shuttingDown else { return }
    startOwnedOperation { store in
      let openPanel = NSOpenPanel()
      openPanel.allowedContentTypes = [.json]
      openPanel.canChooseFiles = true
      openPanel.canChooseDirectories = false
      openPanel.allowsMultipleSelection = false

      // Anchor to the window hosting the control (the Settings window when it is
      // frontmost). Settings can be opened from the menu bar with the mixer
      // window closed, leaving NSApp.mainWindow nil.
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        store.showToast(title: "Import failed", detail: "No window available.", kind: .error)
        return
      }

      let response = await openPanel.beginSheetModal(for: window)
      guard !Task.isCancelled, store.startupState != .shuttingDown else { return }
      if response == .OK, let url = openPanel.url {
        do {
          let sizeCap = 10 * 1024 * 1024
          let data: Data
          do {
            data = try BoundedRegularFileReader.read(from: url, maximumBytes: sizeCap)
          } catch BoundedRegularFileReaderError.fileTooLarge {
            store.showToast(title: "Import failed", detail: "This file is larger than the 10 MB limit.", kind: .error)
            return
          }

          // Accept the app's own profiles.json backup (a VersionedPayload<[Profile]>
          // envelope or a bare [Profile]) as well as a single exported Profile, so
          // restoring a backup doesn't fail with a cryptic generic decode error.
          guard let decoded = Self.decodeImportedProfiles(from: data) else {
            store.showToast(
              title: "Import failed",
              detail: "Unsupported file. Expected a Waves profile or profiles backup.",
              kind: .error
            )
            return
          }

          // Validate and build the entire batch into a local working copy BEFORE
          // touching the observed `profiles` array. Any validation failure returns
          // without having mutated `profiles`, so a multi-profile backup with a
          // single bad entry leaves the live library (and the UI) unchanged —
          // restoring the original atomic behavior for the multi-profile case.
          var working = store.profiles
          var importedNames: [String] = []
          for profile in decoded {
            // Validate profile structure. Trim first so a whitespace-only name is
            // rejected (isEmpty alone passes "   ") and bound the length to match
            // the editor's 100-character cap.
            let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
              store.showToast(title: "Import failed", detail: "Profile name cannot be empty.", kind: .error)
              return
            }

            if trimmedName.count > Profile.maxNameLength {
              store.showToast(title: "Import failed", detail: "Profile name exceeds \(Profile.maxNameLength) characters.", kind: .error)
              return
            }

            if profile.entries.count > Profile.maxEntries {
              store.showToast(title: "Import failed", detail: "Profile has too many entries (max \(Profile.maxEntries)).", kind: .error)
              return
            }

            // Keep an existing same-name profile intact. Imports get a clear,
            // unique name so restoring a file can never overwrite local work.
            let importedName = Self.uniqueImportedProfileName(trimmedName, among: working)
            var imported = profile
            imported.id = UUID()
            imported.name = importedName
            imported.createdAt = .now
            imported.updatedAt = .now
            working.append(imported)
            importedNames.append(importedName)
          }

          // Every profile passed — commit the batch atomically and persist once.
          store.profiles = working
          store.persistProfilesWithFeedback(
            working,
            successTitle: importedNames.count == 1 ? "Profile imported" : "Profiles imported",
            successDetail: importedNames.count == 1 ? importedNames.first : "\(importedNames.count) profiles restored",
            failureTitle: "Import not saved",
            duration: .seconds(2.0)
          )
        } catch {
          store.showToast(title: "Import failed", detail: error.localizedDescription, kind: .error)
        }
      }
    }
  }

  /// Decodes profiles from any shape Waves itself writes: the versioned
  /// `profiles.json` backup envelope (`VersionedPayload<[Profile]>`), a bare
  /// `[Profile]` array, or a single exported `Profile`. Also reads legacy
  /// `presets.json` backups, whose entries decode straight into level-bearing
  /// profiles. Returns nil when the data matches none of these.
  nonisolated static func decodeImportedProfiles(from data: Data) -> [Profile]? {
    let decoder = JSONDecoder()
    // The bounded decoder accepts the versioned envelope, legacy arrays, and a
    // single export while stopping before an oversized collection is decoded.
    return try? ProfilePayloadDecoder.decodeImportedProfiles(from: data, using: decoder)
  }

  nonisolated static func uniqueImportedProfileName(_ name: String, among profiles: [Profile]) -> String {
    // Match the editor's Unicode-aware collision semantics. `lowercased()` is
    // insufficient for cases such as German sharp S, and can disagree with
    // the case-insensitive comparison used by saveProfile.
    func containsName(_ candidate: String) -> Bool {
      profiles.contains { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    if !containsName(name) { return name }

    func candidate(suffix: String) -> String {
      let baseLength = max(0, Profile.maxNameLength - suffix.count)
      let base = String(name.prefix(baseLength))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return base + suffix
    }

    let firstCandidate = candidate(suffix: " (Imported)")
    if !containsName(firstCandidate) { return firstCandidate }
    var suffix = 2
    var numberedCandidate = candidate(suffix: " (Imported \(suffix))")
    while containsName(numberedCandidate) {
      suffix += 1
      numberedCandidate = candidate(suffix: " (Imported \(suffix))")
    }
    return numberedCandidate
  }

  func retrySavingProfiles() {
    guard startupState != .shuttingDown else { return }
    persistProfilesWithFeedback(
      profiles,
      successTitle: "Profiles saved",
      successDetail: "Your profile changes are saved.",
      failureTitle: "Profiles not saved"
    )
  }

  private func persistProfilesWithFeedback(
    _ snapshot: [Profile],
    successTitle: String,
    successDetail: String?,
    failureTitle: String,
    successKind: AppToast.Kind = .success,
    duration: Duration = .seconds(1.6)
  ) {
    startOwnedOperation { store in
      do {
        let savedCurrentSnapshot = try await store.persistenceCoordinator.saveProfilesDurably(snapshot)
        guard savedCurrentSnapshot else { return }
        for toast in store.toasts.filter({ $0.action == .retryProfiles }) {
          store.dismissToast(id: toast.id)
        }
        store.showToast(
          title: successTitle,
          detail: successDetail,
          kind: successKind,
          duration: duration
        )
      } catch is CancellationError {
        return
      } catch {
        guard store.profiles == snapshot else { return }
        store.showToast(
          title: failureTitle,
          detail: "Your changes are still open in Waves. \(error.localizedDescription)",
          kind: .warning,
          action: .retryProfiles
        )
      }
    }
  }

}
