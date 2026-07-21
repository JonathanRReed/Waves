import AppKit
import ApplicationServices
import AudioToolbox
import Darwin
import Foundation
import OSLog
import WavesAudioCore

struct CleanupStatusObservation: Hashable, Sendable {
  let appID: String?
  let stage: CleanupStage
  let nativeStatus: Int32
  let detail: String?

  init(
    appID: String? = nil,
    stage: CleanupStage,
    nativeStatus: Int32,
    detail: String? = nil
  ) {
    self.appID = appID
    self.stage = stage
    self.nativeStatus = nativeStatus
    self.detail = detail
  }
}

func checkedCleanupDegradations(
  from observations: [CleanupStatusObservation]
) -> [CleanupDegradation] {
  observations.compactMap { observation in
    guard observation.nativeStatus != noErr else { return nil }
    return CleanupDegradation(
      appID: observation.appID,
      stage: observation.stage,
      nativeStatus: observation.nativeStatus,
      detail: observation.detail
    )
  }
}

final class IdempotentCleanupResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: [CleanupDegradation]?

  func run(_ cleanup: () -> [CleanupDegradation]) -> [CleanupDegradation] {
    lock.lock()
    defer { lock.unlock() }
    if let result { return result }
    let result = cleanup()
    self.result = result
    return result
  }
}

