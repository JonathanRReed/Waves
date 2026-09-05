import AppKit
import Foundation
import OSLog
import WavesAudioCore

// MARK: - External control (wavesctl / Stream Deck socket)

extension AppStore {
  func externalControlPreferenceChanged() {
    onExternalControlPreferenceChange?()
  }

  /// Surfaces a control-socket failure to the user. The plugin will show its own
  /// "can't reach Waves" state, but the reason lives here, where it can be acted
  /// on.
  func reportExternalControlUnavailable() {
    showToast(
      title: "External control unavailable",
      detail: "Waves could not open its control socket. Stream Deck control will not work.",
      kind: .warning
    )
  }

  /// Pushes whatever actually changed since the last push.
  ///
  /// Driven by change detection rather than by instrumenting every mutation
  /// site. A Stream Deck key has to reflect a mute made with the mouse, by a
  /// profile apply, by a keyboard shortcut, or by the app quitting — and hooking
  /// each of those individually is how one gets missed. Comparing the rendered
  /// state catches all of them, including changes Waves makes to itself.
  ///
  /// Costs nothing when no one is listening: the roster is not even built.
  func broadcastControlStateIfChanged() {
    guard let controlBroadcast else {
      // Nothing subscribed. Drop the baseline so a later subscriber gets a fresh
      // picture rather than diffing against a stale one.
      if !lastBroadcastControlApps.isEmpty { lastBroadcastControlApps = [:] }
      return
    }

    let current = controlApps()
    let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

    // Roster changes first: a client that learns an app appeared or vanished
    // re-lists, which supersedes any per-app push for it.
    if Set(currentByID.keys) != Set(lastBroadcastControlApps.keys) {
      lastBroadcastControlApps = currentByID
      controlBroadcast(ControlResponse(ok: true, event: .appsChanged))
      return
    }

    for app in current where lastBroadcastControlApps[app.id] != app {
      var response = ControlResponse(ok: true, event: .appChanged)
      response.changed = app
      controlBroadcast(response)
    }
    lastBroadcastControlApps = currentByID
  }

  /// The roster as the control surface describes it.
  ///
  /// Built from `visibleApps`, so an app the user has hidden from the mixer is
  /// also absent from a Stream Deck's dropdown — one notion of "the apps Waves
  /// shows you", not two that can disagree.
  func controlApps() -> [ControlApp] {
    visibleApps.map { app in
      ControlApp(
        id: app.logicalID,
        name: app.displayName,
        running: app.pid != nil,
        muted: app.isMuted,
        volume: app.desiredVolume,
        live: isLive(app),
        managed: app.routingState == .managed
      )
    }
  }

  /// Resolves a control-surface identifier back to a real app.
  func controlApp(forID logicalID: String) -> AudioApp? {
    visibleApps.first { $0.logicalID == logicalID }
  }

  var hasActiveSessionMaintenance: Bool {
    sessionMaintenanceTask != nil
  }

