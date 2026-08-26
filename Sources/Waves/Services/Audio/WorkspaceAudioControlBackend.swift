import AppKit
import AudioToolbox
import Darwin
import Foundation
import OSLog
import WavesAudioCore

/// Read-only ownership view for lifecycle tests. Every value is derived from
/// the backend's production collections, never maintained as a second model.
struct AudioBackendLifecycleDebugSnapshot: Equatable, Sendable {
  let liveControllers: Int
  let orphanedControllers: Int
  let retainedCallbackOwners: Int
  let routerListenerRegistrations: Int
  let pendingGeometryRecoveries: Int
  let retainedGeometryRecoveryStates: Int
}

actor WorkspaceAudioControlBackend: AudioControlBackend {
  // Start from a neutral, empty session. Using `.preview` here would seed the
  // live backend with fabricated apps, volumes, and a fake error string that
  // could surface before the first real snapshot is built.
  var snapshot: AudioSessionSnapshot = .empty
  private let currentBundleID = Bundle.main.bundleIdentifier
  var controllers: [String: PerAppTapController] = [:]
  var controllerGenerationByRuntimeID: [String: UInt64] = [:]
  private var equalizerSettingsByAppID: [String: EqualizerSettings] = [:]
  private var managedAudioEqualizerSettings = GlobalEqualizerSettings()
  private var adaptiveGainDBByAppID: [String: Float] = [:]
  private var latestAcceptedGenerationByLogicalID: [String: UInt64] = [:]
  private var stagedIntentByLogicalID: [String: AppRouteIntent] = [:]
  private var legacyGeneration: UInt64 = 0
  private var isStarted = false
  var isShuttingDown = false
  var lifecycleEpoch: UInt64 = 0
  private var shutdownTask: Task<BackendShutdownResult, Never>?
  private var shutdownResult: BackendShutdownResult?
  private var didFinishDeviceChangeContinuation = false
  private var retainedCleanupDegradations: [CleanupDegradation] = []
  /// How many rows were discarded once the buffer filled, so a bounded report
  /// never reads as a complete one.
  private var droppedCleanupDegradations = 0
  private var cleanupDegradationLogCounts: [CleanupLogKey: Int] = [:]
  /// Comfortably above `DiagnosticsExportFormatter.maximumCleanupRows`, so the
  /// export's own bound stays the one that shapes the report.
  private static let maxRetainedCleanupDegradations = 64

  private struct CleanupLogKey: Hashable {
    let stage: CleanupStage
    let appID: String?
  }
  private var levelUpdateTask: Task<Void, Never>?
  private var routeMaintenanceTick = 0
  private var geometryRecoveryByRuntimeID: [String: GeometryRecoveryCoordinator] = [:]
  var routerConflictObservationByRuntimeID: [String: RouterConflictObservationDebouncer] = [:]
  private var routerObservationListenerFailureDetail: String?
  var routerObservationGeneration: UInt64 = 1
  var consumedRouterObservationGeneration: UInt64 = 0
  var staleRouteTicks: [String: Int] = [:]
  /// Last IO-render-callback count seen per app, so a route that has genuinely
  /// stopped rendering can be told apart from one that is merely silent.
  var lastRenderTickByAppID: [String: UInt64] = [:]
  /// Authorization-probe taps whose destroy failed, awaiting another attempt.
  var leakedProbeTapIDs: [AudioObjectID] = []
  var probeTapDestroyAttempts: [AudioObjectID: Int] = [:]
  let maxProbeTapDestroyRetries = 5
  /// Controllers whose native teardown failed, awaiting another attempt.
  private var orphanedControllers: [PerAppTapController] = []
  private var orphanDisposeAttempts: [ObjectIdentifier: Int] = [:]
  private static let maxOrphanDisposeRetries = 5
  private let routeMaintenanceTickInterval = 20
  private let staleRouteThresholdTicks = 24
  var deviceChangeListenerSelectors: [AudioObjectPropertySelector] = []
  var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
  private let routerObservationListeners: RouterObservationListenerLifecycle
  var defaultOutputDeviceChange = DefaultOutputDeviceChange()
  private var outputDeviceReadinessError: String?
  let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "AudioBackend")

  typealias IntentRouteApplyOverride = @Sendable (AudioApp, EqualizerSettings) async throws -> Void
  typealias ShutdownCleanupOverride = @Sendable () -> [CleanupDegradation]
  typealias RouteMaintenanceOverride = @Sendable (Set<String>, Set<String>) async -> Void
  typealias VerifiedRouterConflictProvider = @Sendable (AudioApp) -> VerifiedRouterConflict?
  typealias VerifiedRouterActivityProvider = @Sendable () -> VerifiedRouterActivitySnapshot
  typealias ControllerFactory =
    @Sendable (
      AudioApp,
      [AudioObjectID],
      EqualizerSettings,
      GlobalEqualizerSettings,
      Float
    ) throws -> PerAppTapController
  typealias ProcessObjectIDResolver = @Sendable (AudioApp) throws -> [AudioObjectID]
  typealias ProcessTargetResolver = @Sendable (AudioApp) throws -> ResolvedProcessTarget
  typealias ProcessObjectLivenessProvider = @Sendable (AudioObjectID) -> Bool
  typealias RuntimeIdentityProvider = @Sendable (pid_t) -> AppRuntimeIdentity?
  typealias ProcessObjectTranslator = @Sendable (pid_t) throws -> AudioObjectID?
  typealias CaptureAuthorizationProbe = @Sendable () -> CaptureAuthorizationResult
  private let intentRouteApplyOverride: IntentRouteApplyOverride?
  private let shutdownCleanupOverride: ShutdownCleanupOverride?
  private let routeMaintenanceOverride: RouteMaintenanceOverride?
  let verifiedRouterConflictProvider: VerifiedRouterConflictProvider?
  let verifiedRouterActivityProvider: VerifiedRouterActivityProvider?
  var perAppAudioController: PerAppAudioController
  var waveLinkCompatibilityEnabled: Bool
  let waveLinkController: (any WaveLinkControlling)?
  /// Tail of the strictly serialized queue of in-flight bridge applies.
  var waveLinkApplyQueueTail: Task<Void, Never>?
  private let controllerFactory: ControllerFactory?
  private let processObjectIDResolver: ProcessObjectIDResolver?
  private let processTargetResolver: ProcessTargetResolver?
  private let processObjectLivenessProvider: ProcessObjectLivenessProvider?
  private let runtimeIdentityProvider: RuntimeIdentityProvider
  private let liveRuntimeIdentityProvider: RuntimeIdentityProvider
  private let processObjectTranslator: ProcessObjectTranslator?
  let captureAuthorizationProbe: CaptureAuthorizationProbe?

  nonisolated let deviceChangeEvents: AsyncStream<Void>
  nonisolated let deviceChangeContinuation: AsyncStream<Void>.Continuation

  init(
    verifiedRouterConflictProvider: VerifiedRouterConflictProvider? = nil,
    verifiedRouterActivityProvider: VerifiedRouterActivityProvider? = nil,
    perAppAudioController: PerAppAudioController = .waves,
    waveLinkCompatibilityEnabled: Bool = true
  ) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.deviceChangeEvents = stream
    self.deviceChangeContinuation = continuation
    self.intentRouteApplyOverride = nil
    self.shutdownCleanupOverride = nil
    self.routeMaintenanceOverride = nil
    self.verifiedRouterConflictProvider = verifiedRouterConflictProvider
    self.verifiedRouterActivityProvider = verifiedRouterActivityProvider
    self.perAppAudioController = perAppAudioController
    self.waveLinkCompatibilityEnabled = waveLinkCompatibilityEnabled
    self.waveLinkController = WaveLinkControlBridge()
    self.controllerFactory = nil
    self.processObjectIDResolver = nil
    self.processTargetResolver = nil
    self.processObjectLivenessProvider = nil
    self.runtimeIdentityProvider = RuntimeProcessIdentityCache.shared.identity
    self.liveRuntimeIdentityProvider = RuntimeProcessIdentity.captureLive
    self.processObjectTranslator = nil
    self.captureAuthorizationProbe = nil
    self.routerObservationListeners = RouterObservationListenerLifecycle(
      nativeCalls: .live(on: DispatchQueue(label: "com.waves.backend.router-observation"))
    )
  }

  init(
    testingSnapshot: AudioSessionSnapshot,
    captureAuthorization: CaptureAuthorizationResult = .undetermined,
    intentRouteApplyOverride: IntentRouteApplyOverride? = nil,
    shutdownCleanupOverride: ShutdownCleanupOverride? = nil,
    verifiedRouterConflictProvider: VerifiedRouterConflictProvider? = nil,
    verifiedRouterActivityProvider: VerifiedRouterActivityProvider? = nil,
    perAppAudioController: PerAppAudioController = .waves,
    waveLinkCompatibilityEnabled: Bool = true,
    waveLinkController: (any WaveLinkControlling)? = nil,
    routerObservationNativeCalls: RouterObservationListenerNativeCalls? = nil,
    testingControllers: [PerAppTapController] = [],
    routeMaintenanceOverride: RouteMaintenanceOverride? = nil,
    controllerFactory: ControllerFactory? = nil,
    processObjectIDResolver: ProcessObjectIDResolver? = nil,
    processObjectLivenessProvider: ProcessObjectLivenessProvider? = nil,
    processTargetResolver: ProcessTargetResolver? = nil,
    runtimeIdentityProvider: @escaping RuntimeIdentityProvider = RuntimeProcessIdentityCache.shared.identity,
    liveRuntimeIdentityProvider: @escaping RuntimeIdentityProvider = RuntimeProcessIdentity.captureLive,
    processObjectTranslator: ProcessObjectTranslator? = nil,
    captureAuthorizationProbe: CaptureAuthorizationProbe? = nil
  ) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.deviceChangeEvents = stream
    self.deviceChangeContinuation = continuation
    self.snapshot = testingSnapshot
    self.captureAuthorization = captureAuthorization
    self.intentRouteApplyOverride = intentRouteApplyOverride
    self.shutdownCleanupOverride = shutdownCleanupOverride
    self.routeMaintenanceOverride = routeMaintenanceOverride
    self.verifiedRouterConflictProvider = verifiedRouterConflictProvider
    self.verifiedRouterActivityProvider = verifiedRouterActivityProvider
    self.perAppAudioController = perAppAudioController
    self.waveLinkCompatibilityEnabled = waveLinkCompatibilityEnabled
    self.waveLinkController = waveLinkController
    self.controllerFactory = controllerFactory
    self.processObjectIDResolver = processObjectIDResolver
    self.processTargetResolver = processTargetResolver
    self.processObjectLivenessProvider = processObjectLivenessProvider
    self.runtimeIdentityProvider = runtimeIdentityProvider
    self.liveRuntimeIdentityProvider = liveRuntimeIdentityProvider
    self.processObjectTranslator = processObjectTranslator
    self.captureAuthorizationProbe = captureAuthorizationProbe
    self.routerObservationListeners = RouterObservationListenerLifecycle(
      nativeCalls: routerObservationNativeCalls
        ?? .live(on: DispatchQueue(label: "com.waves.backend.router-observation"))
    )
    self.controllers = Dictionary(uniqueKeysWithValues: testingControllers.map { ($0.appID, $0) })
    self.isStarted = true
  }

  func start() async throws {
    try ensureAcceptingOperations()
    guard !isStarted else { return }
    snapshot = await buildSnapshot(merging: snapshot)
    try ensureAcceptingOperations()
    defaultOutputDeviceChange.recordInitialUID(try? currentDefaultOutputDeviceUID())
    isStarted = true
    startLevelUpdateTask()
    addDeviceChangeListener()
    retainCleanupDegradations(addRouterObservationListeners())
  }

  func lifecycleDebugSnapshot() -> AudioBackendLifecycleDebugSnapshot {
    AudioBackendLifecycleDebugSnapshot(
      liveControllers: controllers.count,
      orphanedControllers: orphanedControllers.count,
      retainedCallbackOwners: controllers.count + orphanedControllers.count,
      routerListenerRegistrations: routerObservationListeners.installedSelectorCount,
      pendingGeometryRecoveries: geometryRecoveryByRuntimeID.values.count(where: \.hasPendingRecoveryWork),
      retainedGeometryRecoveryStates: geometryRecoveryByRuntimeID.count
    )
  }

  func beginTestingLifecycle() {
    retainCleanupDegradations(addRouterObservationListeners())
  }

  func reattachRoutesForTesting(_ logicalIDs: Set<String>) async {
    await reattachRoutes(forLogicalIDs: logicalIDs)
  }

  func flagGeometryMismatchForTesting(runtimeID: String) {
    controllers[runtimeID]?.flagGeometryMismatchForTesting()
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
          checkedDegradations: [
            CleanupDegradation(
              stage: .controllerDisposal,
              detail: "The audio backend was released before cleanup could be verified."
            )
          ]
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

    // Everything below goes through `record` rather than appending directly, so
    // the failures that happen *during shutdown* are logged like every in-session
    // failure is. They previously bypassed the only logging site, which is why a
    // degraded quit left nothing behind explaining which stage had failed.
    func record(_ new: [CleanupDegradation]) {
      guard !new.isEmpty else { return }
      logCleanupDegradations(new)
      degradations.append(contentsOf: new)
    }

    record(removeDeviceChangeListener())
    record(removeRouterObservationListeners())
    defaultOutputDeviceChange.recordInitialUID(nil)

    let installedControllers = controllers.sorted { $0.key < $1.key }
    controllers.removeAll()
    for (_, controller) in installedControllers {
      let controllerDegradations = controller.dispose()
      record(controllerDegradations)
      if !controllerDegradations.isEmpty {
        // A failed stop or IO-proc destroy can still be followed by a native
        // callback. Keep its Swift callback state alive until process exit.
        orphanedControllers.append(controller)
        record([
          CleanupDegradation(
            appID: controller.appID,
            stage: .controllerDisposal,
            detail:
              "Controller disposal completed with \(controllerDegradations.count) checked native cleanup failure(s)."
          )
        ])
      }
    }
    if let shutdownCleanupOverride {
      record(shutdownCleanupOverride())
    }

    // One last attempt at anything a previous teardown could not release, so a
    // stranded tap does not outlive the process if it can be avoided.
    let parked = orphanedControllers
    orphanedControllers.removeAll(keepingCapacity: true)
    for controller in parked {
      let controllerDegradations = controller.retryDispose()
      record(controllerDegradations)
      if !controllerDegradations.isEmpty,
        !orphanedControllers.contains(where: { $0 === controller })
      {
        orphanedControllers.append(controller)
      }
    }
    orphanDisposeAttempts.removeAll()

    // Never let the buffer's cap hide the fact that it capped: a truncated
    // report that looks complete is worse than one that admits the gap.
    if droppedCleanupDegradations > 0 {
      record([
        CleanupDegradation(
          stage: .controllerDisposal,
          detail: "\(droppedCleanupDegradations) earlier cleanup failure(s) were dropped once the in-session buffer reached \(Self.maxRetainedCleanupDegradations) rows."
        )
      ])
      droppedCleanupDegradations = 0
    }

    controllerGenerationByRuntimeID.removeAll()
    equalizerSettingsByAppID.removeAll()
    adaptiveGainDBByAppID.removeAll()
    latestAcceptedGenerationByLogicalID.removeAll()
    stagedIntentByLogicalID.removeAll()
    staleRouteTicks.removeAll()
    lastRenderTickByAppID.removeAll()
    geometryRecoveryByRuntimeID.removeAll()
    routerConflictObservationByRuntimeID.removeAll()
    routeMaintenanceTick = 0
    routerObservationListenerFailureDetail = nil
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
    await applyAppIntent(intent, routerActivity: nil)
  }

  private func applyAppIntent(
    _ intent: AppRouteIntent,
    routerActivity: VerifiedRouterActivitySnapshot?
  ) async -> AppIntentApplyResult {
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
      intent.generation < latestGeneration
    {
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

    if let conflict = competingAudioRouterConflict(
      for: snapshot.apps[acceptedIndex],
      routerActivity: routerActivity
    ) {
      if shouldControlThroughWaveLink(snapshot.apps[acceptedIndex], conflict: conflict) {
        return await applyIntentThroughWaveLink(
          intent,
          logicalID: logicalID,
          acceptedIndex: acceptedIndex,
          conflict: conflict
        )
      }
      let detail = conflict.detail
      suspendManagedRouteForConflict(at: acceptedIndex, conflict: conflict)
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      snapshot.updatedAt = .now
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unsupported,
        resultingApp: snapshot.apps[acceptedIndex],
        backendStatus: snapshot.backendStatus,
        detail: detail
      )
    }

    if !supportsPerAppRouting || snapshot.apps[acceptedIndex].compatibility == .unsupported {
      let detail =
        supportsPerAppRouting
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
    let hasNoChanges =
      previousApp.desiredVolume == intent.desiredVolume
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
          generationContext: generationContext,
          routerActivity: routerActivity
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
      snapshot.apps[currentIndex].routeHealthContext = nil
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
    let result = await applyAppIntent(
      AppRouteIntent(
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
    let result = await applyAppIntent(
      AppRouteIntent(
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
    let result = await applyAppIntent(
      AppRouteIntent(
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
    let result = await applyAppIntent(
      AppRouteIntent(
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
    let routerActivity = verifiedRouterActivityProvider?()

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

      guard let appIndex = snapshot.apps.firstIndex(matchingAppKey: entry.appID) else {
        rows.append(
          ProfileRowApplyResult(
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
      let result = await applyAppIntent(
        AppRouteIntent(
          appID: entry.appID,
          desiredVolume: entry.desiredVolume ?? values.desiredVolume,
          isMuted: entry.isMuted ?? values.isMuted,
          volumeBoost: entry.volumeBoost ?? values.volumeBoost,
          equalizerSettings: values.equalizerSettings,
          targetDeviceUID: values.targetDeviceUID,
          generation: generation,
          reason: .profileApply
        ),
        routerActivity: routerActivity
      )
      rows.append(
        ProfileRowApplyResult(
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
        .filter {
          Self.isRouteRecoveryCandidate(
            $0,
            hasActiveController: controllers[$0.id]?.isActive == true,
            reclaimMixedOutput: !waveLinkCompatibilityEnabled
          )
        }
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

  static func isRouteRecoveryCandidate(
    _ app: AudioApp,
    hasActiveController: Bool,
    reclaimMixedOutput: Bool
  ) -> Bool {
    if app.routingState == .managed || hasActiveController { return true }
    guard app.routingState == .monitorOnly else { return false }
    switch app.routeHealthContext {
    case .verifiedRouterOwnership, .unattributableRouterFallback, .waveLinkBridge:
      return true
    case .routerMixedOutput:
      return reclaimMixedOutput
    case nil, .geometryRecoveryInProgress, .geometryRecoveryExhausted:
      return false
    }
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

  /// The last structured result of the Core Audio capture-capability probe.
  /// OS support, reliable denial, and ambiguous native probe failures remain
  /// distinct so diagnostics never mislabel an unknown failure as TCC denial.
  var captureAuthorization: CaptureAuthorizationResult = .undetermined

  struct IntentGenerationContext: Sendable {
    let logicalID: String
    let generation: UInt64
    let lifecycleEpoch: UInt64
  }

  struct IntentSupersededError: Error {}
  struct IntentBackendStoppedError: Error {}

  func ensureAcceptingOperations() throws {
    guard !isShuttingDown else {
      throw BackendError.managedRouteUnavailable("The audio backend is shutting down.")
    }
  }

  func isGenerationCurrent(_ context: IntentGenerationContext) -> Bool {
    context.lifecycleEpoch == lifecycleEpoch
      && latestAcceptedGenerationByLogicalID[context.logicalID] == context.generation
  }

  func ensureGenerationCurrent(_ context: IntentGenerationContext) throws {
    guard isStarted, !isShuttingDown else { throw IntentBackendStoppedError() }
    guard isGenerationCurrent(context) else { throw IntentSupersededError() }
  }

  func supersededResult(
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
      retainCleanupDegradations(disposeController(controller))
    }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
    staleRouteTicks.removeValue(forKey: runtimeID)
    lastRenderTickByAppID.removeValue(forKey: runtimeID)
    snapshot.apps[index].routingState = .monitorOnly
    snapshot.apps[index].appliedVolume = nil
    snapshot.apps[index].peakLevel = 0
    snapshot.apps[index].rmsLevel = 0
    snapshot.apps[index].hasNoAudioCapability = false
    snapshot.apps[index].notes = nil
    snapshot.apps[index].routeHealthContext = nil
  }

  private func disposeControllerInstalledByGeneration(
    runtimeID: String,
    generation: UInt64
  ) {
    guard controllerGenerationByRuntimeID[runtimeID] == generation else { return }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
    if let controller = controllers.removeValue(forKey: runtimeID) {
      retainCleanupDegradations(disposeController(controller))
    }
    staleRouteTicks.removeValue(forKey: runtimeID)
    lastRenderTickByAppID.removeValue(forKey: runtimeID)
  }

  struct IntentControlValues {
    let desiredVolume: Float
    let isMuted: Bool
    let volumeBoost: Float
    let equalizerSettings: EqualizerSettings
    let targetDeviceUID: String?
  }

  func intentControlValues(for app: AudioApp) -> IntentControlValues {
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

  func clearStagedIntentIfCurrent(
    _ intent: AppRouteIntent,
    logicalID: String
  ) {
    guard stagedIntentByLogicalID[logicalID] == intent else { return }
    stagedIntentByLogicalID.removeValue(forKey: logicalID)
  }

  func legacyApp(forAppID appID: String) throws -> AudioApp {
    guard let app = snapshot.apps.app(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }
    return app
  }

  func nextLegacyGeneration() -> UInt64 {
    let highestAccepted = latestAcceptedGenerationByLogicalID.values.max() ?? 0
    let base = max(legacyGeneration, highestAccepted)
    legacyGeneration = base == .max ? .max : base + 1
    return legacyGeneration
  }

  func validateLegacyApplyResult(_ result: AppIntentApplyResult) throws {
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
    generationContext: IntentGenerationContext? = nil,
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) async throws {
    try ensureAcceptingOperations()
    guard supportsPerAppRouting else {
      throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
    }
    if let conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity) {
      throw BackendError.unsupportedOperation(conflict.detail)
    }

    if let generationContext {
      try ensureGenerationCurrent(generationContext)
    }
    let processTarget = try resolveProcessTarget(for: app)
    let processObjectIDs = processTarget.processObjectIDs
    let targetProcessFamily = TargetProcessFamily(
      logicalID: app.logicalID,
      processObjectIDs: processObjectIDs,
      processLifetimeIdentities: processTarget.processLifetimeIdentities
    )
    let stagedEqualizer =
      equalizerSettings
      ?? equalizerSettingsByAppID[app.logicalID]
      ?? EqualizerSettings()

    // Reuse the live tap for parameter-only changes as long as it already covers
    // every process we'd tap now. A target-device change explicitly forces a new
    // controller, while volume/mute/boost/EQ changes stay on the current route.
    if !forceRebuild,
      let controller = controllers[app.id],
      controller.isActive,
      controller.covers(targetProcessFamily)
    {
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
      processTarget: processTarget,
      equalizerSettings: stagedEqualizer,
      generationContext: generationContext
    )

    do {
      try ensureAcceptingOperations()
      if let generationContext {
        try ensureGenerationCurrent(generationContext)
        if let installedGeneration = controllerGenerationByRuntimeID[app.id],
          installedGeneration > generationContext.generation
        {
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
        retainCleanupDegradations(disposeController(replacedController))
      }

      // A freshly-created process tap proves capture is currently authorized.
      captureAuthorization = .authorized
    } catch {
      retainCleanupDegradations(disposeController(controller))
      throw error
    }
  }

  private func createControllerWithRetry(
    for app: AudioApp,
    processTarget: ResolvedProcessTarget,
    equalizerSettings: EqualizerSettings,
    generationContext: IntentGenerationContext?
  ) async throws -> PerAppTapController {
    let maxRetries = 3
    var lastError: Error?
    var currentProcessTarget = processTarget

    for attempt in 1...maxRetries {
      try ensureAcceptingOperations()
      do {
        if let generationContext {
          try ensureGenerationCurrent(generationContext)
        }
        let controller = try createController(
          for: app,
          processTarget: currentProcessTarget,
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
          if let refreshedProcessTarget = try? resolveProcessTarget(for: app),
            refreshedProcessTarget != currentProcessTarget
          {
            logger.info("Process object IDs changed for \(app.displayName) during retry")
            currentProcessTarget = refreshedProcessTarget
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
    processTarget: ResolvedProcessTarget,
    equalizerSettings: EqualizerSettings
  ) throws -> PerAppTapController {
    try ensureAcceptingOperations()

    if let controllerFactory {
      try revalidateProcessTarget(processTarget, for: app)
      return try controllerFactory(
        app,
        processTarget.processObjectIDs,
        equalizerSettings,
        managedAudioEqualizerSettings,
        adaptiveGainDBByAppID[app.logicalID] ?? 0
      )
    }

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

      let tapDescription = CATapDescription(
        stereoMixdownOfProcesses: processTarget.processObjectIDs
      )
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
            observations.append(
              CleanupStatusObservation(
                appID: app.logicalID,
                stage: .aggregateDeviceDestroy,
                nativeStatus: AudioHardwareDestroyAggregateDevice(aggregateID),
                detail: "Destroy partially-created aggregate device"
              ))
          }
          if tapID != .unknown {
            observations.append(
              CleanupStatusObservation(
                appID: app.logicalID,
                stage: .processTapDestroy,
                nativeStatus: AudioHardwareDestroyProcessTap(tapID),
                detail: "Destroy partially-created process tap"
              ))
          }
          retainCleanupDegradations(checkedCleanupDegradations(from: observations))
        }
      }

      // Keep the authority check adjacent to native tap creation. A PID can be
      // recycled after discovery, and a Core Audio object can be rebound after
      // translation. Both live identities and object ownership must still match.
      try revalidateProcessTarget(processTarget, for: app)
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
        kAudioAggregateDeviceTapAutoStartKey: ProcessTapAggregatePolicy.autoStartEnabled,
        kAudioAggregateDeviceSubDeviceListKey: [
          [
            kAudioSubDeviceUIDKey: outputDeviceUID,
            kAudioSubDeviceDriftCompensationKey: false,
          ]
        ],
        kAudioAggregateDeviceTapListKey: [
          [
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapUIDKey: tapUID,
          ]
        ],
      ]

      try withStatusCheck(
        AudioHardwareCreateAggregateDevice(aggregateDeviceDescription as CFDictionary, &aggregateID),
        action: "create aggregate device"
      )

      let controller = try PerAppTapController(
        appID: app.id,
        appName: app.displayName,
        logicalID: app.logicalID,
        targetProcessObjectIDs: processTarget.processObjectIDs,
        targetProcessLifetimeIdentities: processTarget.processLifetimeIdentities,
        tapDescription: tapDescription,
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
        let cleanupDegradations = disposeController(controller)
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

  private func resolveProcessTarget(for app: AudioApp) throws -> ResolvedProcessTarget {
    if let processTargetResolver {
      return try processTargetResolver(app)
    }
    if let processObjectIDResolver {
      return .testing(processObjectIDs: try processObjectIDResolver(app))
    }
    guard let targetIdentity = app.runtimeIdentity,
      let targetPID = app.pid,
      targetIdentity.lifetime.pid == targetPID,
      runtimeIdentityProvider(targetPID) == targetIdentity
    else {
      throw BackendError.managedRouteUnavailable(
        "The live process identity for \(app.displayName) could not be verified."
      )
    }

    var candidatePIDs: Set<pid_t> = [targetPID]
    candidatePIDs.formUnion(
      NSWorkspace.shared.runningApplications.compactMap { runningApp -> pid_t? in
        guard let bundlePath = runningApp.bundleURL?.path,
          canonicalOuterBundlePath(forBundlePath: bundlePath) == targetIdentity.outerBundlePath
        else {
          return nil
        }
        return runningApp.processIdentifier
      })

    // Include audible helpers that do not appear in NSWorkspace, such as a
    // Chromium Audio Service. Executable containment is only a prefilter. The
    // signed runtime family check below remains the authority boundary.
    for pid in cachedAudibleProcesses().pids
    where
      executableForPID(pid, belongsToAppBundleAt: targetIdentity.outerBundlePath)
    {
      candidatePIDs.insert(pid)
    }

    var processByObjectID: [AudioObjectID: ResolvedProcessObject] = [:]
    for pid in candidatePIDs.sorted() {
      guard let candidateIdentity = runtimeIdentityProvider(pid),
        AppDiscoveryPolicy.runtimeFamilyMatches(
          target: targetIdentity,
          candidate: candidateIdentity
        ),
        let processObjectID = try? translateProcessObject(forPID: pid),
        processObjectID != .unknown
      else {
        continue
      }

      if let existing = processByObjectID[processObjectID],
        existing.runtimeIdentity != candidateIdentity
      {
        throw BackendError.managedRouteUnavailable(
          "Core Audio returned ambiguous process ownership for \(app.displayName)."
        )
      }
      processByObjectID[processObjectID] = ResolvedProcessObject(
        id: processObjectID,
        runtimeIdentity: candidateIdentity
      )
    }

    let resolvedProcesses = processByObjectID.values.sorted { $0.id < $1.id }
    if !resolvedProcesses.isEmpty {
      return ResolvedProcessTarget(
        targetRuntimeIdentity: targetIdentity,
        processes: resolvedProcesses,
        requiresLiveIdentityValidation: true
      )
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

  private func revalidateProcessTarget(
    _ processTarget: ResolvedProcessTarget,
    for app: AudioApp
  ) throws {
    guard processTarget.requiresLiveIdentityValidation else { return }
    guard let targetIdentity = app.runtimeIdentity,
      liveRuntimeIdentityProvider(targetIdentity.lifetime.pid) == targetIdentity
    else {
      throw BackendError.managedRouteUnavailable(
        "The live process identity for \(app.displayName) changed before route creation."
      )
    }

    for process in processTarget.processes {
      guard let storedIdentity = process.runtimeIdentity,
        liveRuntimeIdentityProvider(storedIdentity.lifetime.pid) == storedIdentity,
        AppDiscoveryPolicy.runtimeFamilyMatches(
          target: targetIdentity,
          candidate: storedIdentity
        ),
        let currentObjectID = try translateProcessObject(forPID: storedIdentity.lifetime.pid),
        currentObjectID == process.id
      else {
        throw BackendError.managedRouteUnavailable(
          "Core Audio process ownership for \(app.displayName) changed before route creation."
        )
      }
    }
  }

  private func canonicalOuterBundlePath(forBundlePath path: String) -> String? {
    guard let outerPath = AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: path) else {
      return nil
    }
    return URL(fileURLWithPath: outerPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
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
    let expectedUIDSize = UInt32(MemoryLayout<CFString?>.size)
    guard uidSize == expectedUIDSize else {
      throw BackendError.managedRouteUnavailable(
        "Process tap UID returned \(uidSize) bytes; expected \(expectedUIDSize)."
      )
    }

    var readSize = expectedUIDSize
    var rawUID: CFString?
    let uidStatus = withUnsafeMutablePointer(to: &rawUID) {
      AudioObjectGetPropertyData(tapID, &address, 0, nil, &readSize, $0)
    }
    try withStatusCheck(uidStatus, action: "read tap uid")
    guard readSize == expectedUIDSize else {
      throw BackendError.managedRouteUnavailable(
        "Process tap UID returned \(readSize) bytes; expected \(expectedUIDSize)."
      )
    }

    guard let rawUID else {
      throw BackendError.managedRouteUnavailable("No process tap UID returned.")
    }

    return rawUID as String
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
    let expectedSize = UInt32(MemoryLayout<AudioObjectID>.size)
    guard size == expectedSize else {
      throw BackendError.managedRouteUnavailable(
        "Translate pid \(pid) returned \(size) bytes; expected \(expectedSize)."
      )
    }

    return processObjectID == .unknown ? nil : processObjectID
  }

  private func translateProcessObject(forPID pid: pid_t) throws -> AudioObjectID? {
    if let processObjectTranslator {
      return try processObjectTranslator(pid)
    }
    return try translateProcessID(forPID: pid)
  }

  /// The set of processes currently producing audio output, indexed both by raw
  /// PID and by the path of the enclosing top-level `.app`. Using the actual
  /// bundle path prevents an unrelated app from claiming a trusted bundle ID.
  struct AudibleProcessIndex: Sendable {
    var pids: Set<pid_t> = []
    var parentBundlePaths: Set<String> = []
  }

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

  private func executablePath(forPID pid: pid_t) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't surfaced to Swift, so the
    // value is inlined. proc_pidpath never writes more than this.
    let maxPathSize = 4 * 1024
    var pathBuffer = [CChar](repeating: 0, count: maxPathSize)
    let length = proc_pidpath(pid, &pathBuffer, UInt32(maxPathSize))
    guard length > 0 else { return nil }
    let executablePath = pathBuffer.withUnsafeBufferPointer { buffer in
      buffer.baseAddress.map { String(cString: $0) } ?? ""
    }
    return executablePath
  }

  private func executableForPID(_ pid: pid_t, belongsToAppBundleAt bundlePath: String) -> Bool {
    guard let executablePath = executablePath(forPID: pid) else { return false }
    return AppDiscoveryPolicy.executablePath(executablePath, belongsToAppBundleAt: bundlePath)
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

    let elementSize = UInt32(MemoryLayout<AudioObjectID>.size)
    guard size % elementSize == 0 else {
      logger.warning("Ignoring malformed process object list byte size \(size); expected a multiple of \(elementSize).")
      return AudibleProcessIndex()
    }
    let processObjectCount = Int(size / elementSize)
    guard processObjectCount > 0 else {
      return AudibleProcessIndex()
    }

    let expectedSize = size
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
    guard size == expectedSize else {
      logger.warning("Ignoring process object list read that returned \(size) bytes; expected \(expectedSize).")
      return AudibleProcessIndex()
    }

    var index = AudibleProcessIndex()
    // Objects that vanish between the enumeration above and the reads below are
    // normal churn, not faults. Tally them and report one summary line for the
    // pass rather than a warning per object.
    var stale = StaleAudioObjectTally()
    for processObjectID in processObjectIDs where processObjectID != .unknown {
      guard isProcessRunningOutput(processObjectID, stale: &stale) else { continue }
      guard let pid = readProcessPID(processObjectID, stale: &stale) else { continue }
      index.pids.insert(pid)
      // Attribute helper/utility audio (browsers, Electron) to the parent app.
      if let executablePath = executablePath(forPID: pid),
        let parentBundlePath = AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: executablePath)
      {
        index.parentBundlePaths.insert(parentBundlePath)
      }
    }
    if !stale.isEmpty {
      logger.debug(
        "Skipped \(stale.count) audio process object(s) that exited during enumeration.")
    }

    return index
  }

  private func readProcessPID(
    _ processObjectID: AudioObjectID,
    stale: inout StaleAudioObjectTally
  ) -> pid_t? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var pid = pid_t()
    var size = UInt32(MemoryLayout<pid_t>.size)
    let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &pid)
    switch CoreAudioObjectReadOutcome(status) {
    case .ok:
      break
    case .objectDisappeared:
      // The process exited between enumeration and this read. Expected.
      stale.record(processObjectID)
      return nil
    case .failed(let status):
      logger.warning("Failed to read process pid for object \(processObjectID) (OSStatus: \(status))")
      return nil
    }
    guard size == UInt32(MemoryLayout<pid_t>.size) else {
      logger.warning("Ignoring process pid read for object \(processObjectID) that returned \(size) bytes.")
      return nil
    }

    return pid
  }

  private func isProcessRunningOutput(
    _ processObjectID: AudioObjectID,
    stale: inout StaleAudioObjectTally
  ) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningOutput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var isRunningOutput: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &size, &isRunningOutput)
    switch CoreAudioObjectReadOutcome(status) {
    case .ok:
      break
    case .objectDisappeared:
      // The process exited between enumeration and this read. Expected.
      stale.record(processObjectID)
      return false
    case .failed(let status):
      logger.warning("Failed to read process output state for object \(processObjectID) (OSStatus: \(status))")
      return false
    }
    guard size == UInt32(MemoryLayout<UInt32>.size) else {
      logger.warning("Ignoring process output state for object \(processObjectID) that returned \(size) bytes.")
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
    // Carry icons forward like every other preserved field. An app's icon does
    // not change while it runs, but this rebuild happens every 8 seconds — and
    // each one used to draw and PNG-encode the icon of every running app, then
    // throw the result away in the merge below, which already keeps the previous
    // app's data. That is dozens of image encodes a minute for nothing.
    let knownIcons = (previousSnapshot?.apps ?? []).reduce(into: [String: Data]()) { result, app in
      if let data = app.iconTIFFData { result[app.logicalID] = data }
    }
    let discoveryCapture = await AppRuntimeDiscovery.captureRunningApplications(
      currentBundleID: currentBundleID,
      knownIconData: knownIcons
    )
    let runningApps = await Task.detached { [currentBundleID, audible, discoveryCapture] in
      AppRuntimeDiscovery.discoverRunningApps(
        from: discoveryCapture,
        currentBundleID: currentBundleID,
        audiblePIDs: audible.pids,
        audibleParentBundlePaths: audible.parentBundlePaths
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
      app.routeHealthContext = previous.routeHealthContext
      if previous.routeHealthContext != nil {
        app.routingState = previous.routingState
        app.notes = previous.notes
      }
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
      guard AppRuntimeDiscovery.isStillRunning(previous, in: discoveryCapture, currentBundleID: currentBundleID) else { continue }

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

      if mergedApps[index].routeHealthContext != nil {
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
    let routeError =
      hasRouteErrors
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

  func releaseControllers(
    forRuntimeIdentity runtimeIdentity: AppRuntimeIdentity,
    clearMuteState: Bool = false
  ) async {
    guard !isShuttingDown else { return }
    let targetIDs = snapshot.apps.filter { app in
      app.runtimeIdentity == runtimeIdentity
    }.map(\.id)

    guard !targetIDs.isEmpty else { return }

    for id in targetIDs {
      if let controller = controllers.removeValue(forKey: id) {
        retainCleanupDegradations(disposeController(controller))
      }
      controllerGenerationByRuntimeID.removeValue(forKey: id)
      staleRouteTicks.removeValue(forKey: id)
      lastRenderTickByAppID.removeValue(forKey: id)
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
        degradations.append(contentsOf: disposeController(controller))
      }
      controllerGenerationByRuntimeID.removeValue(forKey: appID)
      staleRouteTicks.removeValue(forKey: appID)
      lastRenderTickByAppID.removeValue(forKey: appID)
    }
    return degradations
  }

  /// - Parameter knownIconData: icons already encoded on a previous pass, keyed
  ///   by logical ID. Reused rather than re-encoded; an app's icon is fixed for
  ///   as long as it runs.

  private func dictionaryByLogicalID(_ apps: [AudioApp]) -> [String: AudioApp] {
    apps.reduce(into: [:]) { result, app in
      result[app.logicalID] = app
    }
  }

  func withStatusCheck(_ status: OSStatus, action: String) throws {
    if status != noErr {
      throw BackendError.managedRouteUnavailable("\(action) failed (OSStatus: \(status)).")
    }
  }

  func retainCleanupStatus(
    _ status: OSStatus,
    appID: String? = nil,
    stage: CleanupStage,
    detail: String
  ) {
    retainCleanupDegradations(
      checkedCleanupDegradations(from: [
        CleanupStatusObservation(
          appID: appID,
          stage: stage,
          nativeStatus: status,
          detail: detail
        )
      ]))
  }

  /// Records cleanup failures for diagnostics, bounded in both size and noise.
  ///
  /// A route that fails the same teardown stage on every maintenance pass used
  /// to append a row and emit a log line every time, for the life of the
  /// process — an unbounded array and an unbounded log for one stuck condition.
  /// Keeping the first rows preserves the original failure (usually the
  /// informative one) while a counter records what came after.
  func retainCleanupDegradations(_ degradations: [CleanupDegradation]) {
    guard !degradations.isEmpty else { return }
    for degradation in degradations {
      if retainedCleanupDegradations.count < Self.maxRetainedCleanupDegradations {
        retainedCleanupDegradations.append(degradation)
      } else {
        droppedCleanupDegradations += 1
      }
    }
    logCleanupDegradations(degradations)
  }

  /// Disposes a controller and, if the native teardown failed, keeps it for
  /// another attempt.
  ///
  /// A failed teardown is not cosmetic: the process tap is created with
  /// `.mutedWhenTapped`, so while it exists but nothing renders it, the target
  /// app is *silent*. Before this, the controller was dropped on the floor
  /// regardless of outcome and `IdempotentCleanupResult` memoized the failure,
  /// so nothing would ever try again — the app stayed muted for the rest of the
  /// session with no signal to the user.
  func disposeController(_ controller: PerAppTapController) -> [CleanupDegradation] {
    let degradations = controller.dispose()
    guard !degradations.isEmpty else { return degradations }
    orphanedControllers.append(controller)
    return degradations
  }

  /// Retries parked teardowns, dropping each one once it succeeds or has had
  /// enough attempts. Driven from the existing route-maintenance tick, so it
  /// costs nothing when there is nothing parked.
  private func retryOrphanedControllerDisposals() {
    guard !orphanedControllers.isEmpty else { return }
    var stillOrphaned: [PerAppTapController] = []
    for controller in orphanedControllers {
      let controllerID = ObjectIdentifier(controller)
      // A controller whose native IO proc never relinquished its callback must
      // remain alive for the lifetime of this backend. Dropping it after the
      // retry budget would free callback state that Core Audio may still use.
      if (orphanDisposeAttempts[controllerID] ?? 0) >= Self.maxOrphanDisposeRetries {
        stillOrphaned.append(controller)
        continue
      }
      let degradations = controller.retryDispose()
      if degradations.isEmpty {
        // Released at last — drop its attempt count too, so a later controller
        // that happens to reuse this appID starts from a full retry budget.
        orphanDisposeAttempts.removeValue(forKey: controllerID)
        continue
      }
      let attempts = (orphanDisposeAttempts[controllerID] ?? 0) + 1
      orphanDisposeAttempts[controllerID] = attempts
      if attempts >= Self.maxOrphanDisposeRetries {
        retainCleanupDegradations([
          CleanupDegradation(
            appID: controller.appID,
            stage: .controllerDisposal,
            detail:
              "Native audio resources still had not released after \(attempts) attempts. Waves retained the controller to keep callbacks safe and original audio fail-open until restart."
          )
        ])
        stillOrphaned.append(controller)
        continue
      }
      stillOrphaned.append(controller)
    }
    orphanedControllers = stillOrphaned
  }

  /// Logs the first occurrence of each (stage, app) pair, then stays quiet:
  /// repetition adds no information and buries everything else. A route stuck
  /// failing the same teardown every maintenance pass used to log forever.
  private func logCleanupDegradations(_ degradations: [CleanupDegradation]) {
    for degradation in degradations {
      let key = CleanupLogKey(stage: degradation.stage, appID: degradation.appID)
      let seen = (cleanupDegradationLogCounts[key] ?? 0) + 1
      cleanupDegradationLogCounts[key] = seen
      guard seen == 1 else { continue }
      logger.error(
        "Cleanup degraded at \(degradation.stage.name, privacy: .public) for \(degradation.appID ?? "backend", privacy: .public): OSStatus \(degradation.nativeStatus ?? 0, privacy: .public). \(degradation.detail ?? "No detail.", privacy: .public)"
      )
    }
  }

  /// Recompute global route readiness from authorization, the confirmed current
  /// output device, and every app route. A successful app apply cannot erase an
  /// authorization/device query failure or another app's route error.
  func refreshGlobalRouteHealth(latestError: String? = nil) {
    let hasRouteErrors = hasBlockingRouteErrors(in: snapshot.apps)
    let deviceIsReady = snapshot.currentDevice != nil
    snapshot.backendStatus.hasRequiredPermissions = captureAuthorization == .authorized
    snapshot.backendStatus.isRouteRecoveryHealthy =
      supportsPerAppRouting
      && captureAuthorization == .authorized
      && deviceIsReady
      && !hasRouteErrors
      && routerObservationListenerFailureDetail == nil

    let routeError =
      hasRouteErrors
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
    if let routerObservationListenerFailureDetail {
      details.append(routerObservationListenerFailureDetail)
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
  func hasBlockingRouteErrors(in apps: [AudioApp]) -> Bool {
    apps.contains { $0.routingState == .error && !$0.hasNoAudioCapability }
  }

  /// Records route failures. A missing active stream on a normal app is kept as
  /// monitor-only because it is a retryable precondition, not a broken route.
  /// True route failures become `.error`; permanent non-audio rows also record
  /// `hasNoAudioCapability` so UI can suggest exclusion.
  func markRouteError(at index: Int, error: Error) {
    if case BackendError.noActiveAudioStream = error {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.apps[index].hasNoAudioCapability = false
      snapshot.apps[index].routeHealthContext = nil
      return
    }

    snapshot.apps[index].routingState = .error
    snapshot.apps[index].notes = error.localizedDescription
    snapshot.apps[index].routeHealthContext = nil
    if case BackendError.noAudioCapability = error {
      snapshot.apps[index].hasNoAudioCapability = true
    } else {
      snapshot.apps[index].hasNoAudioCapability = false
    }
  }

  func reattachRoutes(forLogicalIDs logicalIDs: Set<String>) async {
    guard !isShuttingDown else { return }
    // A reattach is one coherent setup pass. Capture router activity before
    // any await so every route sees the same verified Security/Core Audio view.
    let routerActivity = verifiedRouterActivityProvider?()
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

      if let conflict = competingAudioRouterConflict(
        for: app,
        routerActivity: routerActivity
      ) {
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          suspendManagedRouteForConflict(at: index, conflict: conflict)
        }
        continue
      }

      do {
        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted,
          routerActivity: routerActivity
        )
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == logicalID }) {
          snapshot.apps[index].routingState = .managed
          snapshot.apps[index].appliedVolume =
            snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
          snapshot.apps[index].notes = nil
          snapshot.apps[index].routeHealthContext = nil
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
        try? await Task.sleep(nanoseconds: 250_000_000)  // 0.25 seconds (optimized from 0.1s)
        await self?.updateAudioLevels()
      }
    }
  }

  private func stopLevelUpdateTask() {
    levelUpdateTask?.cancel()
    levelUpdateTask = nil
  }

  private func updateAudioLevels() async {
    await updateAudioLevels(at: monotonicRouteTime())
  }

  func updateAudioLevels(at now: Duration) async {
    guard !isShuttingDown else { return }
    if routerObservationListeners.consumeFallbackReobservationTick() {
      retainCleanupDegradations(addRouterObservationListeners())
      markRouterObservationDirty()
    }
    // Most of the app's lifetime has no managed renderers. Avoid rescanning the
    // entire app snapshot four times per second when there is nothing a router
    // conflict could suspend.
    let routerActivity = verifiedRouterActivityProvider?()
    let routerReleasedRouteIDs = observeCompetingRouterConflicts(
      at: now,
      routerActivity: routerActivity
    )
    // With no controllers left there are no levels to read — but there may still
    // be a parked teardown to retry, and that is exactly the case where one
    // exists: disposing the last controller removes it from `controllers` before
    // dispose() runs, so a failure there leaves an orphan with nothing to drive
    // its retry. A stranded tap is created `.mutedWhenTapped`, so the app it
    // targets stays silent until Waves restarts.
    guard !controllers.isEmpty else {
      routeMaintenanceTick += 1
      if routeMaintenanceTick >= routeMaintenanceTickInterval || !routerReleasedRouteIDs.isEmpty {
        routeMaintenanceTick = 0
        retryOrphanedControllerDisposals()
        await performRouteMaintenance(
          forceRebuildIDs: routerReleasedRouteIDs,
          routerActivity: routerActivity
        )
      }
      return
    }

    let appIndexMap = snapshot.apps.enumerated().reduce(into: [String: Int]()) { result, pair in
      result[pair.element.logicalID] = pair.offset
    }

    var routeIDsNeedingRebuild = Set<String>()
    var geometryRecoveryRouteIDs = Set<String>()

    for (appID, controller) in controllers {
      if controller.consumeGeometryMismatch() {
        var recovery = geometryRecoveryByRuntimeID[appID] ?? GeometryRecoveryCoordinator()
        _ = recovery.signalMismatch(at: now)
        geometryRecoveryByRuntimeID[appID] = recovery
        if let index = appIndexMap[appID] ?? snapshot.apps.firstIndex(where: { $0.id == appID }) {
          snapshot.apps[index].routeHealthContext = .geometryRecoveryInProgress
          snapshot.apps[index].notes = "Audio geometry changed. Waves is rebuilding this route asynchronously."
          snapshot.updatedAt = .now
        }
      }
      if var recovery = geometryRecoveryByRuntimeID[appID],
        case .attempt = recovery.beginRecovery(at: now)
      {
        geometryRecoveryByRuntimeID[appID] = recovery
        routeIDsNeedingRebuild.insert(appID)
        geometryRecoveryRouteIDs.insert(appID)
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

        // A controller's target objects disappear whenever the source app quits,
        // which is exactly when this check runs — so the tally absorbs those
        // instead of logging a warning per dead object per poll.
        var stale = StaleAudioObjectTally()
        let sourceIsRunningOutput = controller.targetProcessObjectIDs.contains {
          processObjectLivenessProvider?($0) ?? isProcessRunningOutput($0, stale: &stale)
        }
        // Liveness comes from the IO proc actually running, never from signal
        // level. Judging a route dead because it went quiet meant that any app
        // holding output IO open while emitting digital silence — a call with
        // nobody talking, a stream between cues, a paused game — got its process
        // tap and aggregate device torn down and rebuilt every 6 seconds,
        // forever, with an audible dropout each time and two device-change
        // notifications feeding back into route maintenance.
        let renderTick = controller.currentRenderTick()
        let isRendering = RouteLivenessJudgment.isRendering(
          currentTick: renderTick,
          previousTick: lastRenderTickByAppID[app.logicalID]
        )
        lastRenderTickByAppID[app.logicalID] = renderTick

        if app.routingState == .managed,
          !app.isMuted,
          !isVolumeZero,
          sourceIsRunningOutput,
          !isRendering
        {
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
    routeIDsNeedingRebuild.formUnion(routerReleasedRouteIDs)
    if routeMaintenanceTick >= routeMaintenanceTickInterval || !routeIDsNeedingRebuild.isEmpty {
      routeMaintenanceTick = 0
      // A tap left behind by a failed teardown keeps its app muted, so keep
      // trying to release it rather than leaving the app silent for the session.
      retryOrphanedControllerDisposals()
      await performRouteMaintenance(
        forceRebuildIDs: routeIDsNeedingRebuild,
        geometryRecoveryIDs: geometryRecoveryRouteIDs,
        routerActivity: routerActivity
      )
    }
  }

  private func addRouterObservationListeners() -> [CleanupDegradation] {
    guard !isShuttingDown else { return [] }
    let degradations = routerObservationListeners.install { [weak self] in
      Task { [weak self] in await self?.markRouterObservationDirty() }
    }
    if degradations.isEmpty, !routerObservationListeners.requiresFallbackReobservation {
      routerObservationListenerFailureDetail = nil
    } else if let degradation = degradations.first {
      routerObservationListenerFailureDetail =
        "Waves could not attach a router observation listener (OSStatus: \(degradation.nativeStatus ?? -1)). Re-observing every second until listeners attach."
    }
    refreshGlobalRouteHealth()
    return degradations
  }

  private func removeRouterObservationListeners() -> [CleanupDegradation] {
    routerObservationListeners.remove()
  }

  private func performRouteMaintenance(
    forceRebuildIDs: Set<String> = [],
    geometryRecoveryIDs: Set<String> = [],
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) async {
    if let routeMaintenanceOverride {
      await routeMaintenanceOverride(forceRebuildIDs, geometryRecoveryIDs)
      return
    }
    await maintainManagedRoutes(
      forceRebuildIDs: forceRebuildIDs,
      geometryRecoveryIDs: geometryRecoveryIDs,
      routerActivity: routerActivity
    )
  }

  func markRouterObservationDirty() {
    routerObservationGeneration &+= 1
  }

  private func maintainManagedRoutes(
    forceRebuildIDs: Set<String> = [],
    geometryRecoveryIDs: Set<String> = [],
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) async {
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
        let processTarget = try resolveProcessTarget(for: app)
        let processObjectIDs = processTarget.processObjectIDs
        if !shouldForceRebuild,
          let controller = controllers[app.id],
          controller.isActive,
          controller.covers(
            TargetProcessFamily(
              logicalID: app.logicalID,
              processObjectIDs: processObjectIDs,
              processLifetimeIdentities: processTarget.processLifetimeIdentities
            )
          )
        {
          continue
        }

        try await applyRoute(
          for: app,
          toVolume: app.desiredVolume,
          muted: app.isMuted,
          forceRebuild: shouldForceRebuild,
          routerActivity: routerActivity
        )

        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
          snapshot.apps[currentIndex].routingState = .managed
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
          snapshot.apps[currentIndex].notes = nil
          snapshot.apps[currentIndex].routeHealthContext = nil
        }
        staleRouteTicks.removeValue(forKey: app.logicalID)
        lastRenderTickByAppID.removeValue(forKey: app.logicalID)
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          _ = recovery.finishRecovery(succeeded: true, at: monotonicRouteTime())
          geometryRecoveryByRuntimeID[app.id] = recovery
        }
        changed = true
      } catch {
        if geometryRecoveryIDs.contains(appID) || geometryRecoveryIDs.contains(app.id),
          var recovery = geometryRecoveryByRuntimeID[app.id]
        {
          let action = recovery.finishRecovery(succeeded: false, at: monotonicRouteTime())
          geometryRecoveryByRuntimeID[app.id] = recovery
          if case .exhausted = action {
            let exhaustion = BackendError.managedRouteUnavailable(
              "Audio route recovery failed after 3 attempts. Refresh the route or restart Waves."
            )
            if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
              markRouteError(at: currentIndex, error: exhaustion)
              snapshot.apps[currentIndex].routeHealthContext = .geometryRecoveryExhausted
            }
            lastError = exhaustion.localizedDescription
            changed = true
            continue
          }
        }
        if let currentIndex = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
          markRouteError(at: currentIndex, error: error)
          snapshot.apps[currentIndex].appliedVolume =
            snapshot.apps[currentIndex].isMuted ? 0 : snapshot.apps[currentIndex].desiredVolume
        }
        staleRouteTicks.removeValue(forKey: app.logicalID)
        lastRenderTickByAppID.removeValue(forKey: app.logicalID)
        lastError = error.localizedDescription
        changed = true
      }
    }

    if changed {
      refreshGlobalRouteHealth(latestError: lastError)
      snapshot.updatedAt = .now
    }
  }

  private func monotonicRouteTime() -> Duration {
    .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
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