actor WorkspaceAudioControlBackend: AudioControlBackend {
  // Start from a neutral, empty session. Using `.preview` here would seed the
  // live backend with fabricated apps, volumes, and a fake error string that
  // could surface before the first real snapshot is built.
  private var snapshot: AudioSessionSnapshot = .empty
  private let currentBundleID = Bundle.main.bundleIdentifier
  private var controllers: [String: PerAppTapController] = [:]
  private var controllerGenerationByRuntimeID: [String: UInt64] = [:]
  private var equalizerSettingsByAppID: [String: EqualizerSettings] = [:]
  private var managedAudioEqualizerSettings = GlobalEqualizerSettings()
  private var adaptiveGainDBByAppID: [String: Float] = [:]
  private var latestAcceptedGenerationByLogicalID: [String: UInt64] = [:]
  private var stagedIntentByLogicalID: [String: AppRouteIntent] = [:]
  private var legacyGeneration: UInt64 = 0
  private var isStarted = false
  private var isShuttingDown = false
  private var lifecycleEpoch: UInt64 = 0
  private var shutdownTask: Task<BackendShutdownResult, Never>?
  private var shutdownResult: BackendShutdownResult?
  private var didFinishDeviceChangeContinuation = false
  private var retainedCleanupDegradations: [CleanupDegradation] = []
  private var levelUpdateTask: Task<Void, Never>?
  private var routeMaintenanceTick = 0
  private var staleRouteTicks: [String: Int] = [:]
  private let routeMaintenanceTickInterval = 20
  private let staleRouteThresholdTicks = 24
  private let staleRouteLevelThreshold: Float = 0.0005
  private var deviceChangeListenerSelectors: [AudioObjectPropertySelector] = []
  private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
  private var lastKnownDefaultOutputDeviceUID: String?
  private var outputDeviceReadinessError: String?
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "AudioBackend")

  typealias IntentRouteApplyOverride = @Sendable (AudioApp, EqualizerSettings) async throws -> Void
  typealias ShutdownCleanupOverride = @Sendable () -> [CleanupDegradation]
  private let intentRouteApplyOverride: IntentRouteApplyOverride?
  private let shutdownCleanupOverride: ShutdownCleanupOverride?

  nonisolated let deviceChangeEvents: AsyncStream<Void>
  private nonisolated let deviceChangeContinuation: AsyncStream<Void>.Continuation

  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.deviceChangeEvents = stream
    self.deviceChangeContinuation = continuation
    self.intentRouteApplyOverride = nil
    self.shutdownCleanupOverride = nil
  }

  init(
    testingSnapshot: AudioSessionSnapshot,
    captureAuthorization: CaptureAuthorizationResult = .undetermined,
    intentRouteApplyOverride: @escaping IntentRouteApplyOverride,
    shutdownCleanupOverride: ShutdownCleanupOverride? = nil
  ) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.deviceChangeEvents = stream
    self.deviceChangeContinuation = continuation
    self.snapshot = testingSnapshot
    self.captureAuthorization = captureAuthorization
    self.intentRouteApplyOverride = intentRouteApplyOverride
    self.shutdownCleanupOverride = shutdownCleanupOverride
    self.isStarted = true
  }

  func start() async throws {
    try ensureAcceptingOperations()
    guard !isStarted else { return }
    snapshot = await buildSnapshot(merging: snapshot)
    try ensureAcceptingOperations()
    lastKnownDefaultOutputDeviceUID = try? currentDefaultOutputDeviceUID()
    isStarted = true
    startLevelUpdateTask()
    addDeviceChangeListener()
  }

  func stop() async {
    _ = await shutdownWithResult()
  }

  func shutdownWithResult() async -> BackendShutdownResult {
    if let shutdownResult { return shutdownResult }
    if let shutdownTask { return await shutdownTask.value }

    // Publish the terminal lifecycle state before creating or awaiting any task so
    // actor reentrancy cannot admit a fresh route/device/recovery operation.
    isShuttingDown = true
    isStarted = false
    lifecycleEpoch = lifecycleEpoch == .max ? 0 : lifecycleEpoch + 1
    stagedIntentByLogicalID.removeAll()

    let task = Task { [weak self] in
      guard let self else {
        return BackendShutdownResult(
          checkedDegradations: [CleanupDegradation(
            stage: .controllerDisposal,
            detail: "The audio backend was released before cleanup could be verified."
          )]
        )
      }
      return await self.performCheckedShutdown()
    }
    shutdownTask = task
    return await task.value
  }

  private func performCheckedShutdown() async -> BackendShutdownResult {
    var degradations = retainedCleanupDegradations
    retainedCleanupDegradations.removeAll()

    let levelTask = levelUpdateTask
    levelUpdateTask = nil
    levelTask?.cancel()
    if let levelTask {
      await levelTask.value
    }

    degradations.append(contentsOf: removeDeviceChangeListener())
    lastKnownDefaultOutputDeviceUID = nil

    let installedControllers = controllers.sorted { $0.key < $1.key }
    controllers.removeAll()
    for (_, controller) in installedControllers {
      let controllerDegradations = controller.dispose()
      degradations.append(contentsOf: controllerDegradations)
      if !controllerDegradations.isEmpty {
        degradations.append(CleanupDegradation(
          appID: controller.appID,
          stage: .controllerDisposal,
          detail: "Controller disposal completed with \(controllerDegradations.count) checked native cleanup failure(s)."
        ))
      }
    }
    if let shutdownCleanupOverride {
      degradations.append(contentsOf: shutdownCleanupOverride())
    }

    controllerGenerationByRuntimeID.removeAll()
    equalizerSettingsByAppID.removeAll()
    adaptiveGainDBByAppID.removeAll()
    latestAcceptedGenerationByLogicalID.removeAll()
    stagedIntentByLogicalID.removeAll()
    staleRouteTicks.removeAll()
    routeMaintenanceTick = 0
    appBundleIDByPath.removeAll()
    audibleCache = nil
    outputDeviceReadinessError = nil
    snapshot = .empty
    finishDeviceChangeContinuationIfNeeded()

    let result = BackendShutdownResult(checkedDegradations: degradations)
    shutdownResult = result
    return result
  }

  private func finishDeviceChangeContinuationIfNeeded() {
    guard !didFinishDeviceChangeContinuation else { return }
    didFinishDeviceChangeContinuation = true
    deviceChangeContinuation.finish()
  }

  func currentSnapshot() async -> AudioSessionSnapshot {
    snapshot
  }

  func audioCapabilityMode() async -> AudioCapabilityMode {
    supportsPerAppRouting && captureAuthorization == .authorized ? .full : .limited
  }

  func captureAuthorizationResult() async -> CaptureAuthorizationResult {
    captureAuthorization
  }

  func refresh() async throws -> AudioSessionSnapshot {
    try ensureAcceptingOperations()
    let rebuilt = await buildSnapshot(merging: snapshot)
    try ensureAcceptingOperations()
    snapshot = rebuilt
    return snapshot
  }

  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    guard !isShuttingDown else {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: snapshot.apps.app(matchingAppKey: intent.appID),
        backendStatus: snapshot.backendStatus,
        detail: "The audio backend is shutting down."
      )
    }
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

    let currentApp = snapshot.apps[initialIndex]
    let logicalID = currentApp.logicalID
    guard isStarted else {
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .failed,
        resultingApp: currentApp,
        backendStatus: snapshot.backendStatus,
        detail: "The audio backend is not started."
      )
    }

    if let latestGeneration = latestAcceptedGenerationByLogicalID[logicalID],
       intent.generation < latestGeneration {
      return supersededResult(for: intent, logicalID: logicalID)
    }
    latestAcceptedGenerationByLogicalID[logicalID] = intent.generation
    stagedIntentByLogicalID[logicalID] = intent
    legacyGeneration = max(legacyGeneration, intent.generation)

    guard let acceptedIndex = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) else {
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
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
      excludeApp(at: acceptedIndex)
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth()
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .excluded,
        resultingApp: snapshot.apps[acceptedIndex],
        backendStatus: snapshot.backendStatus
      )
    }

    if !supportsPerAppRouting || snapshot.apps[acceptedIndex].compatibility == .unsupported {
      let detail = supportsPerAppRouting
        ? "This app does not support managed audio controls."
        : "Per-app routing requires macOS 14.2 or newer."
      snapshot.apps[acceptedIndex].routingState = .monitorOnly
      snapshot.apps[acceptedIndex].notes = detail
      snapshot.apps[acceptedIndex].appliedVolume = nil
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth()
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unsupported,
        resultingApp: snapshot.apps[acceptedIndex],
        backendStatus: snapshot.backendStatus,
        detail: detail
      )
    }

    let previousApp = snapshot.apps[acceptedIndex]
    let previousEqualizer = equalizerSettingsByAppID[logicalID] ?? EqualizerSettings()
    var stagedApp = previousApp
    stagedApp.desiredVolume = intent.desiredVolume
    stagedApp.isMuted = intent.isMuted
    stagedApp.volumeBoost = intent.volumeBoost
    stagedApp.targetDeviceUID = intent.targetDeviceUID

    let expectedAppliedVolume: Float = intent.isMuted ? 0 : intent.desiredVolume
    let hasNoChanges = previousApp.desiredVolume == intent.desiredVolume
      && previousApp.isMuted == intent.isMuted
      && previousApp.volumeBoost == intent.volumeBoost
      && previousApp.targetDeviceUID == intent.targetDeviceUID
      && previousEqualizer == intent.equalizerSettings
      && previousApp.routingState == .managed
      && previousApp.appliedVolume == expectedAppliedVolume
      && controllers[previousApp.id]?.isActive == true

    if hasNoChanges {
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .noChange,
        resultingApp: previousApp,
        backendStatus: snapshot.backendStatus
      )
    }

    let generationContext = IntentGenerationContext(
      logicalID: logicalID,
      generation: intent.generation,
      lifecycleEpoch: lifecycleEpoch
    )
    let forceRebuild = previousApp.targetDeviceUID != intent.targetDeviceUID

    do {
      try ensureGenerationCurrent(generationContext)
      if let intentRouteApplyOverride {
        try await intentRouteApplyOverride(stagedApp, intent.equalizerSettings)
        try ensureGenerationCurrent(generationContext)
      } else {
        try await applyRoute(
          for: stagedApp,
          toVolume: intent.desiredVolume,
          muted: intent.isMuted,
          forceRebuild: forceRebuild,
          equalizerSettings: intent.equalizerSettings,
          generationContext: generationContext
        )
      }
      try ensureGenerationCurrent(generationContext)

      guard let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) else {
        disposeControllerInstalledByGeneration(
          runtimeID: previousApp.id,
          generation: intent.generation
        )
        clearStagedIntentIfCurrent(intent, logicalID: logicalID)
        return AppIntentApplyResult(
          appID: intent.appID,
          generation: intent.generation,
          outcome: .unavailable,
          resultingApp: nil,
          backendStatus: snapshot.backendStatus,
          detail: "The app left the current audio session before its intent was committed."
        )
      }

      snapshot.apps[currentIndex].desiredVolume = intent.desiredVolume
      snapshot.apps[currentIndex].isMuted = intent.isMuted
      snapshot.apps[currentIndex].volumeBoost = intent.volumeBoost
      snapshot.apps[currentIndex].targetDeviceUID = intent.targetDeviceUID
      snapshot.apps[currentIndex].appliedVolume = expectedAppliedVolume
      snapshot.apps[currentIndex].routingState = .managed
      snapshot.apps[currentIndex].hasNoAudioCapability = false
      snapshot.apps[currentIndex].notes = nil
      if intent.isMuted {
        snapshot.apps[currentIndex].peakLevel = 0
        snapshot.apps[currentIndex].rmsLevel = 0
      }
      equalizerSettingsByAppID[logicalID] = intent.equalizerSettings
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      refreshGlobalRouteHealth()

      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .applied,
        resultingApp: snapshot.apps[currentIndex],
        backendStatus: snapshot.backendStatus
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
        detail: "The audio backend stopped before the intent completed."
      )
    } catch {
      guard isGenerationCurrent(generationContext) else {
        clearStagedIntentIfCurrent(intent, logicalID: logicalID)
        return supersededResult(for: intent, logicalID: logicalID)
      }

      if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
        snapshot.apps[currentIndex].desiredVolume = previousApp.desiredVolume
        snapshot.apps[currentIndex].isMuted = previousApp.isMuted
        snapshot.apps[currentIndex].volumeBoost = previousApp.volumeBoost
        snapshot.apps[currentIndex].targetDeviceUID = previousApp.targetDeviceUID
        snapshot.apps[currentIndex].appliedVolume = previousApp.appliedVolume
        markRouteError(at: currentIndex, error: error)
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

  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    try ensureAcceptingOperations()
    let app = try legacyApp(forAppID: appID)
    let values = intentControlValues(for: app)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: volume,
      isMuted: values.isMuted,
      volumeBoost: values.volumeBoost,
      equalizerSettings: values.equalizerSettings,
      targetDeviceUID: values.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    try ensureAcceptingOperations()
    let app = try legacyApp(forAppID: appID)
    let values = intentControlValues(for: app)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: values.desiredVolume,
      isMuted: isMuted,
      volumeBoost: values.volumeBoost,
      equalizerSettings: values.equalizerSettings,
      targetDeviceUID: values.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    try ensureAcceptingOperations()
    let app = try legacyApp(forAppID: appID)
    let values = intentControlValues(for: app)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: values.desiredVolume,
      isMuted: values.isMuted,
      volumeBoost: boost,
      equalizerSettings: values.equalizerSettings,
      targetDeviceUID: values.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws {
    try ensureAcceptingOperations()
    let app = try legacyApp(forAppID: appID)
    let values = intentControlValues(for: app)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: values.desiredVolume,
      isMuted: values.isMuted,
      volumeBoost: values.volumeBoost,
      equalizerSettings: settings,
      targetDeviceUID: values.targetDeviceUID,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  func setManagedAudioEqualizer(_ settings: GlobalEqualizerSettings) async {
    guard !isShuttingDown else { return }
    managedAudioEqualizerSettings = settings
    for controller in controllers.values {
      controller.setManagedAudioEqualizer(settings)
    }
  }

  func managedAudioEqualizerSettingsForTesting() -> GlobalEqualizerSettings {
    managedAudioEqualizerSettings
  }

  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels] {
    guard !isShuttingDown else { return [:] }
    return snapshot.apps.reduce(into: [:]) { result, app in
      guard let controller = controllers[app.id], controller.isActive else { return }
      result[app.logicalID] = controller.getAdaptiveAnalysis()
    }
  }

  func setAdaptiveGains(_ gainsDB: [String: Float]) async {
    guard !isShuttingDown else { return }
    var normalized: [String: Float] = [:]
    normalized.reserveCapacity(gainsDB.count)
    for (appID, gainDB) in gainsDB {
      let safeGain = gainDB.isFinite ? gainDB : 0
      normalized[appID] = min(3, max(-18, safeGain))
    }
    adaptiveGainDBByAppID = normalized

    // Omitted apps explicitly return to unity gain, preventing a stopped or
    // cancelled coordinator from leaving old attenuation on a live route.
    for app in snapshot.apps {
      guard let controller = controllers[app.id] else { continue }
      controller.setAdaptiveGainDB(normalized[app.logicalID] ?? 0)
    }
  }

  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {
    try ensureAcceptingOperations()
    if snapshot.currentDevice?.id == deviceID {
      snapshot.currentDevice?.volumeControlMode = mode
    }
  }

  func pinApp(_ isPinned: Bool, appID: String) async throws {
    try ensureAcceptingOperations()
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isPinned = isPinned
  }

  func applyProfileWithResults(
    _ profile: Profile,
    generation: UInt64
  ) async -> ProfileApplyResult {
    guard !isShuttingDown else {
      return ProfileApplyResult(
        rows: profile.entries.enumerated().map { entryIndex, entry in
          ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .failed,
            resultingApp: snapshot.apps.app(matchingAppKey: entry.appID),
            detail: "The audio backend is shutting down."
          )
        },
        backendStatus: snapshot.backendStatus
      )
    }
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
      let values = intentControlValues(for: app)
      let result = await applyAppIntent(AppRouteIntent(
        appID: entry.appID,
        desiredVolume: entry.desiredVolume ?? values.desiredVolume,
        isMuted: entry.isMuted ?? values.isMuted,
        volumeBoost: entry.volumeBoost ?? values.volumeBoost,
        equalizerSettings: values.equalizerSettings,
        targetDeviceUID: values.targetDeviceUID,
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

  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot {
    let result = await applyProfileWithResults(
      profile,
      generation: nextLegacyGeneration()
    )
    if let failure = result.rows.first(where: \.outcome.isActionableFailure) {
      throw BackendError.managedRouteUnavailable(
        failure.detail ?? "The profile could not be fully applied to \(failure.appID)."
      )
    }
    return snapshot
  }

  func saveCurrentProfile(named name: String) async throws -> Profile {
    try ensureAcceptingOperations()
    return Profile(
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
  }

  func recoverRoutes() async throws -> AudioSessionSnapshot {
    try ensureAcceptingOperations()
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter { $0.routingState == .managed || controllers[$0.id]?.isActive == true }
        .map(\.logicalID)
    )

    retainCleanupDegradations(disposeControllers(keeping: []))
    // buildSnapshot (and the subsequent reattachRoutes) is the single source of
    // route-health truth here: it recomputes backendStatus from scratch, so any
    // isRouteRecoveryHealthy/lastError assignment made before it would be
    // immediately overwritten and has no observable effect.
    snapshot = await buildSnapshot(merging: snapshot)
    try ensureAcceptingOperations()

    if !managedLogicalIDs.isEmpty {
      await reattachRoutes(forLogicalIDs: managedLogicalIDs)
    }

    return snapshot
  }

  func autoRestoreDevice() async throws -> AudioSessionSnapshot {
    try ensureAcceptingOperations()
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter { $0.routingState == .managed || controllers[$0.id]?.isActive == true }
        .map(\.logicalID)
    )

    retainCleanupDegradations(disposeControllers(keeping: []))
    snapshot = await buildSnapshot(merging: snapshot)
    try ensureAcceptingOperations()
    snapshot.updatedAt = .now

    if !managedLogicalIDs.isEmpty {
      await reattachRoutes(forLogicalIDs: managedLogicalIDs)
    }

    return snapshot
  }

  func diagnosticsReport() async -> DiagnosticsReport {
    guard !isShuttingDown else {
      return DiagnosticsReport(
        summary: "The audio backend is shutting down.",
        checks: []
      )
    }
    // Re-probe real capture authorization so opening Advanced reflects the
    // current TCC state rather than the result cached at the last refresh.
    // The probe creates and immediately destroys a private tap with no IO
    // proc, so it is side-effect-free and cheap.
    refreshCaptureAuthorization()
    refreshGlobalRouteHealth()

    // A hard route failure is one where the OS and capture permission are both
    // fine yet real routes errored — that is genuinely broken, not transient or
    // unsupported, so the Route recovery check should read as .failed (red).
    let hasRouteErrors = hasBlockingRouteErrors(in: snapshot.apps)
    let routeRecoveryStatus: DiagnosticsStatus
    if snapshot.backendStatus.isRouteRecoveryHealthy {
      routeRecoveryStatus = .passed
    } else if supportsPerAppRouting, captureAuthorization == .authorized, hasRouteErrors {
      routeRecoveryStatus = .failed
    } else {
      routeRecoveryStatus = .warning
    }

    return DiagnosticsReport(
      summary: recoverabilitySummary,
      checks: [
        DiagnosticsCheck(
          title: "Audio component",
          status: snapshot.backendStatus.isAudioComponentInstalled ? .passed : .warning,
          detail: snapshot.backendStatus.isAudioComponentInstalled
            ? "Process tap routing is supported on this system."
            : "Per-app routing needs macOS 14.2 or newer."
        ),
        DiagnosticsCheck(
          title: "Audio capture permission",
          status: captureAuthorizationStatus,
          detail: captureAuthorizationDetail
        ),
        DiagnosticsCheck(
          title: "Accessibility permission",
          status: hasAccessibilityPermission ? .passed : .warning,
          detail: hasAccessibilityPermission
            ? "Accessibility is granted for global shortcuts and app control helpers."
            : "Grant Accessibility in System Settings to enable global shortcuts. Per-app volume routing can still work without it."
        ),
        DiagnosticsCheck(
          title: "Route recovery",
          status: routeRecoveryStatus,
          detail: routeRecoveryDetail
        ),
        DiagnosticsCheck(
          title: "Support matrix",
          status: .informational,
          detail: snapshot.supportMatrix.coverageSummary
        ),
      ]
    )
  }

  private var captureAuthorizationStatus: DiagnosticsStatus {
    CaptureAuthorizationPresentation(captureAuthorization).status
  }

  private var captureAuthorizationDetail: String {
    CaptureAuthorizationPresentation(captureAuthorization).detail
  }

  private var routeRecoveryDetail: String {
    if snapshot.backendStatus.isRouteRecoveryHealthy {
      return "Per-app routing is active and can be reapplied."
    }
    if let lastError = snapshot.backendStatus.lastError {
      return lastError
    }
    return "Per-app routing is not ready. Refresh diagnostics, verify the output device, and retry route recovery."
  }

  private var recoverabilitySummary: String {
    guard snapshot.backendStatus.isAudioComponentInstalled else {
      return "Per-app routing is not available on this OS version."
    }
    guard captureAuthorization == .authorized else {
      return "Per-app routing is not ready because audio capture authorization could not be confirmed."
    }
    guard snapshot.currentDevice != nil else {
      return "Per-app routing is not ready because the current output device could not be identified."
    }

    let managed = snapshot.apps.filter { $0.routingState == .managed }.count
    return "Per-app routing is active for this session. Managed routes currently available: \(managed)."
  }

  private var supportsPerAppRouting: Bool {
    if #available(macOS 14.2, *) {
      return true
    }

    return false
  }

  private var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
  }

  /// The last structured result of the Core Audio capture-capability probe.
  /// OS support, reliable denial, and ambiguous native probe failures remain
  /// distinct so diagnostics never mislabel an unknown failure as TCC denial.
  private(set) var captureAuthorization: CaptureAuthorizationResult = .undetermined

  /// Probes audio-capture authorization by creating and immediately destroying
  /// a private global process tap. This codebase has no authoritative
  /// denial-only OSStatus, so every nonzero native status remains `.probeFailed`.
  @discardableResult
  func refreshCaptureAuthorization() -> CaptureAuthorizationResult {
    guard !isShuttingDown else { return captureAuthorization }
    guard #available(macOS 14.2, *) else {
      captureAuthorization = .unsupported
      return captureAuthorization
    }

    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "Waves-CapabilityProbe"
    description.uuid = UUID()
    description.isPrivate = true
    description.muteBehavior = .unmuted

    var tapID: AudioObjectID = .unknown
    let status = AudioHardwareCreateProcessTap(description, &tapID)
    if status == noErr, tapID != .unknown {
      let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
      retainCleanupStatus(
        destroyStatus,
        stage: .authorizationProbe,
        detail: "Destroy audio-capture authorization probe tap"
      )
    }

    captureAuthorization = CaptureAuthorizationResult.fromProbe(
      isPlatformSupported: true,
      nativeStatus: status
    )
    if case .probeFailed(let nativeStatus) = captureAuthorization {
      logger.warning("Audio-capture authorization probe could not be verified (OSStatus: \(nativeStatus))")
    }
    return captureAuthorization
  }

  private struct IntentGenerationContext: Sendable {
    let logicalID: String
    let generation: UInt64
    let lifecycleEpoch: UInt64
  }

  private struct IntentSupersededError: Error {}
  private struct IntentBackendStoppedError: Error {}

  private func ensureAcceptingOperations() throws {
    guard !isShuttingDown else {
      throw BackendError.managedRouteUnavailable("The audio backend is shutting down.")
    }
  }

  private func isGenerationCurrent(_ context: IntentGenerationContext) -> Bool {
    context.lifecycleEpoch == lifecycleEpoch
      && latestAcceptedGenerationByLogicalID[context.logicalID] == context.generation
  }

  private func ensureGenerationCurrent(_ context: IntentGenerationContext) throws {
    guard isStarted, !isShuttingDown else { throw IntentBackendStoppedError() }
    guard isGenerationCurrent(context) else { throw IntentSupersededError() }
  }

  private func supersededResult(
    for intent: AppRouteIntent,
    logicalID: String
  ) -> AppIntentApplyResult {
    AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: .superseded,
      resultingApp: snapshot.apps.first(where: { $0.logicalID == logicalID }),
      backendStatus: snapshot.backendStatus,
      detail: "A newer app intent has already been accepted."
    )
  }

  private func excludeApp(at index: Int) {
    let runtimeID = snapshot.apps[index].id
    if let controller = controllers.removeValue(forKey: runtimeID) {
      retainCleanupDegradations(controller.dispose())
    }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
    staleRouteTicks.removeValue(forKey: runtimeID)
    snapshot.apps[index].routingState = .monitorOnly
    snapshot.apps[index].appliedVolume = nil
    snapshot.apps[index].peakLevel = 0
    snapshot.apps[index].rmsLevel = 0
    snapshot.apps[index].hasNoAudioCapability = false
    snapshot.apps[index].notes = nil
  }

  private func disposeControllerInstalledByGeneration(
    runtimeID: String,
    generation: UInt64
  ) {
    guard controllerGenerationByRuntimeID[runtimeID] == generation else { return }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
    if let controller = controllers.removeValue(forKey: runtimeID) {
      retainCleanupDegradations(controller.dispose())
    }
    staleRouteTicks.removeValue(forKey: runtimeID)
  }

  private struct IntentControlValues {
    let desiredVolume: Float
    let isMuted: Bool
    let volumeBoost: Float
    let equalizerSettings: EqualizerSettings
    let targetDeviceUID: String?
  }

  private func intentControlValues(for app: AudioApp) -> IntentControlValues {
    if let stagedIntent = stagedIntentByLogicalID[app.logicalID] {
      return IntentControlValues(
        desiredVolume: stagedIntent.desiredVolume,
        isMuted: stagedIntent.isMuted,
        volumeBoost: stagedIntent.volumeBoost,
        equalizerSettings: stagedIntent.equalizerSettings,
        targetDeviceUID: stagedIntent.targetDeviceUID
      )
    }
    return IntentControlValues(
      desiredVolume: app.desiredVolume,
      isMuted: app.isMuted,
      volumeBoost: app.volumeBoost,
      equalizerSettings: equalizerSettingsByAppID[app.logicalID] ?? EqualizerSettings(),
      targetDeviceUID: app.targetDeviceUID
    )
  }

  private func clearStagedIntentIfCurrent(
    _ intent: AppRouteIntent,
    logicalID: String
  ) {
    guard stagedIntentByLogicalID[logicalID] == intent else { return }
    stagedIntentByLogicalID.removeValue(forKey: logicalID)
  }

  private func legacyApp(forAppID appID: String) throws -> AudioApp {
    guard let app = snapshot.apps.app(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }
    return app
  }

  private func nextLegacyGeneration() -> UInt64 {
    let highestAccepted = latestAcceptedGenerationByLogicalID.values.max() ?? 0
    let base = max(legacyGeneration, highestAccepted)
    legacyGeneration = base == .max ? .max : base + 1
    return legacyGeneration
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

  private func applyRoute(
    for app: AudioApp,
    toVolume volume: Float,
    muted: Bool,
    forceRebuild: Bool = false,
    equalizerSettings: EqualizerSettings? = nil,
    generationContext: IntentGenerationContext? = nil
  ) async throws {
    try ensureAcceptingOperations()
    guard supportsPerAppRouting else {
      throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
    }

    if let generationContext {
      try ensureGenerationCurrent(generationContext)
    }
    let processObjectIDs = try resolveProcessObjectIDs(for: app)
    let stagedEqualizer = equalizerSettings
      ?? equalizerSettingsByAppID[app.logicalID]
      ?? EqualizerSettings()

    // Reuse the live tap for parameter-only changes as long as it already covers
    // every process we'd tap now. A target-device change explicitly forces a new
    // controller, while volume/mute/boost/EQ changes stay on the current route.
    if !forceRebuild,
       let controller = controllers[app.id],
       controller.isActive,
       controller.covers(processObjectIDs) {
      if let generationContext {
        try ensureGenerationCurrent(generationContext)
      }
      controller.apply(volume: volume, volumeBoost: app.volumeBoost, muted: muted)
      controller.setEqualizer(stagedEqualizer)
      controller.setManagedAudioEqualizer(managedAudioEqualizerSettings)
      controller.setAdaptiveGainDB(adaptiveGainDBByAppID[app.logicalID] ?? 0)
      return
    }

    if let generationContext {
      try ensureGenerationCurrent(generationContext)
    }
    let controller = try await createControllerWithRetry(
      for: app,
      processObjectIDs: processObjectIDs,
      equalizerSettings: stagedEqualizer,
      generationContext: generationContext
    )

    do {
      try ensureAcceptingOperations()
      if let generationContext {
        try ensureGenerationCurrent(generationContext)
        if let installedGeneration = controllerGenerationByRuntimeID[app.id],
           installedGeneration > generationContext.generation {
          throw IntentSupersededError()
        }
        // Keep this check immediately adjacent to installation. If newer work ran
        // while controller creation was suspended, the new controller is disposed
        // below and the currently-installed controller remains untouched.
        try ensureGenerationCurrent(generationContext)
      }

      let replacedController = controllers.updateValue(controller, forKey: app.id)
      if let generationContext {
        controllerGenerationByRuntimeID[app.id] = generationContext.generation
      } else {
        controllerGenerationByRuntimeID.removeValue(forKey: app.id)
      }
      controller.apply(volume: volume, volumeBoost: app.volumeBoost, muted: muted)
      controller.setEqualizer(stagedEqualizer)
      controller.setManagedAudioEqualizer(managedAudioEqualizerSettings)
      controller.setAdaptiveGainDB(adaptiveGainDBByAppID[app.logicalID] ?? 0)
      if let replacedController {
        retainCleanupDegradations(replacedController.dispose())
      }

      // A freshly-created process tap proves capture is currently authorized.
      captureAuthorization = .authorized
    } catch {
      retainCleanupDegradations(controller.dispose())
      throw error
    }
  }

  private func createControllerWithRetry(
    for app: AudioApp,
    processObjectIDs: [AudioObjectID],
    equalizerSettings: EqualizerSettings,
    generationContext: IntentGenerationContext?
  ) async throws -> PerAppTapController {
    let maxRetries = 3
    var lastError: Error?
    var currentProcessObjectIDs = processObjectIDs

    for attempt in 1...maxRetries {
      try ensureAcceptingOperations()
      do {
        if let generationContext {
          try ensureGenerationCurrent(generationContext)
        }
        let controller = try createController(
          for: app,
          processObjectIDs: currentProcessObjectIDs,
          equalizerSettings: equalizerSettings
        )
        if attempt > 1 {
          logger.info("Successfully created controller for \(app.displayName) on attempt \(attempt)")
        }
        return controller
      } catch let superseded as IntentSupersededError {
        throw superseded
      } catch {
        lastError = error
        logger.warning("Failed to create controller for \(app.displayName) on attempt \(attempt): \(error.localizedDescription)")

        if attempt < maxRetries {
          let backoffMs = UInt64(100 * Int(pow(4.0, Double(attempt - 1))))
          if let generationContext {
            try ensureGenerationCurrent(generationContext)
          }
          try await Task.sleep(nanoseconds: backoffMs * 1_000_000)
          try ensureAcceptingOperations()
          if let generationContext {
            try ensureGenerationCurrent(generationContext)
          }

          // Re-resolve process object IDs after suspension. A transient resolution
          // failure is left for the next retry to report with the friendly error.
          if let refreshedProcessObjectIDs = try? resolveProcessObjectIDs(for: app),
             refreshedProcessObjectIDs != currentProcessObjectIDs {
            logger.info("Process object IDs changed for \(app.displayName) during retry")
            currentProcessObjectIDs = refreshedProcessObjectIDs
          }
        }
      }
    }

    if let generationContext {
      try ensureGenerationCurrent(generationContext)
    }
    logger.error("Giving up on managed route for \(app.displayName) after \(maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown error")")
    throw BackendError.managedRouteUnavailable(
      "Waves couldn't take over audio for \(app.displayName). If this keeps happening, check that audio capture is allowed in System Settings › Privacy & Security."
    )
  }

  private func createController(
    for app: AudioApp,
    processObjectIDs: [AudioObjectID],
    equalizerSettings: EqualizerSettings
  ) throws -> PerAppTapController {
    try ensureAcceptingOperations()

    if #available(macOS 14.2, *) {
      // Route to the app's pinned device if it has one; otherwise follow the
      // system default. If a pinned device is gone, fail honestly (the caller
      // marks the route .error) rather than silently falling back.
      let outputDeviceUID: String
      if let target = app.targetDeviceUID {
        guard isDeviceAvailable(uid: target) else {
          throw BackendError.managedRouteUnavailable(
            "The chosen output device for \(app.displayName) is unavailable. Pick another in the app's Output Device menu."
          )
        }
        outputDeviceUID = target
      } else {
        outputDeviceUID = try currentDefaultOutputDeviceUID()
      }

      let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
      tapDescription.name = "Waves-\(app.displayName)"
      tapDescription.uuid = UUID()
      tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped
      tapDescription.isPrivate = true

      var tapID: AudioObjectID = .unknown
      var aggregateID: AudioObjectID = .unknown
      var controllerOwnsResources = false
      defer {
        if !controllerOwnsResources {
          var observations: [CleanupStatusObservation] = []
          if aggregateID != .unknown {
            observations.append(CleanupStatusObservation(
              appID: app.logicalID,
              stage: .aggregateDeviceDestroy,
              nativeStatus: AudioHardwareDestroyAggregateDevice(aggregateID),
              detail: "Destroy partially-created aggregate device"
            ))
          }
          if tapID != .unknown {
            observations.append(CleanupStatusObservation(
              appID: app.logicalID,
              stage: .processTapDestroy,
              nativeStatus: AudioHardwareDestroyProcessTap(tapID),
              detail: "Destroy partially-created process tap"
            ))
          }
          retainCleanupDegradations(checkedCleanupDegradations(from: observations))
        }
      }

      try withStatusCheck(
        AudioHardwareCreateProcessTap(tapDescription, &tapID),
        action: "create process tap"
      )

      let tapUID = try readTapUID(tapID)
      let audioFormatPlan = try readTapFormatPlan(tapID)
      let aggregateDeviceDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Waves-\(app.displayName)",
        kAudioAggregateDeviceUIDKey: "com.waves.aggregate.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
        kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [
          [
            kAudioSubDeviceUIDKey: outputDeviceUID,
            kAudioSubDeviceDriftCompensationKey: false,
          ],
        ],
        kAudioAggregateDeviceTapListKey: [
          [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapUID,
          ],
        ],
      ]

      try withStatusCheck(
        AudioHardwareCreateAggregateDevice(aggregateDeviceDescription as CFDictionary, &aggregateID),
        action: "create aggregate device"
      )

      let controller = try PerAppTapController(
        appID: app.id,
        appName: app.displayName,
        targetProcessObjectIDs: processObjectIDs,
        tapID: tapID,
        aggregateDeviceID: aggregateID,
        volume: app.desiredVolume,
        volumeBoost: app.volumeBoost,
        muted: app.isMuted,
        equalizerSettings: equalizerSettings,
        managedAudioEqualizerSettings: managedAudioEqualizerSettings,
        adaptiveGainDB: adaptiveGainDBByAppID[app.logicalID] ?? 0,
        audioFormatPlan: audioFormatPlan
      )

      controllerOwnsResources = true
      do {
        try controller.start()
      } catch {
        let cleanupDegradations = controller.dispose()
        retainCleanupDegradations(cleanupDegradations)
        if !cleanupDegradations.isEmpty {
          logger.error(
            "Controller creation failed for \(app.displayName, privacy: .public): \(error.localizedDescription, privacy: .public). Cleanup also reported \(cleanupDegradations.count, privacy: .public) degradation(s)."
          )
        }
        throw error
      }

      return controller
    }

    throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
  }

  private func resolveProcessObjectIDs(for app: AudioApp) throws -> [AudioObjectID] {
    var candidatePIDs = Set<pid_t>()

    if let bundleID = app.bundleID, !bundleID.isEmpty {
      let runningFamilyPIDs = NSWorkspace.shared.runningApplications
        .filter { runningApp in
          AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: runningApp.bundleIdentifier)
        }
        .map(\.processIdentifier)
      candidatePIDs.formUnion(runningFamilyPIDs)

      // Include any currently-audible helper/utility process whose enclosing
      // top-level app is this app — e.g. a Chromium/Electron "Audio Service" or
      // renderer process that owns the real output stream. Without this the tap
      // would capture only the main process, which for browsers and Electron
      // apps emits no audio, so volume/mute/boost would silently do nothing.
      for pid in cachedAudibleProcesses().pids {
        guard let parentBundleID = enclosingAppBundleID(forPID: pid),
              AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: parentBundleID)
        else { continue }
        candidatePIDs.insert(pid)
      }
    }

    if let pid = app.pid {
      candidatePIDs.insert(pid)
    }

    let processObjectIDs = candidatePIDs
      .compactMap { pid -> AudioObjectID? in
        // A sibling PID may have no Core Audio process object yet (transient
        // helper/renderer in a browser family), which makes translateProcessID
        // throw. Skip that PID instead of aborting resolution for the whole
        // family — the empty-set checks below still fail honestly when NO PID
        // resolves.
        guard let processObjectID = try? translateProcessID(forPID: pid), processObjectID != .unknown else {
          return nil
        }
        return processObjectID
      }

    let uniqueProcessObjectIDs = Array(Set(processObjectIDs)).sorted { $0 < $1 }
    if !uniqueProcessObjectIDs.isEmpty {
      return uniqueProcessObjectIDs
    }

    if let pid = app.pid, let processObjectID = try translateProcessID(forPID: pid), processObjectID != .unknown {
      return [processObjectID]
    }

    // macOS only assigns a Core Audio process object once a process engages the
    // audio subsystem. For browsers/Electron shells (Helium, Chrome, Slack) that
    // object may belong to a short-lived helper and may not exist until playback
    // starts. Treat user-facing apps as retryable; reserve the permanent
    // no-audio path for true system/non-audio rows where exclusion is a safe
    // recommendation.
    if AppDiscoveryPolicy.treatsMissingAudioProcessAsPermanent(
      bundleID: app.bundleID,
      displayName: app.displayName,
      category: app.category
    ) {
      throw BackendError.noAudioCapability(
        "\(app.displayName) does not expose an audio stream Waves can manage. "
          + "If this app never plays sound, exclude it from Waves to stop this notice."
      )
    }

    throw BackendError.noActiveAudioStream(
      "No active audio stream was available for \(app.displayName), so Waves could not create a managed route yet. "
        + "Start playback in the app, then try again."
    )
  }

  private func readTapUID(_ tapID: AudioObjectID) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var uidSize: UInt32 = 0
    try withStatusCheck(
      AudioObjectGetPropertyDataSize(tapID, &address, 0, nil, &uidSize),
      action: "read tap uid size"
    )

    var rawUID: CFString?
    let uidStatus = withUnsafeMutablePointer(to: &rawUID) {
      AudioObjectGetPropertyData(tapID, &address, 0, nil, &uidSize, $0)
    }
    try withStatusCheck(uidStatus, action: "read tap uid")

    guard let rawUID else {
      throw BackendError.managedRouteUnavailable("No process tap UID returned.")
    }

    return rawUID as String
  }

  private func currentDefaultOutputDeviceUID() throws -> String {
    try outputDeviceUID(for: currentDefaultOutputDeviceID())
  }

  private func outputDeviceUID(for deviceID: AudioObjectID) throws -> String {
    var uidAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var uidSize: UInt32 = 0
    try withStatusCheck(
      AudioObjectGetPropertyDataSize(deviceID, &uidAddress, 0, nil, &uidSize),
      action: "read default output uid size"
    )

    var rawUID: CFString?
    let uidStatus = withUnsafeMutablePointer(to: &rawUID) {
      AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, $0)
    }
    try withStatusCheck(uidStatus, action: "read default output uid")

    guard let rawUID else {
      throw BackendError.managedRouteUnavailable("No output device UID returned.")
    }

    return rawUID as String
  }

  private func currentOutputDevice() throws -> AudioDevice {
    let deviceID = try currentDefaultOutputDeviceID()
    let uid = try outputDeviceUID(for: deviceID)
    let name = (try? stringProperty(
      deviceID,
      selector: kAudioObjectPropertyName,
      action: "read default output name"
    )) ?? "System Output"

    return AudioDevice(
      id: uid,
      name: name,
      kind: deviceKind(uid: uid, name: name),
      isCurrent: true,
      isManagedRouteAvailable: supportsPerAppRouting
    )
  }

  private func currentDefaultOutputDeviceID() throws -> AudioObjectID {
    var selectorAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try withStatusCheck(
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &selectorAddress, 0, nil, &size, &deviceID),
      action: "read default output device"
    )

    guard deviceID != .unknown else {
      throw BackendError.managedRouteUnavailable("No default output device found.")
    }

    return deviceID
  }

  func availableOutputDevices() async -> [AudioDevice] {
    guard !isShuttingDown, supportsPerAppRouting else { return [] }
    let currentUID = try? currentDefaultOutputDeviceUID()
    var devices: [AudioDevice] = []
    for deviceID in allDeviceIDs() where hasOutputStreams(deviceID) {
      guard let uid = deviceUID(deviceID) else { continue }
      // Skip Waves' own private aggregate devices so they never appear as
      // user-selectable outputs.
      if uid.hasPrefix("com.waves.aggregate.") { continue }
      let name = (try? stringProperty(deviceID, selector: kAudioObjectPropertyName, action: "read device name")) ?? "Output Device"
      let kind = deviceKind(uid: uid, name: name)
      // Note: do NOT also filter on a "waves" name substring. This app's own
      // aggregates are reliably identified by the com.waves.aggregate. UID prefix
      // above; a name-based test would wrongly hide legitimate third-party
      // hardware from Waves Audio (a real vendor) whose names contain "waves".
      devices.append(AudioDevice(
        id: uid,
        name: name,
        kind: kind,
        isCurrent: uid == currentUID,
        isManagedRouteAvailable: supportsPerAppRouting
      ))
    }
    return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func setDefaultOutputDevice(uid: String) async throws {
    try ensureAcceptingOperations()
    guard let deviceID = allDeviceIDs().first(where: { deviceUID($0) == uid }) else {
      throw BackendError.managedRouteUnavailable("That output device is no longer available.")
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var mutableID = deviceID
    try withStatusCheck(
      AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioObjectID>.size),
        &mutableID
      ),
      action: "set default output device"
    )
    // The default-device listener fires from here, driving auto-restore + a
    // deviceChangeEvents emission that refreshes the UI.
  }

  func setOutputDevice(uid: String?, forAppID appID: String) async throws {
    try ensureAcceptingOperations()
    let app = try legacyApp(forAppID: appID)
    let values = intentControlValues(for: app)
    let result = await applyAppIntent(AppRouteIntent(
      appID: app.logicalID,
      desiredVolume: values.desiredVolume,
      isMuted: values.isMuted,
      volumeBoost: values.volumeBoost,
      equalizerSettings: values.equalizerSettings,
      targetDeviceUID: uid,
      generation: nextLegacyGeneration(),
      reason: .userEdit
    ))
    try validateLegacyApplyResult(result)
  }

  private func isDeviceAvailable(uid: String) -> Bool {
    allDeviceIDs().contains { deviceUID($0) == uid }
  }

  private func allDeviceIDs() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: .unknown, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids.filter { $0 != .unknown }
  }

  private func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return false }
    return size > 0
  }

  private func deviceUID(_ deviceID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return nil }
    var rawUID: CFString?
    let status = withUnsafeMutablePointer(to: &rawUID) {
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let rawUID else { return nil }
    return rawUID as String
  }

  private func stringProperty(
    _ objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    action: String
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0
    try withStatusCheck(
      AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &propertySize),
      action: "\(action) size"
    )

    var rawValue: CFString?
    let status = withUnsafeMutablePointer(to: &rawValue) {
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, $0)
    }
    try withStatusCheck(status, action: action)

    guard let rawValue else {
      throw BackendError.managedRouteUnavailable("\(action) returned no value.")
    }

    return rawValue as String
  }

  private func deviceKind(uid: String, name: String) -> DeviceKind {
    let token = "\(uid) \(name)".lowercased()
    if token.contains("bluetooth") || token.contains("airpods") || token.contains("beats") {
      return .bluetooth
    }
    if token.contains("display") || token.contains("hdmi") || token.contains("usb-c") {
      return .display
    }
    if token.contains("aggregate") || token.contains("multi-output") {
      return .aggregate
    }
    if token.contains("waves") || token.contains("blackhole") || token.contains("soundflower") || token.contains("eqmac") {
      return .virtual
    }
    if token.contains("speaker") || token.contains("built-in") || token.contains("macbook") {
      return .builtInOutput
    }
    return .unknown
  }

  private func translateProcessID(forPID pid: pid_t) throws -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var processObjectID = AudioObjectID(kAudioObjectUnknown)
    var qualifier = pid
    var size = UInt32(MemoryLayout<AudioObjectID>.size)

    try withStatusCheck(
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        UInt32(MemoryLayout<pid_t>.size),
        &qualifier,
        &size,
        &processObjectID
      ),
      action: "translate pid \(pid) to process object"
    )

    return processObjectID == .unknown ? nil : processObjectID
  }

  /// The set of processes currently producing audio output, indexed both by raw
  /// PID and by the bundle identifier of the enclosing top-level `.app`. The
  /// bundle index is what lets a Chromium/Electron helper's audio be attributed
  /// to the parent app (see `enclosingAppBundleID`).
  struct AudibleProcessIndex: Sendable {
    var pids: Set<pid_t> = []
    /// Bundle IDs of the top-level apps that own the audible processes. For a
    /// browser this is `com.google.Chrome` even though the audible PID is a
    /// nested "… Helper (Renderer)" process.
    var parentBundleIDs: Set<String> = []
  }

  /// Caches the resolved top-level-app bundle ID per app-bundle path so repeated
  /// `Bundle` loads (which read Info.plist from disk) are avoided. Keyed by the
  /// stable bundle path rather than PID, so PID reuse can't poison it.
  private var appBundleIDByPath: [String: String] = [:]

  /// Short-lived cache of the audible-process scan. A volume drag fires many
  /// throttled applies in quick succession; without this each one would re-walk
  /// the full Core Audio process-object list. 300ms is well under human notice
  /// for "a new app just started playing", and stale data only ever delays
  /// folding a brand-new helper into a tap by one tick.
  private var audibleCache: (index: AudibleProcessIndex, at: Date)?
  private let audibleCacheTTL: TimeInterval = 0.3

  /// The audible-process index, reused from the cache when fresh enough. Pass a
  /// smaller `maxAge` (or 0) to force a fresh scan.
  private func cachedAudibleProcesses(maxAge: TimeInterval? = nil) -> AudibleProcessIndex {
    let ttl = maxAge ?? audibleCacheTTL
    if let cached = audibleCache, Date().timeIntervalSince(cached.at) < ttl {
      return cached.index
    }
    let index = getAudibleProcesses()
    audibleCache = (index, Date())
    return index
  }

  /// Resolves the bundle identifier of the outermost `.app` that contains the
  /// given PID's executable. This is the public, App-Store-safe way (used by
  /// AudioCap) to map a sandboxed audio helper back to its user-facing app —
  /// browsers and Electron apps render audio in helper subprocesses that aren't
  /// in `NSWorkspace.runningApplications`, so their executable path is the only
  /// reliable link back to the parent.
  private func enclosingAppBundleID(forPID pid: pid_t) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't surfaced to Swift, so the
    // value is inlined. proc_pidpath never writes more than this.
    let maxPathSize = 4 * 1024
    var pathBuffer = [CChar](repeating: 0, count: maxPathSize)
    let length = proc_pidpath(pid, &pathBuffer, UInt32(maxPathSize))
    guard length > 0 else { return nil }
    let executablePath = pathBuffer.withUnsafeBufferPointer { buffer in
      buffer.baseAddress.map { String(cString: $0) } ?? ""
    }
    guard let appPath = AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: executablePath) else {
      return nil
    }
    if let cached = appBundleIDByPath[appPath] {
      return cached
    }
    guard let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
          let identifier = bundle.bundleIdentifier else {
      return nil
    }
    appBundleIDByPath[appPath] = identifier
    return identifier
  }

  private func getAudibleProcesses() -> AudibleProcessIndex {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size
    )

    guard status == noErr else {
      logger.warning("Failed to get process object list size (OSStatus: \(status))")
      return AudibleProcessIndex()
    }

    let processObjectCount = Int(size) / MemoryLayout<AudioObjectID>.size
    guard processObjectCount > 0 else {
      return AudibleProcessIndex()
    }

    var processObjectIDs = [AudioObjectID](repeating: .unknown, count: processObjectCount)
    let listStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &processObjectIDs
    )

    guard listStatus == noErr else {
      logger.warning("Failed to get process object list (OSStatus: \(listStatus))")
      return AudibleProcessIndex()
    }

    var index = AudibleProcessIndex()
    for processObjectID in processObjectIDs where processObjectID != .unknown {
      guard isProcessRunningOutput(processObjectID) else { continue }
      guard let pid = readProcessPID(processObjectID) else { continue }
      index.pids.insert(pid)
      // Attribute helper/utility audio (browsers, Electron) to the parent app.
      if let parentBundleID = enclosingAppBundleID(forPID: pid) {
        index.parentBundleIDs.insert(parentBundleID)
      }
    }

    return index
  }

  private func readProcessPID(_ processObjectID: AudioObjectID) -> pid_t? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var pid = pid_t()
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &pid)
    guard status == noErr else {
      logger.warning("Failed to read process pid for object \(processObjectID) (OSStatus: \(status))")
      return nil
    }

    return pid
  }

  private func isProcessRunningOutput(_ processObjectID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningOutput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var isRunningOutput: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &isRunningOutput)
    guard status == noErr else {
      logger.warning("Failed to read process output state for object \(processObjectID) (OSStatus: \(status))")
      return false
    }

    return isRunningOutput != 0
  }

  private func readTapFormatPlan(_ tapID: AudioObjectID) throws -> AudioFormatPlan {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var streamDescription = AudioStreamBasicDescription()
    let expectedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var actualSize = expectedSize
    try withStatusCheck(
      AudioObjectGetPropertyData(
        tapID,
        &address,
        0,
        nil,
        &actualSize,
        &streamDescription
      ),
      action: "read process tap audio format"
    )
    guard actualSize == expectedSize else {
      throw BackendError.managedRouteUnavailable(
        "Process tap audio format returned \(actualSize) bytes; expected \(expectedSize)."
      )
    }
    guard let plan = AudioFormatPlan(nativeStreamDescription: streamDescription) else {
      throw BackendError.managedRouteUnavailable(
        "The process tap returned an unsupported or inconsistent linear PCM audio format."
      )
    }
    return plan
  }

  private func buildSnapshot(merging previousSnapshot: AudioSessionSnapshot?) async -> AudioSessionSnapshot {
    // Re-check real capture authorization so a snapshot honestly reflects whether
    // Waves can actually take over audio, not merely whether the OS supports it.
    refreshCaptureAuthorization()
    let audible = getAudibleProcesses()
    let runningApps = await Task.detached { [currentBundleID, audible] in
      Self.discoverRunningApps(
        currentBundleID: currentBundleID,
        audiblePIDs: audible.pids,
        audibleParentBundleIDs: audible.parentBundleIDs
      )
    }.value
    guard !isShuttingDown else { return snapshot }
    let previousByLogicalID = dictionaryByLogicalID(previousSnapshot?.apps ?? [])
    let now = Date()

    var mergedApps = runningApps.map { candidate -> AudioApp in
      guard let previous = previousByLogicalID[candidate.logicalID] else {
        return candidate
      }

      var app = candidate
      app.desiredVolume = previous.desiredVolume
      app.appliedVolume = previous.appliedVolume ?? previous.desiredVolume
      app.isMuted = previous.isMuted
      app.isPinned = previous.isPinned
      app.compatibility = previous.compatibility
      app.volumeBoost = previous.volumeBoost
      app.muteSource = previous.muteSource
      app.targetDeviceUID = previous.targetDeviceUID
      // Preserve a prior route error across a plain rebuild: a refresh with no
      // successful re-apply must not erase the Error chip / inline reason. The
      // error clears only on a later successful apply or reattach (those paths
      // set .managed and notes=nil) or once the controller is live again.
      // But if the fresh candidate shows the app currently audible (.live), the
      // app is plainly playing again — let that clear a stale, transient error
      // rather than pinning the row/global health to error indefinitely.
      if previous.routingState == .error && candidate.routingState != .live {
        app.routingState = .error
        app.notes = previous.notes
        app.hasNoAudioCapability = previous.hasNoAudioCapability
      }
      return app
    }

    var mergedLogicalIDs = Set(mergedApps.map(\.logicalID))
    for previous in previousSnapshot?.apps ?? [] {
      guard !mergedLogicalIDs.contains(previous.logicalID) else { continue }
      guard Self.isStillRunning(previous, currentBundleID: currentBundleID) else { continue }

      var retained = previous
      retained.isActive = false
      retained.peakLevel = 0
      retained.rmsLevel = 0
      if let controller = controllers[retained.id], controller.isActive {
        retained.routingState = .managed
        retained.appliedVolume = retained.isMuted ? 0 : retained.desiredVolume
        retained.notes = nil
      } else if retained.routingState != .error {
        // Preserve a prior route error across rebuild (keep .error + its note);
        // it clears only on a successful apply/reattach. Otherwise demote a
        // non-controller app to monitorOnly.
        retained.routingState = .monitorOnly
        retained.notes = nil
      }
      mergedApps.append(retained)
      mergedLogicalIDs.insert(retained.logicalID)
    }

    for index in mergedApps.indices {
      if !supportsPerAppRouting {
        mergedApps[index].routingState = RoutingState.monitorOnly
        mergedApps[index].notes = "Per-app route requires macOS 14.2+"
        mergedApps[index].compatibility = CompatibilityState.planned
        continue
      }

      if let controller = controllers[mergedApps[index].id], controller.isActive {
        mergedApps[index].routingState = RoutingState.managed
        mergedApps[index].appliedVolume = mergedApps[index].isMuted ? 0 : mergedApps[index].appliedVolume
        mergedApps[index].notes = nil
      } else if mergedApps[index].routingState == .live {
        mergedApps[index].appliedVolume = mergedApps[index].isMuted ? 0 : mergedApps[index].desiredVolume
        mergedApps[index].notes = nil
      } else if mergedApps[index].routingState == .error {
        // Keep a real route error visible across the rebuild; do not silently
        // demote it to monitorOnly / clear its note without a successful apply.
        continue
      } else {
        mergedApps[index].routingState = RoutingState.monitorOnly
        mergedApps[index].notes = nil
      }
    }

    let runningIDs: Set<String> = Set(mergedApps.map(\.id))
    retainCleanupDegradations(disposeControllers(keeping: runningIDs))

    let hasRouteErrors = hasBlockingRouteErrors(in: mergedApps)
    let routeError = hasRouteErrors
      ? mergedApps.first(where: { $0.routingState == .error && $0.notes != nil })?.notes
        ?? snapshot.backendStatus.lastError
      : nil

    let deviceReadiness: OutputDeviceReadiness
    do {
      deviceReadiness = OutputDeviceReadiness(
        currentDevice: try currentOutputDevice(),
        previousRecentDeviceIDs: previousSnapshot?.recentDeviceIDs ?? []
      )
    } catch {
      deviceReadiness = OutputDeviceReadiness(
        currentDevice: nil,
        previousRecentDeviceIDs: previousSnapshot?.recentDeviceIDs ?? [],
        failureDetail: "Waves could not identify the current output device: \(error.localizedDescription)"
      )
    }
    outputDeviceReadinessError = deviceReadiness.errorDetail
    let backendError = combinedBackendError(routeError: routeError)

    return AudioSessionSnapshot(
      apps: mergedApps,
      currentDevice: deviceReadiness.currentDevice,
      recentDeviceIDs: deviceReadiness.recentDeviceIDs,
      supportMatrix: SupportMatrix(
        entries: mergedApps.map {
          SupportMatrixEntry(
            appID: $0.logicalID,
            displayName: $0.displayName,
            category: $0.category,
            state: $0.compatibility
          )
        }
      ),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: supportsPerAppRouting,
        hasRequiredPermissions: captureAuthorization == .authorized,
        isRouteRecoveryHealthy: supportsPerAppRouting
          && captureAuthorization == .authorized
          && deviceReadiness.isReady
          && !hasRouteErrors,
        lastError: backendError
      ),
      updatedAt: now
    )
  }

  func audioLevels() async -> [String: AudioLevels] {
    guard !isShuttingDown else { return [:] }
    var result: [String: AudioLevels] = [:]
    for app in snapshot.apps where app.routingState == .managed || app.routingState == .live {
      result[app.logicalID] = AudioLevels(peak: app.peakLevel, rms: app.rmsLevel)
    }
    return result
  }

  // Satisfies the AudioControlBackend protocol requirement
  // releaseControllers(forBundleID:pid:). The defaulted clearMuteState parameter
  // means this also fulfils the shorter protocol signature, and plain callers
  // (e.g. app TERMINATION via handleAppTermination) get the safe default of
  // NOT clearing mute — so a user's saved manual mute survives the app quitting
  // and is not later propagated as "unmuted" by a snapshot merge.
  func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool = false) async {
    guard !isShuttingDown else { return }
    let targetIDs = snapshot.apps.filter { app in
      (bundleID != nil && app.bundleID == bundleID) || (app.pid != nil && app.pid == pid)
    }.map(\.id)

    guard !targetIDs.isEmpty else { return }

    for id in targetIDs {
      if let controller = controllers.removeValue(forKey: id) {
        retainCleanupDegradations(controller.dispose())
      }
      controllerGenerationByRuntimeID.removeValue(forKey: id)
      staleRouteTicks.removeValue(forKey: id)
    }

    for index in snapshot.apps.indices where targetIDs.contains(snapshot.apps[index].id) {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].isActive = false
      snapshot.apps[index].appliedVolume = nil
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
      // Only the EXCLUSION path clears mute, so a later whole-session pull
      // (buildSnapshot carries previous.isMuted forward) does not resurrect a
      // mute the user cleared by excluding the app, keeping the backend snapshot
      // in agreement with the store (which clears mute + sets muteSource = .user
      // on exclusion). Plain termination must NOT clear it.
      if clearMuteState {
        snapshot.apps[index].isMuted = false
        snapshot.apps[index].muteSource = .user
      }
    }
  }

  private func disposeControllers(keeping appIDs: Set<String>) -> [CleanupDegradation] {
    let stale = Set(controllers.keys).subtracting(appIDs).sorted()
    var degradations: [CleanupDegradation] = []
    for appID in stale {
      if let controller = controllers.removeValue(forKey: appID) {
        degradations.append(contentsOf: controller.dispose())
      }
      controllerGenerationByRuntimeID.removeValue(forKey: appID)
      staleRouteTicks.removeValue(forKey: appID)
    }
    return degradations
  }

  private static func discoverRunningApps(
    currentBundleID: String?,
    audiblePIDs: Set<pid_t>,
    audibleParentBundleIDs: Set<String>
  ) -> [AudioApp] {
    let runningApps = NSWorkspace.shared.runningApplications
      .filter { app in
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        guard app.activationPolicy != .prohibited else { return false }
        guard let localizedName = app.localizedName, !localizedName.isEmpty else { return false }
        guard app.bundleIdentifier != currentBundleID else { return false }
        return true
      }

    let candidateApps = runningApps
      .filter { app in
        let localizedName = app.localizedName ?? ""
        guard AppDiscoveryPolicy.isManageableApp(named: localizedName, bundleID: app.bundleIdentifier) else { return false }
        return true
      }
      .sorted {
        ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
      }

    var representativesByLogicalID: [String: NSRunningApplication] = [:]
    for app in candidateApps {
      let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: app.bundleIdentifier, displayName: app.localizedName ?? "")
      if let existing = representativesByLogicalID[logicalID] {
        representativesByLogicalID[logicalID] = Self.preferredRepresentative(current: existing, candidate: app)
      } else {
        representativesByLogicalID[logicalID] = app
      }
    }

    return representativesByLogicalID.values
      .sorted {
        ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
      }
      .map { app in
        let bundleID = app.bundleIdentifier
        let name = app.localizedName ?? "Unknown App"
        let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: bundleID, displayName: name)
        let category = AppDiscoveryPolicy.inferCategory(bundleID: bundleID, displayName: name)
        let pid = app.processIdentifier
        let familyApps = Self.processFamily(for: app, in: runningApps)
        let familyPIDs = Set(familyApps.map(\.processIdentifier))
        // An app is audible if a process in its NSWorkspace family is producing
        // output, OR — crucially for Chromium/Electron apps — if a helper whose
        // enclosing top-level app is this app is producing output. The latter is
        // the only signal that lights up browsers, whose audio is emitted by a
        // sandboxed "Audio Service" helper that never appears in the family set.
        let isAudibleByPID = !audiblePIDs.isEmpty && !familyPIDs.isDisjoint(with: audiblePIDs)
        let isAudibleByBundle = bundleID.map { bid in
          audibleParentBundleIDs.contains { candidate in
            AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bid, candidateBundleID: candidate)
          }
        } ?? false
        let isAudible = isAudibleByPID || isAudibleByBundle
        let isFrontmost = familyApps.contains(where: \.isActive)
        let routeState: RoutingState = isAudible ? .live : .monitorOnly

        return AudioApp(
          id: logicalID,
          logicalID: logicalID,
          pid: pid,
          bundleID: bundleID,
          displayName: name,
          iconName: AppDiscoveryPolicy.iconName(for: category),
          iconTIFFData: Self.iconTIFFData(for: app),
          category: category,
          isActive: isAudible || isFrontmost,
          peakLevel: 0,
          rmsLevel: 0,
          desiredVolume: 1,
          appliedVolume: 1,
          isMuted: false,
          isPinned: false,
          routingState: routeState,
          compatibility: .supported,
          notes: nil,
          volumeBoost: 1.0
        )
      }
  }

  private static func iconTIFFData(for app: NSRunningApplication) -> Data? {
    if let icon = app.icon {
      return iconPNGData(from: icon)
    }

    if let bundleURL = app.bundleURL {
      return iconPNGData(from: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    if let bundleID = app.bundleIdentifier,
       let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return iconPNGData(from: NSWorkspace.shared.icon(forFile: bundleURL.path))
    }

    return nil
  }

  private static func iconPNGData(from icon: NSImage) -> Data? {
    let size = NSSize(width: 64, height: 64)
    let resized = NSImage(size: size)
    resized.lockFocus()
    icon.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    resized.unlockFocus()

    guard let tiffData = resized.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
      return nil
    }

    return bitmap.representation(using: .png, properties: [:])
  }

  private func dictionaryByLogicalID(_ apps: [AudioApp]) -> [String: AudioApp] {
    apps.reduce(into: [:]) { result, app in
      result[app.logicalID] = app
    }
  }

  private static func preferredRepresentative(
    current: NSRunningApplication,
    candidate: NSRunningApplication
  ) -> NSRunningApplication {
    score(candidate) >= score(current) ? candidate : current
  }

  private static func processFamily(
    for app: NSRunningApplication,
    in runningApps: [NSRunningApplication]
  ) -> [NSRunningApplication] {
    let appName = app.localizedName ?? ""
    let logicalID = AppDiscoveryPolicy.logicalAppID(bundleID: app.bundleIdentifier, displayName: appName)

    return runningApps.filter { candidate in
      if candidate.processIdentifier == app.processIdentifier {
        return true
      }

      if let bundleID = app.bundleIdentifier,
        AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: candidate.bundleIdentifier)
      {
        return true
      }

      return AppDiscoveryPolicy.logicalAppID(
        bundleID: candidate.bundleIdentifier,
        displayName: candidate.localizedName ?? ""
      ) == logicalID
    }
  }

  private static func isStillRunning(_ app: AudioApp, currentBundleID: String?) -> Bool {
    NSWorkspace.shared.runningApplications.contains { candidate in
      guard candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
      guard candidate.bundleIdentifier != currentBundleID else { return false }

      if let pid = app.pid, candidate.processIdentifier == pid {
        return true
      }

      if let bundleID = app.bundleID,
        AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: candidate.bundleIdentifier)
      {
        return true
      }

      return AppDiscoveryPolicy.logicalAppID(
        bundleID: candidate.bundleIdentifier,
        displayName: candidate.localizedName ?? ""
      ) == app.logicalID
    }
  }

  private static func score(_ app: NSRunningApplication) -> Int {
    let token = [app.bundleIdentifier ?? "", app.localizedName ?? ""].joined(separator: " ").lowercased()
    var value = 0

    if app.activationPolicy == .regular {
      value += 8
    } else if app.activationPolicy == .accessory {
      value += 2
    }

    if app.isActive {
      value += 4
    }

    if app.bundleURL?.pathExtension == "app" {
      value += 2
    }

    if app.icon != nil {
      value += 1
    }

    if let localizedName = app.localizedName,
      !AppDiscoveryPolicy.isCompanionAudioProcess(named: localizedName, bundleID: app.bundleIdentifier)
    {
      value += 6
    } else {
      value -= 4
    }

    if ["daemon", "updater", "agent", "service", "crashpad", "login item", "xpc"]
      .contains(where: { token.contains($0) })
    {
      value -= 6
    }

    return value
  }

  private func withStatusCheck(_ status: OSStatus, action: String) throws {
    if status != noErr {
      throw BackendError.managedRouteUnavailable("\(action) failed (OSStatus: \(status)).")
    }
  }

  private func retainCleanupStatus(
    _ status: OSStatus,
    appID: String? = nil,
    stage: CleanupStage,
    detail: String
  ) {
    retainCleanupDegradations(checkedCleanupDegradations(from: [
      CleanupStatusObservation(
        appID: appID,
        stage: stage,
        nativeStatus: status,
        detail: detail
      )
    ]))
  }

  private func retainCleanupDegradations(_ degradations: [CleanupDegradation]) {
    guard !degradations.isEmpty else { return }
    retainedCleanupDegradations.append(contentsOf: degradations)
    for degradation in degradations {
      logger.error(
        "Cleanup degraded at \(String(describing: degradation.stage), privacy: .public) for \(degradation.appID ?? "backend", privacy: .public): OSStatus \(degradation.nativeStatus ?? 0, privacy: .public). \(degradation.detail ?? "No detail.", privacy: .public)"
      )
    }
  }

  /// Recompute global route readiness from authorization, the confirmed current
  /// output device, and every app route. A successful app apply cannot erase an
  /// authorization/device query failure or another app's route error.
  private func refreshGlobalRouteHealth(latestError: String? = nil) {
    let hasRouteErrors = hasBlockingRouteErrors(in: snapshot.apps)
    let deviceIsReady = snapshot.currentDevice != nil
    snapshot.backendStatus.hasRequiredPermissions = captureAuthorization == .authorized
    snapshot.backendStatus.isRouteRecoveryHealthy = supportsPerAppRouting
      && captureAuthorization == .authorized
      && deviceIsReady
      && !hasRouteErrors

    let routeError = hasRouteErrors
      ? latestError
        ?? snapshot.apps.first(where: { $0.routingState == .error && $0.notes != nil })?.notes
        ?? snapshot.backendStatus.lastError
      : nil
    snapshot.backendStatus.lastError = combinedBackendError(routeError: routeError)
  }

  private func combinedBackendError(routeError: String?) -> String? {
    var details: [String] = []
    if let authorizationError = CaptureAuthorizationPresentation(captureAuthorization).backendErrorDetail {
      details.append(authorizationError)
    }
    if let outputDeviceReadinessError {
      details.append(outputDeviceReadinessError)
    }
    if let routeError, !details.contains(routeError) {
      details.append(routeError)
    }
    return details.isEmpty ? nil : details.joined(separator: " ")
  }

  // Apps with hasNoAudioCapability never had a Core Audio process object to
  // begin with (menu-bar utilities, CLI tools) — retrying can never route
  // them, so they shouldn't hold the global "Needs attention" badge or the
  // Route recovery diagnostic red forever. Their row still shows an Error
  // chip + explanation; this only excludes them from the app-wide signal.
  private func hasBlockingRouteErrors(in apps: [AudioApp]) -> Bool {
    apps.contains { $0.routingState == .error && !$0.hasNoAudioCapability }
  }

  /// Records route failures. A missing active stream on a normal app is kept as
  /// monitor-only because it is a retryable precondition, not a broken route.
  /// True route failures become `.error`; permanent non-audio rows also record
  /// `hasNoAudioCapability` so UI can suggest exclusion.
  private func markRouteError(at index: Int, error: Error) {
    if case BackendError.noActiveAudioStream = error {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.apps[index].hasNoAudioCapability = false
      return
    }

    snapshot.apps[index].routingState = .error
    snapshot.apps[index].notes = error.localizedDescription
    if case BackendError.noAudioCapability = error {
      snapshot.apps[index].hasNoAudioCapability = true
    } else {
      snapshot.apps[index].hasNoAudioCapability = false
    }
  }

  private func reattachRoutes(forLogicalIDs logicalIDs: Set<String>) async {
    guard !isShuttingDown else { return }
    var lastError: String?

    // applyRoute suspends (tap-retry backoff) and the actor is reentrant, so a
    // concurrent refresh/buildSnapshot can replace `snapshot.apps` mid-loop.
    // Iterate by logicalID and re-resolve the row after every await — a stale
    // index would trap or write onto the wrong app. Rows that vanished are
    // skipped.
    let targetLogicalIDs = snapshot.apps.map(\.logicalID).filter { logicalIDs.contains($0) }
    for logicalID in targetLogicalIDs {
      guard !isShuttingDown else { return }
      guard let app = snapshot.apps.first(where: { $0.logicalID == logicalID }) else { continue }

      do {
        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted
        )
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          snapshot.apps[index].routingState = .managed
          snapshot.apps[index].appliedVolume =
            snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
          snapshot.apps[index].notes = nil
        }
      } catch {
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          markRouteError(at: index, error: error)
        }
        lastError = error.localizedDescription
      }
    }

    // Health is "no errors anywhere", not "any route recovered": a partial
    // reattach that leaves some apps in .error must keep the badge red.
    refreshGlobalRouteHealth(latestError: lastError)
    snapshot.updatedAt = .now
  }

  private func startLevelUpdateTask() {
    guard !isShuttingDown else { return }
    levelUpdateTask?.cancel()
    levelUpdateTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000) // 0.25 seconds (optimized from 0.1s)
        await self?.updateAudioLevels()
      }
    }
  }

  private func stopLevelUpdateTask() {
    levelUpdateTask?.cancel()
    levelUpdateTask = nil
  }

  private func updateAudioLevels() async {
    guard !isShuttingDown, !controllers.isEmpty else { return }

    let appIndexMap = snapshot.apps.enumerated().reduce(into: [String: Int]()) { result, pair in
      result[pair.element.logicalID] = pair.offset
    }

    var routeIDsNeedingRebuild = Set<String>()

    for (appID, controller) in controllers {
      if let detail = controller.takeGeometryMismatchDiagnostic() {
        logger.error("\(detail)")
      }

      guard controller.isActive else {
        routeIDsNeedingRebuild.insert(appID)
        continue
      }

      let (peak, rms) = controller.getCurrentLevels()

      if let index = appIndexMap[appID] ?? snapshot.apps.firstIndex(where: { $0.id == appID }) {
        let app = snapshot.apps[index]
        // A muted or volume-0 app emits silence, so its meters must read zero even
        // if the controller's last render cycle left a stale non-zero level (e.g.
        // the controller is gone, or a short-circuit branch raced the poll).
        // Only an EXPLICIT zero applied volume forces silence: a nil appliedVolume
        // means "unknown", not "muted" (e.g. an app first enrolled via the Boost
        // menu has a managed route but no assigned appliedVolume), and must not
        // zero its meters.
        let isVolumeZero = app.appliedVolume.map { $0 == 0 } ?? false
        if app.isMuted || isVolumeZero {
          snapshot.apps[index].peakLevel = 0
          snapshot.apps[index].rmsLevel = 0
        } else {
          snapshot.apps[index].peakLevel = peak
          snapshot.apps[index].rmsLevel = rms
        }

        let sourceIsRunningOutput = controller.targetProcessObjectIDs.contains { isProcessRunningOutput($0) }
        let measuredLevel = max(peak, rms)
        if app.routingState == .managed,
           !app.isMuted,
           !isVolumeZero,
           sourceIsRunningOutput,
           measuredLevel <= staleRouteLevelThreshold {
          let ticks = (staleRouteTicks[app.logicalID] ?? 0) + 1
          staleRouteTicks[app.logicalID] = ticks
          if ticks >= staleRouteThresholdTicks {
            routeIDsNeedingRebuild.insert(app.logicalID)
          }
        } else {
          staleRouteTicks.removeValue(forKey: app.logicalID)
        }
      }
    }

    routeMaintenanceTick += 1
    if routeMaintenanceTick >= routeMaintenanceTickInterval || !routeIDsNeedingRebuild.isEmpty {
      routeMaintenanceTick = 0
      await maintainManagedRoutes(forceRebuildIDs: routeIDsNeedingRebuild)
    }
  }

  private func maintainManagedRoutes(forceRebuildIDs: Set<String> = []) async {
    guard !isShuttingDown else { return }
    let managedIDs = snapshot.apps
      .filter { $0.routingState == .managed || forceRebuildIDs.contains($0.logicalID) || forceRebuildIDs.contains($0.id) }
      .map(\.logicalID)
    guard !managedIDs.isEmpty else { return }

    var changed = false
    var lastError: String?

    for appID in managedIDs {
      guard !isShuttingDown else { return }
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
        continue
      }

      let app = snapshot.apps[index]
      let shouldForceRebuild = forceRebuildIDs.contains(app.logicalID) || forceRebuildIDs.contains(app.id)

      do {
        let processObjectIDs = try resolveProcessObjectIDs(for: app)
        if !shouldForceRebuild,
           let controller = controllers[app.id],
           controller.isActive,
           controller.covers(processObjectIDs) {
          continue
        }

        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted,
          forceRebuild: shouldForceRebuild
        )

        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
          snapshot.apps[currentIndex].routingState = .managed
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
          snapshot.apps[currentIndex].notes = nil
        }
        staleRouteTicks.removeValue(forKey: app.logicalID)
        changed = true
      } catch {
        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
          markRouteError(at: currentIndex, error: error)
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
        }
        staleRouteTicks.removeValue(forKey: app.logicalID)
        lastError = error.localizedDescription
        changed = true
      }
    }

    if changed {
      refreshGlobalRouteHealth(latestError: lastError)
      snapshot.updatedAt = .now
    }
  }

  private func addDeviceChangeListener() {
    guard !isShuttingDown else { return }
    // Avoid registering a second listener (and leaking the previous block) if
    // start() runs more than once.
    guard deviceChangeListenerBlock == nil else { return }

    let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
      let selectors = (0..<Int(count)).map { addresses[$0].mSelector }
      Task { [weak self] in
        await self?.handleDeviceChange(selectors: selectors)
      }
    }

    let selectors: [AudioObjectPropertySelector] = [
      kAudioHardwarePropertyDefaultOutputDevice,
      kAudioHardwarePropertyDevices,
    ]

    for selector in selectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      let status = AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        DispatchQueue.main,
        listenerBlock
      )

      if status == noErr {
        deviceChangeListenerSelectors.append(selector)
      } else {
        logger.error("Failed to add device change listener \(selector): \(status)")
      }
    }

    if !deviceChangeListenerSelectors.isEmpty {
      deviceChangeListenerBlock = listenerBlock
    }
  }

  private func removeDeviceChangeListener() -> [CleanupDegradation] {
    guard let listenerBlock = deviceChangeListenerBlock else {
      deviceChangeListenerSelectors.removeAll()
      return []
    }

    var observations: [CleanupStatusObservation] = []
    for selector in deviceChangeListenerSelectors {
      var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      observations.append(CleanupStatusObservation(
        stage: .listenerRemoval,
        nativeStatus: AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject),
          &address,
          DispatchQueue.main,
          listenerBlock
        ),
        detail: "Remove device listener selector \(selector)"
      ))
    }

    deviceChangeListenerSelectors.removeAll()
    deviceChangeListenerBlock = nil
    return checkedCleanupDegradations(from: observations)
  }

  private func handleDeviceChange(selectors: [AudioObjectPropertySelector]) async {
    guard !isShuttingDown else { return }
    let currentDefaultUID = try? currentDefaultOutputDeviceUID()
    let defaultOutputChanged = selectors.contains(kAudioHardwarePropertyDefaultOutputDevice)
      || (lastKnownDefaultOutputDeviceUID != nil && currentDefaultUID != lastKnownDefaultOutputDeviceUID)
    lastKnownDefaultOutputDeviceUID = currentDefaultUID

    if defaultOutputChanged {
      // Re-tap managed routes only when the effective default output changed.
      // Plain device inventory churn, such as plugging in an unused interface,
      // should not tear down audible routes.
      do {
        _ = try await autoRestoreDevice()
        guard !isShuttingDown else { return }
        logger.info("Output device changed, managed routes restored")
      } catch {
        guard !isShuttingDown else { return }
        refreshGlobalRouteHealth(latestError: error.localizedDescription)
        logger.error("Output device change recovery failed: \(error.localizedDescription)")
      }
    } else {
      await reconcilePinnedRoutesAfterDeviceInventoryChange()
    }
    guard !isShuttingDown else { return }
    // Notify observers (the store) so they can refresh UI state and restore
    // per-device volume presets, regardless of whether restoration succeeded.
    deviceChangeContinuation.yield()
  }

  private func reconcilePinnedRoutesAfterDeviceInventoryChange() async {
    let availableUIDs = Set(allDeviceIDs().compactMap(deviceUID))
    guard !availableUIDs.isEmpty else { return }

    var lastError: String?
    var routesNeedingReattach: Set<String> = []

    for app in snapshot.apps {
      guard let targetDeviceUID = app.targetDeviceUID else { continue }
      let isActivelyManaged = app.routingState == .managed || controllers[app.id]?.isActive == true
      let targetIsAvailable = availableUIDs.contains(targetDeviceUID)

      if isActivelyManaged, !targetIsAvailable {
        if let controller = controllers.removeValue(forKey: app.id) {
          retainCleanupDegradations(controller.dispose())
        }
        controllerGenerationByRuntimeID.removeValue(forKey: app.id)
        staleRouteTicks.removeValue(forKey: app.logicalID)
        let error = BackendError.managedRouteUnavailable(
          "The chosen output device for \(app.displayName) is unavailable. Pick another in the app's Output Device menu."
        )
        if let index = snapshot.apps.firstIndex(where: { $0.id == app.id || $0.logicalID == app.logicalID }) {
          markRouteError(at: index, error: error)
          snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
          snapshot.apps[index].peakLevel = 0
          snapshot.apps[index].rmsLevel = 0
        }
        lastError = error.localizedDescription
      } else if app.routingState == .error, targetIsAvailable, !app.hasNoAudioCapability {
        routesNeedingReattach.insert(app.logicalID)
      }
    }

    if !routesNeedingReattach.isEmpty {
      await reattachRoutes(forLogicalIDs: routesNeedingReattach)
      if lastError != nil {
        refreshGlobalRouteHealth(latestError: lastError)
        snapshot.updatedAt = .now
      }
    } else if lastError != nil {
      refreshGlobalRouteHealth(latestError: lastError)
      snapshot.updatedAt = .now
    }
  }
}