  var launchAtLoginEnabled: Bool {
    get { preferences.launchAtLoginEnabled }
    set {
      do {
        try loginItemService.setEnabled(newValue)
        let status = loginItemService.status
        loginItemStatus = status
        preferences.launchAtLoginEnabled = status.isUserIntentEnabled
        onboarding.launchAtLoginEnabled = status.isEnabled
        onboarding.launchAtLoginRequiresApproval = status.requiresApproval
        persistPreferences()
        if status.isEnabled != newValue {
          // Only the .requiresApproval case actually points the user at the
          // System Settings approval path. Other failures (.notRegistered /
          // .notFound / @unknown) are generic enable failures and must not be
          // mislabeled as an approval issue.
          let needsApproval = status.requiresApproval
          showToast(
            title: needsApproval ? "Login item needs approval" : "Couldn't enable Launch at login",
            detail: status.statusDescription,
            kind: .warning,
            duration: .seconds(2.4)
          )
        }
      } catch {
        let status = loginItemService.status
        loginItemStatus = status
        preferences.launchAtLoginEnabled = status.isUserIntentEnabled
        onboarding.launchAtLoginEnabled = status.isEnabled
        onboarding.launchAtLoginRequiresApproval = status.requiresApproval
        persistPreferences()
        showToast(title: "Login item update failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  var launchAtLoginRequiresApproval: Bool {
    loginItemStatus.requiresApproval
  }

  var launchAtLoginStatusDescription: String {
    loginItemStatus.statusDescription
  }

  func openLoginItemsSettings() {
    loginItemService.openSystemSettingsLoginItems()
  }

  func start() {
    performSafeBootstrapIfNeeded()

    switch startupState {
    case .savingPrivacyConsent, .startingAudio, .running, .failed, .shuttingDown:
      return
    case .idle, .awaitingPrivacy:
      break
    }

    guard preferences.hasCompletedPrivacySetup else {
      startupState = .awaitingPrivacy
      isLoading = false
      return
    }

    beginAudioStartupIfNeeded()
  }

  /// Accepts the local-processing explanation, makes that choice durable, and only
  /// then starts the capture-capable audio backend. Reusing this action after a
  /// startup failure retries audio without asking for consent again.
  func acceptPrivacySetupAndStart() async {
    performSafeBootstrapIfNeeded()
    guard startupState != .shuttingDown else { return }

    if let privacySetupTask {
      await privacySetupTask.value
      return
    }

    if preferences.hasCompletedPrivacySetup {
      beginAudioStartupIfNeeded()
      await audioStartupTask?.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.persistPrivacyConsentAndStartAudio()
    }
    privacySetupTask = task
    await task.value
  }

  func waitForAudioStartup() async {
    await audioStartupTask?.value
  }

  func promptToFinishSetup() {
    presentFinishSetupMessage()
  }

  func completeRequiredSetup(version: Int) async -> Bool {
    guard startupState != .shuttingDown,
      version == OnboardingExperience.currentVersion,
      guidedSetupFacts.isReadyForCoreMixing
    else {
      return false
    }

    let completesFirstRun = preferences.requiredSetupVersion < version
    var completedPreferences = preferences
    completedPreferences.requiredSetupVersion = max(
      completedPreferences.requiredSetupVersion,
      version
    )
    completedPreferences.hasCompletedGuidedSetup = true
    if completesFirstRun {
      completedPreferences.whatsNewDismissedVersion = max(
        completedPreferences.whatsNewDismissedVersion,
        version
      )
    }

    do {
      try await persistenceCoordinator.savePreferencesDurably(
        completedPreferences,
        mergePendingWith: { pending in
          pending.requiredSetupVersion = max(pending.requiredSetupVersion, version)
          pending.hasCompletedGuidedSetup = true
          if completesFirstRun {
            pending.whatsNewDismissedVersion = max(
              pending.whatsNewDismissedVersion,
              version
            )
          }
        },
        onDurable: { [weak self] in
          guard let self else { return }
          preferences.requiredSetupVersion = max(
            preferences.requiredSetupVersion,
            version
          )
          preferences.hasCompletedGuidedSetup = true
          if completesFirstRun {
            preferences.whatsNewDismissedVersion = max(
              preferences.whatsNewDismissedVersion,
              version
            )
          }
          requestedSetupReplay = false
        }
      )
      return true
    } catch {
      reportPersistenceFailure(store: .preferences, error: error, showWarning: false)
      showToast(
        title: "Setup may appear again",
        detail: "Waves is ready to mix, but the completed setup state could not be saved. \(error.localizedDescription)",
        kind: .warning
      )
      return false
    }
  }

  private func performSafeBootstrapIfNeeded() {
    guard !isSafeBootstrapComplete else { return }
    isSafeBootstrapComplete = true
    isLoading = false
    syncOnboarding(using: session)
  }

  private func persistPrivacyConsentAndStartAudio() async {
    startupState = .savingPrivacyConsent
    privacySetupError = nil
    preferences.hasCompletedPrivacySetup = true
    onboarding.hasCompletedPrivacySetup = true

    do {
      try await savePreferencesDurably()
    } catch {
      preferences.hasCompletedPrivacySetup = false
      onboarding.hasCompletedPrivacySetup = false
      privacySetupError = "Waves couldn't save your setup choice. Check that your user Library is writable, then try again. \(error.localizedDescription)"
      startupState = .awaitingPrivacy
      privacySetupTask = nil
      reportPersistenceFailure(store: .privacySetup, error: error, showWarning: false)
      showToast(
        title: "Setup wasn't saved",
        detail: privacySetupError,
        kind: .error
      )
      return
    }

    privacySetupTask = nil
    guard !Task.isCancelled, startupState != .shuttingDown else { return }
    beginAudioStartupIfNeeded()
    await audioStartupTask?.value
  }

  private func beginAudioStartupIfNeeded() {
    guard preferences.hasCompletedPrivacySetup else {
      startupState = .awaitingPrivacy
      return
    }
    guard audioStartupTask == nil else { return }
    guard startupState != .running, startupState != .shuttingDown else { return }

    startupState = .startingAudio
    privacySetupError = nil
    isLoading = session.apps.isEmpty
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performAudioStartup()
    }
    audioStartupTask = task
  }

  private func performAudioStartup() async {
    defer {
      isLoading = false
      audioStartupTask = nil
    }

    do {
      let warmSnapshot = session
      if !warmSnapshot.apps.isEmpty {
        syncOnboarding(using: session)
      }

      await backend.setWaveLinkCompatibilityEnabled(preferences.waveLinkCompatibilityEnabled)
      await backend.setPerAppAudioController(preferences.perAppAudioController)
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      try await backend.start()
      // Even if shutdown began while backend.start() was suspended, record the
      // successful native start so the checked shutdown path tears it back down.
      hasStartedAudioBackend = true
      LaunchPerformanceRecorder.active?.mark(.backendStarted)
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      await backend.setManagedAudioEqualizer(preferences.managedAudioEqualizer)
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      let built = await backend.currentSnapshot()
      LaunchPerformanceRecorder.active?.mark(.snapshotReady)
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      session = mergedSession(with: built, cached: warmSnapshot)
      cleanupStaleEntries()
      await reapplyRestoredAudioState()
      LaunchPerformanceRecorder.active?.mark(.restoredRoutesReady)
      if preferences.adaptiveMixMode.usesSpeechFocus,
        preferences.autoPauseMusicForConferencing
      {
        preferences.autoPauseMusicForConferencing = false
        persistPreferences()
      }
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      availableDevices = await backend.availableOutputDevices()
      persistSessionSnapshot()
      syncOnboarding(using: session)

      observeDeviceChanges()
      observeFrontmostAppChanges()
      observeAppTermination()
      startupState = .running
      requestWaveLinkRouteRecoveryIfNeeded()
      startSessionMaintenance()
      restartAdaptiveMixing()
      startLiveLevelPollingIfNeeded()
      checkAutoPauseMusic()
      presentRecoveredStoreWarningIfNeeded()
      showToast(title: "Waves is ready", detail: "Per-app audio mixer loaded.", kind: .success)
      applyDefaultProfileAtStartupIfNeeded()
    } catch {
      guard startupState != .shuttingDown else { return }
      let detail = error.localizedDescription
      startupState = .failed(detail)
      privacySetupError = detail
      showToast(title: "Startup failed", detail: detail, kind: .error, duration: .seconds(3.2))
    }
  }

  private func presentRecoveredStoreWarningIfNeeded() {
    // One combined toast for every store that had to reset a corrupted file — the
    // originals are preserved beside the replacements, and the user deserves to
    // know both facts instead of seeing a silent reset.
    var recoveredStores: [String] = []
    if didRecoverCorruptDeviceVolumePresets { recoveredStores.append("device presets") }
    if didRecoverCorruptProfiles { recoveredStores.append("profiles") }
    if didRecoverCorruptPreferences { recoveredStores.append("settings") }
    if didRecoverCorruptSession { recoveredStores.append("session") }
    didRecoverCorruptDeviceVolumePresets = false
    didRecoverCorruptProfiles = false
    didRecoverCorruptPreferences = false
    didRecoverCorruptSession = false
    if !recoveredStores.isEmpty {
      showToast(
        title: "Saved data recovered",
        detail: "Corrupted \(recoveredStores.joined(separator: ", ")) reset to defaults. Originals kept as .corrupt files.",
        kind: .warning
      )
    }
  }

  @discardableResult
  func requireAudioRunning() -> Bool {
    guard startupState == .running else {
      presentFinishSetupMessage()
      return false
    }
    return true
  }

  @discardableResult
  func startOwnedOperation(
    _ operation: @escaping @MainActor @Sendable (AppStore) async -> Void
  ) -> Bool {
    guard startupState != .shuttingDown else { return false }
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.ownedOperationTasks.removeValue(forKey: id) }
      await operation(self)
    }
    ownedOperationTasks[id] = task
    return true
  }

