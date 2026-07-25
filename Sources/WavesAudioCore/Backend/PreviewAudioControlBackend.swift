import Foundation

public actor PreviewAudioControlBackend: AudioControlBackend {
  private var snapshot: AudioSessionSnapshot
  private var profiles: [Profile]
  private var equalizerSettings: [String: EqualizerSettings] = [:]
  private var managedAudioEqualizerSettings = GlobalEqualizerSettings()
  private var adaptiveGainsDB: [String: Float] = [:]
  private var latestAcceptedGenerationByLogicalID: [String: UInt64] = [:]
  private var legacyGeneration: UInt64 = 0
  private var isStopped = false

  // The preview backend has no real audio hardware, so it never reports device
  // changes. An immediately-finishing stream lets observers attach harmlessly.
  public nonisolated var deviceChangeEvents: AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }

  public init(
    snapshot: AudioSessionSnapshot = .preview,
    profiles: [Profile] = Profile.defaults
  ) {
    self.snapshot = snapshot
    self.profiles = profiles
  }

  public func start() async throws {
    isStopped = false
  }

  public func stop() async {
    isStopped = true
  }

  public func shutdownWithResult() async -> BackendShutdownResult {
    await stop()
    return BackendShutdownResult(completion: .clean)
  }

  public func currentSnapshot() async -> AudioSessionSnapshot {
    snapshot
  }

  public func refresh() async throws -> AudioSessionSnapshot {
    for index in snapshot.apps.indices {
      let boost = Float((index % 4) + 1) * 0.02
      let nextPeak = min(1, max(0, snapshot.apps[index].desiredVolume * 0.65 + boost))
      snapshot.apps[index].peakLevel = snapshot.apps[index].isMuted ? 0 : nextPeak
      snapshot.apps[index].rmsLevel = snapshot.apps[index].isMuted ? 0 : max(0, nextPeak - 0.08)
      snapshot.apps[index].routingState =
        snapshot.apps[index].compatibility == .supported ? .managed : .monitorOnly
      snapshot.apps[index].appliedVolume =
        snapshot.apps[index].compatibility == .supported ? snapshot.apps[index].desiredVolume : nil
    }

    snapshot.updatedAt = .now
    return snapshot
  }

  public func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    let app = try legacyApp(forAppID: appID)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: volume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost,
      equalizerSettings: equalizerSettings[app.logicalID] ?? EqualizerSettings(),
      targetDeviceUID: app.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  public func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    let app = try legacyApp(forAppID: appID)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: isMuted,
      volumeBoost: app.volumeBoost,
      equalizerSettings: equalizerSettings[app.logicalID] ?? EqualizerSettings(),
      targetDeviceUID: app.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  public func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    let app = try legacyApp(forAppID: appID)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: boost,
      equalizerSettings: equalizerSettings[app.logicalID] ?? EqualizerSettings(),
      targetDeviceUID: app.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  public func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {
    let app = try legacyApp(forAppID: appID)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost,
      equalizerSettings: settings,
      targetDeviceUID: app.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  public func setManagedAudioEqualizer(_ settings: GlobalEqualizerSettings) async {
    managedAudioEqualizerSettings = settings
  }

  func managedAudioEqualizerSettingsForTesting() -> GlobalEqualizerSettings {
    managedAudioEqualizerSettings
  }

  public func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] {
    snapshot.apps.reduce(into: [:]) { result, app in
      let rms = app.isMuted ? 0 : max(0, app.rmsLevel)
      let voiceRatio: Float = app.category == .conferencing ? 0.75 : 0.3
      result[app.logicalID] = AdaptiveAnalysisLevels(
        rms: rms,
        voiceBandEnergy: rms * rms * voiceRatio
      )
    }
  }

  public func setAdaptiveGains(_ gainsDB: [String: Float]) async {
    adaptiveGainsDB = gainsDB.reduce(into: [:]) { result, pair in
      let value = pair.value.isFinite ? pair.value : 0
      result[pair.key] = min(3, max(-18, value))
    }
  }

  public func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {
    if snapshot.currentDevice?.id == deviceID {
      snapshot.currentDevice?.volumeControlMode = mode
    }
  }

  public func pinApp(_ isPinned: Bool, appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isPinned = isPinned
  }

  public func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    guard let initialIndex = snapshot.apps.firstIndex(matchingAppKey: intent.appID) else {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unavailable,
        resultingApp: nil,
        backendStatus: snapshot.backendStatus,
        detail: "The app is not available in the current audio session."
      )
    }

    let logicalID = snapshot.apps[initialIndex].logicalID
    guard !isStopped else {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: snapshot.apps[initialIndex],
        backendStatus: snapshot.backendStatus,
        detail: "The preview audio backend is stopped."
      )
    }

    if let latestGeneration = latestAcceptedGenerationByLogicalID[logicalID],
       intent.generation < latestGeneration {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .superseded,
        resultingApp: snapshot.apps[initialIndex],
        backendStatus: snapshot.backendStatus,
        detail: "A newer app intent has already been accepted."
      )
    }
    latestAcceptedGenerationByLogicalID[logicalID] = intent.generation
    legacyGeneration = max(legacyGeneration, intent.generation)

    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) else {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unavailable,
        resultingApp: nil,
        backendStatus: snapshot.backendStatus,
        detail: "The app left the current audio session before its intent was applied."
      )
    }

    if intent.isExcluded {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].appliedVolume = nil
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
      snapshot.apps[index].notes = nil
      snapshot.updatedAt = .now
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .excluded,
        resultingApp: snapshot.apps[index],
        backendStatus: snapshot.backendStatus
      )
    }

    guard snapshot.apps[index].compatibility != .unsupported else {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unsupported,
        resultingApp: snapshot.apps[index],
        backendStatus: snapshot.backendStatus,
        detail: "This preview app does not support managed audio controls."
      )
    }

    let previousEqualizer = equalizerSettings[logicalID] ?? EqualizerSettings()
    let hasNoChanges = snapshot.apps[index].desiredVolume == intent.desiredVolume
      && snapshot.apps[index].isMuted == intent.isMuted
      && snapshot.apps[index].volumeBoost == intent.volumeBoost
      && snapshot.apps[index].targetDeviceUID == intent.targetDeviceUID
      && previousEqualizer == intent.equalizerSettings
      && snapshot.apps[index].routingState == .managed
      && snapshot.apps[index].appliedVolume == (intent.isMuted ? 0 : intent.desiredVolume)

    snapshot.apps[index].desiredVolume = intent.desiredVolume
    snapshot.apps[index].isMuted = intent.isMuted
    snapshot.apps[index].volumeBoost = intent.volumeBoost
    snapshot.apps[index].targetDeviceUID = intent.targetDeviceUID
    snapshot.apps[index].appliedVolume = intent.isMuted ? 0 : intent.desiredVolume
    snapshot.apps[index].routingState = .managed
    snapshot.apps[index].notes = nil
    if intent.isMuted {
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
    }
    equalizerSettings[logicalID] = intent.equalizerSettings
    snapshot.updatedAt = .now

    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: hasNoChanges ? .noChange : .applied,
      resultingApp: snapshot.apps[index],
      backendStatus: snapshot.backendStatus
    )
  }

  public func applyProfileWithResults(
    _ profile: Profile,
    generation: UInt64
  ) async -> ProfileApplyResult {
    var rows: [ProfileRowApplyResult] = []
    rows.reserveCapacity(profile.entries.count)

    for (entryIndex, entry) in profile.entries.enumerated() {
      guard entry.hasLevels else {
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .membershipOnly,
          resultingApp: nil
        ))
        continue
      }

      guard let appIndex = snapshot.apps.firstIndex(matchingAppKey: entry.appID) else {
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .unavailable,
          resultingApp: nil,
          detail: "The app is not available in the current audio session."
        ))
        continue
      }

      let app = snapshot.apps[appIndex]
      let result = await applyAppIntent(AppRouteIntent(
        appID: entry.appID,
        desiredVolume: entry.desiredVolume ?? app.desiredVolume,
        isMuted: entry.isMuted ?? app.isMuted,
        volumeBoost: entry.volumeBoost ?? app.volumeBoost,
        equalizerSettings: equalizerSettings[app.logicalID] ?? EqualizerSettings(),
        targetDeviceUID: app.targetDeviceUID,
        generation: generation,
        reason: .profileApply
      ))
      rows.append(ProfileRowApplyResult(
        entryIndex: entryIndex,
        appID: entry.appID,
        generation: generation,
        outcome: ProfileRowApplyOutcome(appIntentOutcome: result.outcome),
        resultingApp: result.resultingApp,
        detail: result.detail
      ))
    }

    return ProfileApplyResult(rows: rows, backendStatus: snapshot.backendStatus)
  }

  public func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot {
    let generation = nextLegacyGeneration()
    let result = await applyProfileWithResults(profile, generation: generation)
    if let failure = result.rows.first(where: { row in
      switch row.outcome {
      case .membershipOnly, .applied, .noChange, .excluded:
        false
      case .superseded, .unavailable, .unsupported, .failed:
        true
      }
    }) {
      throw BackendError.managedRouteUnavailable(
        failure.detail ?? "The profile could not be fully applied to \(failure.appID)."
      )
    }
    return snapshot
  }

  public func saveCurrentProfile(named name: String) async throws -> Profile {
    let profile = Profile(
      name: name,
      entries: snapshot.apps.map {
        ProfileEntry(
          appID: $0.logicalID,
          desiredVolume: $0.desiredVolume,
          isMuted: $0.isMuted,
          volumeBoost: $0.volumeBoost
        )
      }
    )
    profiles.append(profile)
    return profile
  }

  public func recoverRoutes() async throws -> AudioSessionSnapshot {
    snapshot.backendStatus.isRouteRecoveryHealthy = true
    snapshot.backendStatus.lastError = nil
    snapshot.updatedAt = .now
    return snapshot
  }

  public func autoRestoreDevice() async throws -> AudioSessionSnapshot {
    if !snapshot.recentDeviceIDs.isEmpty {
      snapshot.updatedAt = .now
    }
    return snapshot
  }

  public func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool) async {
    // No real audio routes in the preview backend.
  }

  public func availableOutputDevices() async -> [AudioDevice] {
    snapshot.currentDevice.map { [$0] } ?? []
  }

  public func setDefaultOutputDevice(uid: String) async throws {
    // No real hardware in the preview backend.
  }

  public func setOutputDevice(uid: String?, forAppID appID: String) async throws {
    let app = try legacyApp(forAppID: appID)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost,
      equalizerSettings: equalizerSettings[app.logicalID] ?? EqualizerSettings(),
      targetDeviceUID: uid,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  public func audioLevels() async -> [String: AudioLevels] {
    snapshot.apps.reduce(into: [:]) { result, app in
      result[app.logicalID] = AudioLevels(peak: app.peakLevel, rms: app.rmsLevel)
    }
  }

  private func legacyApp(forAppID appID: String) throws -> AudioApp {
    guard let app = snapshot.apps.app(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }
    return app
  }

  private func validateLegacyApplyResult(_ result: AppIntentApplyResult) throws {
    switch result.outcome {
    case .applied, .noChange:
      return
    case .unavailable:
      throw BackendError.appNotFound(result.appID)
    case .unsupported:
      throw BackendError.unsupportedOperation(
        result.detail ?? "Managed audio controls are not supported for this app."
      )
    case .superseded:
      throw BackendError.managedRouteUnavailable(
        result.detail ?? "A newer app change superseded this request."
      )
    case .excluded:
      throw BackendError.managedRouteUnavailable(
        result.detail ?? "The app is excluded from managed audio controls."
      )
    case .failed:
      throw BackendError.managedRouteUnavailable(
        result.detail ?? "The app intent could not be applied."
      )
    }
  }

  private func nextLegacyGeneration() -> UInt64 {
    let highestAccepted = latestAcceptedGenerationByLogicalID.values.max() ?? 0
    let base = max(legacyGeneration, highestAccepted)
    legacyGeneration = base == .max ? .max : base + 1
    return legacyGeneration
  }

  public func diagnosticsReport() async -> DiagnosticsReport {
    DiagnosticsReport(
      summary:
        "Preview backend simulates managed control for supported daily-use apps and monitor-only behavior for the remaining matrix.",
      checks: [
        DiagnosticsCheck(
          title: "Managed audio component",
          status: snapshot.backendStatus.isAudioComponentInstalled ? .passed : .warning,
          detail: snapshot.backendStatus.isAudioComponentInstalled
            ? "Preview backend marked component as installed."
            : "Install the managed audio component for real route ownership."
        ),
        DiagnosticsCheck(
          title: "Permission status",
          status: snapshot.backendStatus.hasRequiredPermissions ? .passed : .warning,
          detail: snapshot.backendStatus.hasRequiredPermissions
            ? "Required permissions are satisfied."
            : "Grant required permissions during onboarding."
        ),
        DiagnosticsCheck(
          title: "Support matrix",
          status: .informational,
          detail: snapshot.supportMatrix.coverageSummary
        ),
      ]
    )
  }
}

private extension Array where Element == AudioApp {
  func firstIndex(matchingAppKey appKey: String) -> Index? {
    firstIndex { $0.logicalID == appKey } ?? firstIndex { $0.id == appKey }
  }

  func app(matchingAppKey appKey: String) -> AudioApp? {
    first { $0.logicalID == appKey } ?? first { $0.id == appKey }
  }
}