struct CaptureAuthorizationPresentation: Hashable, Sendable {
  let status: DiagnosticsStatus
  let detail: String
  let backendErrorDetail: String?

  init(_ result: CaptureAuthorizationResult) {
    switch result {
    case .authorized:
      status = .passed
      detail = "Audio capture is granted. Waves can apply per-app volume, mute, and boost."
      backendErrorDetail = nil
    case .notGranted:
      status = .failed
      detail = "Audio capture is not granted, so per-app controls cannot take effect. Allow Waves to record audio in System Settings › Privacy & Security › Microphone, then refresh."
      backendErrorDetail = detail
    case .undetermined:
      status = .warning
      detail = "Audio capture status is not yet known. Refresh to check."
      backendErrorDetail = nil
    case .unsupported:
      status = .warning
      detail = "Per-app routing needs macOS 14.2 or newer."
      backendErrorDetail = nil
    case .probeFailed(let nativeStatus):
      status = .failed
      detail = "Waves could not verify audio capture authorization (OSStatus: \(nativeStatus)). Refresh to retry; if it persists, restart Waves and check the current output device."
      backendErrorDetail = detail
    }
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

private extension ProfileRowApplyOutcome {
  var isActionableFailure: Bool {
    switch self {
    case .membershipOnly, .applied, .noChange, .excluded:
      false
    case .superseded, .unavailable, .unsupported, .failed:
      true
    }
  }
}

private extension AudioObjectID {
  static let unknown = AudioObjectID(kAudioObjectUnknown)
}

private struct TapRenderState {
  var volume: Float
  var volumeBoost: Float
  var isMuted: UInt32
  var isActive: UInt32
  var peakLevel: Float
  var rmsLevel: Float
  var analysisRMS: Float
  var voiceBandEnergy: Float
  var geometryMismatchObserved: UInt32
}

private final class TapRenderStateBox {
  let state: UnsafeMutablePointer<TapRenderState>
  private let stateLock = NSLock()
  private var stateBox = TapRenderState(
    volume: 1.0,
    volumeBoost: 1.0,
    isMuted: 0,
    isActive: 0,
    peakLevel: 0,
    rmsLevel: 0,
    analysisRMS: 0,
    voiceBandEnergy: 0,
    geometryMismatchObserved: 0
  )

  init(initialState: TapRenderState) {
    state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
    state.pointee = initialState
    stateBox = initialState
  }

  deinit {
    state.deinitialize(count: 1)
    state.deallocate()
  }

  func read() -> TapRenderState {
    stateLock.lock()
    let value = state.pointee
    stateLock.unlock()
    return value
  }

  func tryRead() -> TapRenderState? {
    guard stateLock.try() else { return nil }
    let value = state.pointee
    stateLock.unlock()
    return value
  }

  func write(
    volume: Float,
    volumeBoost: Float,
    muted: Bool,
    isActive: UInt32,
    peakLevel: Float,
    rmsLevel: Float,
    analysisRMS: Float,
    voiceBandEnergy: Float
  ) {
    stateLock.lock()
    state.pointee.volume = volume
    state.pointee.volumeBoost = volumeBoost
    state.pointee.isMuted = muted ? 1 : 0
    state.pointee.isActive = isActive
    state.pointee.peakLevel = peakLevel
    state.pointee.rmsLevel = rmsLevel
    state.pointee.analysisRMS = analysisRMS
    state.pointee.voiceBandEnergy = voiceBandEnergy
    stateBox.volume = volume
    stateBox.volumeBoost = volumeBoost
    stateBox.isMuted = muted ? 1 : 0
    stateBox.isActive = isActive
    stateBox.peakLevel = peakLevel
    stateBox.rmsLevel = rmsLevel
    stateBox.analysisRMS = analysisRMS
    stateBox.voiceBandEnergy = voiceBandEnergy
    stateLock.unlock()
  }

  func writeVolumeAndMute(volume: Float, volumeBoost: Float, muted: Bool) {
    stateLock.lock()
    state.pointee.volume = volume
    state.pointee.volumeBoost = volumeBoost
    state.pointee.isMuted = muted ? 1 : 0
    stateBox.volume = volume
    stateBox.volumeBoost = volumeBoost
    stateBox.isMuted = muted ? 1 : 0
    stateLock.unlock()
  }

  func writeLevels(
    peakLevel: Float,
    rmsLevel: Float,
    analysisRMS: Float,
    voiceBandEnergy: Float
  ) {
    // Invoked from the realtime IO render thread, which must never block. If the
    // lock is contended, skip this update — level meters are cosmetic and the
    // next render cycle will refresh them.
    guard stateLock.try() else { return }
    state.pointee.peakLevel = peakLevel
    state.pointee.rmsLevel = rmsLevel
    state.pointee.analysisRMS = analysisRMS
    state.pointee.voiceBandEnergy = voiceBandEnergy
    stateBox.peakLevel = peakLevel
    stateBox.rmsLevel = rmsLevel
    stateBox.analysisRMS = analysisRMS
    stateBox.voiceBandEnergy = voiceBandEnergy
    stateLock.unlock()
  }

  func readLevels() -> (peak: Float, rms: Float) {
    stateLock.lock()
    let levels = (state.pointee.peakLevel, state.pointee.rmsLevel)
    stateLock.unlock()
    return levels
  }

  func readAdaptiveAnalysis() -> AdaptiveAnalysisLevels {
    stateLock.lock()
    let analysis = AdaptiveAnalysisLevels(
      rms: state.pointee.analysisRMS,
      voiceBandEnergy: state.pointee.voiceBandEnergy
    )
    stateLock.unlock()
    return analysis
  }

  func flagGeometryMismatch() {
    // The realtime callback must never wait for diagnostics state. Missing a flag
    // during contention is acceptable because a persistent mismatch is observed
    // again on the next callback.
    guard stateLock.try() else { return }
    state.pointee.geometryMismatchObserved = 1
    stateBox.geometryMismatchObserved = 1
    stateLock.unlock()
  }

  func consumeGeometryMismatch() -> Bool {
    stateLock.lock()
    let wasObserved = state.pointee.geometryMismatchObserved != 0
    state.pointee.geometryMismatchObserved = 0
    stateBox.geometryMismatchObserved = 0
    stateLock.unlock()
    return wasObserved
  }

  func setInactive() {
    stateLock.lock()
    state.pointee.isActive = 0
    stateBox.isActive = 0
    stateLock.unlock()
  }
}

private final class PerAppTapController: @unchecked Sendable {
  let appID: String
  let appName: String
  let targetProcessObjectIDs: [AudioObjectID]
  let tapID: AudioObjectID
  let aggregateDeviceID: AudioObjectID

  private let stateBox: TapRenderStateBox
  private let audioFormatPlan: AudioFormatPlan
  private let equalizerDSP: EqualizerDSP
  private let managedAudioEqualizerDSP: EqualizerDSP
  private let voiceBandAnalyzer: VoiceBandEnergyAnalyzer
  private let callbackQueue: DispatchQueue
  private let callbackQueueKey = DispatchSpecificKey<UUID>()
  private let callbackQueueToken = UUID()
  private var ioProcID: AudioDeviceIOProcID?
  private var didStartIOProc = false
  private let disposeOnce = IdempotentCleanupResult()
  private var retainedCleanupDegradations: [CleanupDegradation] = []
  private var didReportGeometryMismatch = false
  private var equalizerSettings: EqualizerSettings
  private var managedAudioEqualizerSettings: GlobalEqualizerSettings
  private var equalizerHeadroomGain: Float
  /// Invalidates a scheduled headroom release when a newer EQ change lands
  /// first. Accessed only on `callbackQueue`, like the gain itself.
  private var equalizerHeadroomReleaseGeneration: UInt64 = 0
  private var adaptiveGain: Float

  init(
    appID: String,
    appName: String,
    targetProcessObjectIDs: [AudioObjectID],
    tapID: AudioObjectID,
    aggregateDeviceID: AudioObjectID,
    volume: Float,
    volumeBoost: Float,
    muted: Bool,
    equalizerSettings: EqualizerSettings,
    managedAudioEqualizerSettings: GlobalEqualizerSettings,
    adaptiveGainDB: Float,
    audioFormatPlan: AudioFormatPlan
  ) throws {
    self.appID = appID
    self.appName = appName
    self.targetProcessObjectIDs = targetProcessObjectIDs
    self.tapID = tapID
    self.aggregateDeviceID = aggregateDeviceID
    self.audioFormatPlan = audioFormatPlan
    self.equalizerDSP = EqualizerDSP(
      sampleRate: audioFormatPlan.sampleRate,
      channelCount: audioFormatPlan.channelCount,
      settings: equalizerSettings
    )
    self.managedAudioEqualizerDSP = EqualizerDSP(
      sampleRate: audioFormatPlan.sampleRate,
      channelCount: audioFormatPlan.channelCount,
      settings: managedAudioEqualizerSettings.equalizerSettings
    )
    self.voiceBandAnalyzer = VoiceBandEnergyAnalyzer(
      sampleRate: audioFormatPlan.sampleRate,
      channelCount: audioFormatPlan.channelCount
    )
    self.equalizerSettings = equalizerSettings
    self.managedAudioEqualizerSettings = managedAudioEqualizerSettings
    self.equalizerHeadroomGain = GlobalEqualizerSettings.combinedHeadroomGain(
      perApp: equalizerSettings,
      managedAudio: managedAudioEqualizerSettings
    )
    let safeAdaptiveGainDB = adaptiveGainDB.isFinite ? min(3, max(-18, adaptiveGainDB)) : 0
    self.adaptiveGain = Float(pow(10, Double(safeAdaptiveGainDB) / 20))
    self.callbackQueue = DispatchQueue(label: "com.waves.backend.tap.\(appID)", qos: .userInitiated)
    let initialState = TapRenderState(
      volume: volume,
      volumeBoost: volumeBoost,
      isMuted: muted ? 1 : 0,
      isActive: 1,
      peakLevel: 0,
      rmsLevel: 0,
      analysisRMS: 0,
      voiceBandEnergy: 0,
      geometryMismatchObserved: 0
    )
    self.stateBox = TapRenderStateBox(initialState: initialState)
    self.callbackQueue.setSpecific(key: callbackQueueKey, value: callbackQueueToken)
  }

  var isActive: Bool {
    stateBox.read().isActive != 0 && ioProcID != nil && aggregateDeviceID != .unknown
  }

  func matches(_ processObjectIDs: [AudioObjectID]) -> Bool {
    targetProcessObjectIDs == processObjectIDs
  }

  /// Whether this controller's existing tap already captures every process in
  /// `processObjectIDs`. Used so a parameter-only change (volume/mute/boost) on a
  /// browser/Electron app — whose audible helper PIDs churn between calls — reuses
  /// the live tap instead of tearing it down, while still rebuilding when a *new*
  /// audio-producing process appears that the current tap doesn't cover.
  func covers(_ processObjectIDs: [AudioObjectID]) -> Bool {
    Set(processObjectIDs).isSubset(of: Set(targetProcessObjectIDs))
  }

  func apply(volume: Float, volumeBoost: Float, muted: Bool) {
    let clampedVolume = max(0.0, min(1.0, volume))
    let clampedBoost = max(1.0, min(4.0, volumeBoost))
    // Use async to avoid blocking the caller, especially important for real-time audio
    callbackQueue.async { [weak self] in
      self?.stateBox.writeVolumeAndMute(volume: clampedVolume, volumeBoost: clampedBoost, muted: muted)
    }
  }

  func setVolumeBoost(_ boost: Float) {
    let clampedBoost = max(1.0, min(4.0, boost))
    let currentState = stateBox.read()
    callbackQueue.async { [weak self] in
      self?.stateBox.writeVolumeAndMute(
        volume: currentState.volume,
        volumeBoost: clampedBoost,
        muted: currentState.isMuted != 0
      )
    }
  }

  func setEqualizer(_ settings: EqualizerSettings) {
    callbackQueue.async { [weak self] in
      guard let self else { return }
      self.equalizerSettings = settings
      self.equalizerDSP.update(settings: settings)
      self.updateEqualizerHeadroomGain()
    }
  }

  func setManagedAudioEqualizer(_ settings: GlobalEqualizerSettings) {
    callbackQueue.async { [weak self] in
      guard let self else { return }
      self.managedAudioEqualizerSettings = settings
      self.managedAudioEqualizerDSP.update(settings: settings.equalizerSettings)
      self.updateEqualizerHeadroomGain()
    }
  }

  /// Runs on `callbackQueue`. Extra attenuation lands immediately; *reduced*
  /// attenuation is held for three smoothing windows first, because the EQ
  /// coefficients themselves ramp to their new curve over ~20 ms — releasing
  /// protection while the old boost is still partially in the filters would
  /// clip exactly the transient the headroom exists to absorb.
  private func updateEqualizerHeadroomGain() {
    let target = GlobalEqualizerSettings.combinedHeadroomGain(
      perApp: equalizerSettings,
      managedAudio: managedAudioEqualizerSettings
    )
    equalizerHeadroomReleaseGeneration &+= 1
    if target <= equalizerHeadroomGain {
      equalizerHeadroomGain = target
      return
    }
    let generation = equalizerHeadroomReleaseGeneration
    callbackQueue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
      guard let self, self.equalizerHeadroomReleaseGeneration == generation else { return }
      self.equalizerHeadroomGain = target
    }
  }

  func setAdaptiveGainDB(_ gainDB: Float) {
    let safeGainDB = gainDB.isFinite ? min(3, max(-18, gainDB)) : 0
    callbackQueue.async { [weak self] in
      self?.adaptiveGain = Float(pow(10, Double(safeGainDB) / 20))
    }
  }

  func getCurrentLevels() -> (peak: Float, rms: Float) {
    stateBox.readLevels()
  }

  func getAdaptiveAnalysis() -> AdaptiveAnalysisLevels {
    stateBox.readAdaptiveAnalysis()
  }

  func takeGeometryMismatchDiagnostic() -> String? {
    guard stateBox.consumeGeometryMismatch(), !didReportGeometryMismatch else { return nil }
    didReportGeometryMismatch = true
    let layout = audioFormatPlan.isInterleaved ? "interleaved" : "noninterleaved"
    return "Silenced \(appName) because Core Audio callback geometry did not match the validated \(layout) \(audioFormatPlan.channelCount)-channel \(audioFormatPlan.sampleFormat) plan."
  }

  func start() throws {
    var procID: AudioDeviceIOProcID?

    let status = AudioDeviceCreateIOProcIDWithBlock(
      &procID,
      aggregateDeviceID,
      callbackQueue
    ) { _, inputData, _, outOutputData, _ in
      guard self.validatesCallbackGeometry(inputData, outputData: outOutputData) else {
        self.stateBox.flagGeometryMismatch()
        self.zeroOutput(outOutputData)
        return
      }

      guard let currentState = self.stateBox.tryRead() else {
        self.zeroOutput(outOutputData)
        return
      }

      guard currentState.isActive != 0 else {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0, analysisRMS: 0, voiceBandEnergy: 0)
        self.zeroOutput(outOutputData)
        return
      }

      if currentState.isMuted != 0 {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0, analysisRMS: 0, voiceBandEnergy: 0)
        self.zeroOutput(outOutputData)
        return
      }

      let volume = currentState.volume
      let volumeBoost = currentState.volumeBoost
      if volume == 0.0 {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0, analysisRMS: 0, voiceBandEnergy: 0)
        self.zeroOutput(outOutputData)
        return
      }