  private func presentFinishSetupMessage() {
    guard !toasts.contains(where: { $0.title == "Finish setup" }) else { return }
    let detail: String
    switch startupState {
    case .startingAudio, .savingPrivacyConsent:
      detail = "Waves is still finishing setup. Wait a moment, then try again."
    case .failed:
      detail = "Waves couldn't start. Use Retry Start Waves on the setup screen."
    case .idle, .awaitingPrivacy:
      detail = "Choose Continue and Start Waves before using audio controls."
    case .running:
      return
    case .shuttingDown:
      detail = "Waves is closing and can't change audio now."
    }
    showToast(title: "Finish setup", detail: detail, kind: .warning)
  }

  func refresh(
    announce: Bool = true,
    reevaluateAutomation: Bool = true
  ) {
    guard requireAudioRunning() else { return }
    guard !isRefreshing else { return }

    isRefreshing = true
    isLoading = session.apps.isEmpty
    startOwnedOperation { store in
      await store.performRefresh(
        announce: announce,
        reevaluateAutomation: reevaluateAutomation
      )
    }
  }

  private func performRefresh(
    announce: Bool,
    reevaluateAutomation: Bool
  ) async {
    defer {
      isRefreshing = false
      isLoading = false
    }

    do {
      let knownAppIDs = Set(session.apps.map(\.logicalID))
      let refreshed = try await backend.refresh()
      guard !Task.isCancelled, startupState == .running else { return }
      session = mergedSession(with: refreshed, cached: session)
      cleanupStaleEntries()
      await restoreNewlyAppearedConfiguredApps(excluding: knownAppIDs)
      guard !Task.isCancelled, startupState == .running else { return }
      persistSessionSnapshot()
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      syncOnboarding(using: session)
      if reevaluateAutomation {
        checkAutoPauseMusic()
      }
      if announce {
        let visibleCount = visibleApps.count
        showToast(title: "Library refreshed", detail: "\(visibleCount) app\(visibleCount == 1 ? "" : "s") detected.", kind: .info)
      }
    } catch {
      guard startupState == .running else { return }
      showToast(title: "Refresh failed", detail: error.localizedDescription, kind: .error)
    }
  }