      self.renderTappedAudio(
        inputData,
        to: outOutputData,
        volume: volume,
        volumeBoost: volumeBoost
      )
    }

    if status != noErr {
      if let procID {
        retainedCleanupDegradations.append(contentsOf: checkedCleanupDegradations(from: [
          CleanupStatusObservation(
            appID: appID,
            stage: .ioProcDestroy,
            nativeStatus: AudioDeviceDestroyIOProcID(aggregateDeviceID, procID),
            detail: "Destroy IO proc returned by a failed create call"
          )
        ]))
      }
      throw BackendError.managedRouteUnavailable(
        "Failed to create IO proc for \(appName) (OSStatus: \(status))."
      )
    }

    guard let procID else {
      throw BackendError.managedRouteUnavailable(
        "Failed to create IO proc for \(appName)."
      )
    }

    ioProcID = procID
    try configureStreamUsage(for: procID)
    try configureStreamUsage(for: procID, scope: kAudioObjectPropertyScopeOutput)

    let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
    if startStatus != noErr {
      stateBox.setInactive()
      retainedCleanupDegradations.append(contentsOf: checkedCleanupDegradations(from: [
        CleanupStatusObservation(
          appID: appID,
          stage: .ioProcDestroy,
          nativeStatus: AudioDeviceDestroyIOProcID(aggregateDeviceID, procID),
          detail: "Destroy IO proc after aggregate-device start failure"
        )
      ]))
      ioProcID = nil
      throw BackendError.managedRouteUnavailable(
        "Failed to start aggregate device for \(appName) (OSStatus: \(startStatus))."
      )
    }
    didStartIOProc = true
  }

  private func configureStreamUsage(for procID: AudioDeviceIOProcID) throws {
    try configureStreamUsage(for: procID, scope: kAudioObjectPropertyScopeInput)
  }

  private func configureStreamUsage(
    for procID: AudioDeviceIOProcID,
    scope: AudioObjectPropertyScope
  ) throws {
    let streamCount = try streamCount(scope: scope)
    guard streamCount > 0 else { return }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyIOProcStreamUsage,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )

    let usageSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
      + (Int(streamCount) - 1) * MemoryLayout<UInt32>.stride
    let usagePointer = UnsafeMutableRawPointer.allocate(
      byteCount: usageSize,
      alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
    )
    defer { usagePointer.deallocate() }

    usagePointer.initializeMemory(as: UInt8.self, repeating: 0, count: usageSize)
    let typedUsage = usagePointer.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    typedUsage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
    typedUsage.pointee.mNumberStreams = streamCount

    let streamsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 0
    let streams = usagePointer
      .advanced(by: streamsOffset)
      .assumingMemoryBound(to: UInt32.self)
    for index in 0..<Int(streamCount) {
      streams[index] = 1
    }

    let status = AudioObjectSetPropertyData(
      aggregateDeviceID,
      &address,
      0,
      nil,
      UInt32(usageSize),
      usagePointer
    )

    if status != noErr {
      throw BackendError.managedRouteUnavailable(
        "Failed to enable aggregate stream usage for \(appName) (OSStatus: \(status))."
      )
    }
  }

  private func streamCount(scope: AudioObjectPropertyScope) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(aggregateDeviceID, &address, 0, nil, &dataSize)
    if status != noErr {
      throw BackendError.managedRouteUnavailable(
        "Failed to read stream configuration size for \(appName) (OSStatus: \(status))."
      )
    }

    let bufferListPointer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }

    status = AudioObjectGetPropertyData(
      aggregateDeviceID,
      &address,
      0,
      nil,
      &dataSize,
      bufferListPointer
    )
    if status != noErr {
      throw BackendError.managedRouteUnavailable(
        "Failed to read stream configuration for \(appName) (OSStatus: \(status))."
      )
    }

    let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
    return UInt32(UnsafeMutableAudioBufferListPointer(audioBufferList).count)
  }

  @discardableResult
  func invalidate() -> [CleanupDegradation] {
    guard let procID = ioProcID, aggregateDeviceID != .unknown else {
      ioProcID = nil
      didStartIOProc = false
      stateBox.setInactive()
      return []
    }

    stateBox.setInactive()
    var observations: [CleanupStatusObservation] = []
    if didStartIOProc {
      observations.append(CleanupStatusObservation(
        appID: appID,
        stage: .ioProcStop,
        nativeStatus: AudioDeviceStop(aggregateDeviceID, procID),
        detail: "Stop controller IO proc during invalidation"
      ))
    }
    didStartIOProc = false
    drainCallbackQueue()
    observations.append(CleanupStatusObservation(
      appID: appID,
      stage: .ioProcDestroy,
      nativeStatus: AudioDeviceDestroyIOProcID(aggregateDeviceID, procID),
      detail: "Destroy controller IO proc during invalidation"
    ))
    ioProcID = nil
    return checkedCleanupDegradations(from: observations)
  }

  @discardableResult
  func dispose() -> [CleanupDegradation] {
    disposeOnce.run { [self] in
      stateBox.setInactive()
      var observations: [CleanupStatusObservation] = []
      if let procID = ioProcID, aggregateDeviceID != .unknown {
        if didStartIOProc {
          observations.append(CleanupStatusObservation(
            appID: appID,
            stage: .ioProcStop,
            nativeStatus: AudioDeviceStop(aggregateDeviceID, procID),
            detail: "Stop controller IO proc"
          ))
        }
        didStartIOProc = false
        drainCallbackQueue()
        observations.append(CleanupStatusObservation(
          appID: appID,
          stage: .ioProcDestroy,
          nativeStatus: AudioDeviceDestroyIOProcID(aggregateDeviceID, procID),
          detail: "Destroy controller IO proc"
        ))
      } else {
        didStartIOProc = false
        drainCallbackQueue()
      }
      ioProcID = nil

      if aggregateDeviceID != .unknown {
        observations.append(CleanupStatusObservation(
          appID: appID,
          stage: .aggregateDeviceDestroy,
          nativeStatus: AudioHardwareDestroyAggregateDevice(aggregateDeviceID),
          detail: "Destroy controller aggregate device"
        ))
      }

      if #available(macOS 14.2, *), tapID != .unknown {
        observations.append(CleanupStatusObservation(
          appID: appID,
          stage: .processTapDestroy,
          nativeStatus: AudioHardwareDestroyProcessTap(tapID),
          detail: "Destroy controller process tap"
        ))
      }

      let result = retainedCleanupDegradations
        + checkedCleanupDegradations(from: observations)
      retainedCleanupDegradations.removeAll()
      return result
    }
  }

  deinit {
    _ = dispose()
  }

  private func validatesCallbackGeometry(
    _ inputData: UnsafePointer<AudioBufferList>?,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> Bool {
    guard let inputData else { return false }
    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    let expectedBufferCount = audioFormatPlan.isInterleaved ? 1 : audioFormatPlan.channelCount
    guard inputBuffers.count == expectedBufferCount,
          outputBuffers.count == expectedBufferCount else {
      return false
    }

    var expectedByteCount: Int?
    for index in 0..<expectedBufferCount {
      let inputBuffer = inputBuffers[index]
      let outputBuffer = outputBuffers[index]
      let expectedChannels = audioFormatPlan.isInterleaved
        ? audioFormatPlan.channelCount
        : 1
      let inputByteCount = Int(inputBuffer.mDataByteSize)
      let outputByteCount = Int(outputBuffer.mDataByteSize)
      guard Int(inputBuffer.mNumberChannels) == expectedChannels,
            Int(outputBuffer.mNumberChannels) == expectedChannels,
            inputByteCount == outputByteCount,
            inputByteCount.isMultiple(of: audioFormatPlan.bytesPerFrame),
            inputByteCount == 0 || (inputBuffer.mData != nil && outputBuffer.mData != nil) else {
        return false
      }

      if let expectedByteCount {
        guard inputByteCount == expectedByteCount else { return false }
      } else {
        expectedByteCount = inputByteCount
      }
    }
    return true
  }

  private func renderTappedAudio(
    _ inputData: UnsafePointer<AudioBufferList>?,
    to outputData: UnsafeMutablePointer<AudioBufferList>,
    volume: Float,
    volumeBoost: Float
  ) {
    guard let inputData else {
      zeroOutput(outputData)
      return
    }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

    var analysisSum: Float = 0
    var analysisSampleCount: UInt32 = 0
    var voiceEnergySum: Float = 0
    var voiceSampleCount: UInt32 = 0
    var finalPeak: Float = 0
    var finalSum: Float = 0
    var finalSampleCount: UInt32 = 0
    var channelOffset = 0

    let manualGain = volume * volumeBoost

    for index in outputBuffers.indices {
      let outputBuffer = outputBuffers[index]
      let bufferChannelCount = max(1, Int(outputBuffer.mNumberChannels))
      let currentChannelOffset = channelOffset
      channelOffset += bufferChannelCount
      guard let outputPointer = outputBuffer.mData else { continue }
      guard index < inputBuffers.count else {
        memset(outputPointer, 0, Int(outputBuffer.mDataByteSize))
        continue
      }

      let inputBuffer = inputBuffers[index]
      guard let inputPointer = inputBuffer.mData else {
        memset(outputPointer, 0, Int(outputBuffer.mDataByteSize))
        continue
      }

      let outputByteCount = Int(outputBuffer.mDataByteSize)
      let copyByteCount = min(Int(inputBuffer.mDataByteSize), outputByteCount)
      guard copyByteCount > 0 else { continue }

      memcpy(outputPointer, inputPointer, copyByteCount)
      if outputByteCount > copyByteCount {
        memset(outputPointer.advanced(by: copyByteCount), 0, outputByteCount - copyByteCount)
      }

      // Apply the combined compensation before either filter. EqualizerDSP
      // clamps typed samples to their valid range, so pre-attenuation is the
      // realtime-safe way to prevent stacked boosts from clipping internally.
      TapDSP.scale(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        gain: equalizerHeadroomGain
      )
      equalizerDSP.process(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        bufferChannelCount: bufferChannelCount,
        channelOffset: currentChannelOffset
      )
      managedAudioEqualizerDSP.process(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        bufferChannelCount: bufferChannelCount,
        channelOffset: currentChannelOffset
      )
      TapDSP.scale(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        gain: manualGain
      )

      // Adaptive analysis observes the user's EQ and manual controls, but not
      // its own temporary correction, so it cannot chase itself.
      let (_, preAdaptiveSum, preAdaptiveSamples) = TapDSP.levels(
        from: outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat
      )
      analysisSum += preAdaptiveSum
      analysisSampleCount += preAdaptiveSamples
      let voice = voiceBandAnalyzer.analyze(
        UnsafeRawPointer(outputPointer),
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        bufferChannelCount: bufferChannelCount,
        channelOffset: currentChannelOffset
      )
      voiceEnergySum += voice.energySum
      voiceSampleCount += voice.sampleCount

      TapDSP.scale(outputPointer, byteCount: copyByteCount, format: audioFormatPlan.sampleFormat, gain: adaptiveGain)

      let (bufferPeak, bufferSum, bufferSamples) = TapDSP.levels(
        from: outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat
      )
      finalPeak = max(finalPeak, bufferPeak)
      finalSum += bufferSum
      finalSampleCount += bufferSamples
    }

    let voiceBandEnergy = voiceSampleCount > 0
      ? voiceEnergySum / Float(voiceSampleCount)
      : 0
    stateBox.writeLevels(
      peakLevel: finalPeak,
      rmsLevel: TapDSP.rms(sum: finalSum, sampleCount: finalSampleCount),
      analysisRMS: TapDSP.rms(sum: analysisSum, sampleCount: analysisSampleCount),
      voiceBandEnergy: voiceBandEnergy.isFinite ? voiceBandEnergy : 0
    )
  }

  private func zeroOutput(_ outOutputData: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(outOutputData)
    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
  }

  private func drainCallbackQueue() {
    if DispatchQueue.getSpecific(key: callbackQueueKey) == callbackQueueToken {
      return
    }

    callbackQueue.sync {}
  }
}