  private func startSessionMaintenance() {
    guard startupState == .running else { return }
    guard sessionMaintenanceTask == nil else { return }
    sessionMaintenanceStartCount += 1
    sessionMaintenanceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: self.sessionMaintenanceInterval)
        guard !Task.isCancelled else { return }
        await self.performSilentSessionRefresh()
      }
    }
  }

  func performSilentSessionRefresh() async {
    guard startupState == .running,
      !isRefreshing,
      !isRecovering,
      !isLoading,
      !isRunningSessionMaintenance,
      !appIntentCoordinator.hasPendingVolumeTargets()
    else {
      return
    }

    isRunningSessionMaintenance = true
    defer { isRunningSessionMaintenance = false }

    do {
      let knownAppIDs = Set(session.apps.map(\.logicalID))
      let rebuilt = try await backend.refresh()
      let merged = mergedSession(with: rebuilt, cached: session)
      if !Self.sessionContentMatches(merged, session) {
        session = merged
        cleanupStaleEntries()
        await restoreNewlyAppearedConfiguredApps(excluding: knownAppIDs)
        persistSessionSnapshot()
      }
      let refreshedDiagnostics = await backend.diagnosticsReport(
        reprobeCaptureAuthorization: false
      )
      if !Self.diagnosticsContentMatches(refreshedDiagnostics, diagnostics) {
        diagnostics = refreshedDiagnostics
      }
      let captureAuthorization = await backend.captureAuthorizationResult()
      if onboarding.captureAuthorization != captureAuthorization {
        onboarding.captureAuthorization = captureAuthorization
      }
      let bridgeStatus = await backend.waveLinkBridgeStatus()
      if waveLinkBridgeStatus != bridgeStatus {
        waveLinkBridgeStatus = bridgeStatus
      }
      let devices = await backend.availableOutputDevices()
      if availableDevices != devices {
        availableDevices = devices
      }
      syncOnboarding(using: session)
      checkAutoPauseMusic()
    } catch {
      logger.debug("Silent session refresh failed: \(error.localizedDescription)")
    }
  }

  private static func sessionContentMatches(
    _ lhs: AudioSessionSnapshot,
    _ rhs: AudioSessionSnapshot
  ) -> Bool {
    var normalizedLHS = lhs
    var normalizedRHS = rhs
    normalizedLHS.updatedAt = .distantPast
    normalizedRHS.updatedAt = .distantPast
    return normalizedLHS == normalizedRHS
  }

  static func diagnosticsContentMatches(
    _ lhs: DiagnosticsReport,
    _ rhs: DiagnosticsReport?
  ) -> Bool {
    guard var normalizedRHS = rhs else { return false }
    var normalizedLHS = lhs
    normalizedLHS.generatedAt = .distantPast
    normalizedRHS.generatedAt = .distantPast
    guard
      normalizedLHS.generatedAt == normalizedRHS.generatedAt,
      normalizedLHS.summary == normalizedRHS.summary,
      normalizedLHS.checks.count == normalizedRHS.checks.count
    else {
      return false
    }
    return zip(normalizedLHS.checks, normalizedRHS.checks).allSatisfy { lhsCheck, rhsCheck in
      lhsCheck.title == rhsCheck.title
        && lhsCheck.status == rhsCheck.status
        && lhsCheck.detail == rhsCheck.detail
    }
  }

  func admitURLAutomationInvocation() -> Bool {
    urlInvocationLimiter.allow()
  }

  func handleURLScheme(_ url: URL, invocationAlreadyAdmitted: Bool = false) {
    guard preferences.enableURLScheme else {
      logger.warning("URL scheme invocation rejected because URL schemes are disabled")
      return
    }
    guard invocationAlreadyAdmitted || admitURLAutomationInvocation() else {
      logger.warning("URL scheme invocation rejected because the invocation limit was exceeded")
      return
    }
    guard requireAudioRunning() else { return }

    switch automationParser.parse(url) {
    case let .accepted(command):
      handleAutomationCommand(command)
    case let .rejected(rejection):
      logger.warning("URL scheme invocation rejected: \(rejection.message, privacy: .public)")
      if rejection.shouldPresent {
        showToast(
          title: "URL command blocked",
          detail: rejection.message,
          kind: .warning
        )
      }
    case let .throttled(shouldNotify):
      logger.warning("URL scheme invocation rejected because the rate limit was exceeded")
      if shouldNotify {
        showToast(
          title: "URL command throttled",
          detail: "Too many commands. Try again shortly.",
          kind: .warning
        )
      }
    }
  }

  private func handleAutomationCommand(_ command: AutomationCommand) {
    switch command {
    case let .setVolume(appID, volume):
      guard let app = session.apps.first(matchingAppKey: appID) else {
        showToast(
          title: "URL command blocked",
          detail: "App not found: \(String(appID.prefix(64)))",
          kind: .warning
        )
        return
      }
      guard !isExcluded(app) else {
        showToast(
          title: "URL command blocked",
          detail: "App is excluded from Waves.",
          kind: .warning
        )
        return
      }
      commitDesiredVolume(volume, for: app, reason: .automation)

    case let .setMuted(appID, isMuted):
      guard let app = session.apps.first(matchingAppKey: appID) else {
        showToast(
          title: "URL command blocked",
          detail: "App not found: \(String(appID.prefix(64)))",
          kind: .warning
        )
        return
      }
      guard !isExcluded(app) else {
        showToast(
          title: "URL command blocked",
          detail: "App is excluded from Waves.",
          kind: .warning
        )
        return
      }
      setMuted(isMuted, for: app, reason: .automation)

    case let .applyProfile(profileName):
      guard
        let profile = profiles.first(where: {
          $0.name.localizedCaseInsensitiveCompare(profileName) == .orderedSame
        })
      else {
        showToast(
          title: "Profile not found",
          detail: "No profile named: \(String(profileName.prefix(64)))",
          kind: .warning
        )
        return
      }
      applyProfile(profile, purpose: .automation)

    case .refresh:
      refresh()
    }
  }
}
