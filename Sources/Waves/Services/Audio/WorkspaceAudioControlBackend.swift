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
  var retainedCleanupDegradations: [CleanupDegradation] = []
  /// How many rows were discarded once the buffer filled, so a bounded report
  /// never reads as a complete one.
  var droppedCleanupDegradations = 0
  var cleanupDegradationLogCounts: [CleanupLogKey: Int] = [:]
  /// Comfortably above `DiagnosticsExportFormatter.maximumCleanupRows`, so the
  /// export's own bound stays the one that shapes the report.
  static let maxRetainedCleanupDegradations = 64

  struct CleanupLogKey: Hashable {
    let stage: CleanupStage
    let appID: String?
  }
  var levelUpdateTask: Task<Void, Never>?
  var routeMaintenanceTick = 0
  var geometryRecoveryByRuntimeID: [String: GeometryRecoveryCoordinator] = [:]
  var routerConflictObservationByRuntimeID: [String: RouterConflictObservationDebouncer] = [:]
  var routerObservationListenerFailureDetail: String?
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
  var orphanedControllers: [PerAppTapController] = []
  var orphanDisposeAttempts: [ObjectIdentifier: Int] = [:]
  static let maxOrphanDisposeRetries = 5
  let routeMaintenanceTickInterval = 20
  let staleRouteThresholdTicks = 24
  var deviceChangeListenerSelectors: [AudioObjectPropertySelector] = []
  var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
  /// Device-change passes never overlap: a second event that arrives while a
  /// pass is rebuilding routes is folded into one follow-up pass instead.
  var isHandlingDeviceChange = false
  var pendingDeviceChangeSelectors: [AudioObjectPropertySelector]?
  /// The device UIDs outside Waves's own private aggregates at the last
  /// inventory pass, so events raised by Waves's own aggregate create/destroy
  /// can be told apart from real hardware changes.
  var lastKnownExternalDeviceUIDs: Set<String>?
  let routerObservationListeners: RouterObservationListenerLifecycle
  var defaultOutputDeviceChange = DefaultOutputDeviceChange()
  var outputDeviceReadinessError: String?
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
  let routeMaintenanceOverride: RouteMaintenanceOverride?
  let verifiedRouterConflictProvider: VerifiedRouterConflictProvider?
  let verifiedRouterActivityProvider: VerifiedRouterActivityProvider?
  /// Short-lived cache of the audible-process scan. A volume drag fires many
  /// throttled applies in quick succession; without this each one would re-walk
  /// the full Core Audio process-object list. 300ms is well under human notice
  /// for "a new app just started playing", and stale data only ever delays
  /// folding a brand-new helper into a tap by one tick.
  var audibleCache: (index: AudibleProcessIndex, at: Date)?
  let audibleCacheTTL: TimeInterval = 0.3

  var perAppAudioController: PerAppAudioController
  var waveLinkCompatibilityEnabled: Bool
  let waveLinkController: (any WaveLinkControlling)?
  /// Tail of the strictly serialized queue of in-flight bridge applies.
  var waveLinkApplyQueueTail: Task<Void, Never>?
  private let controllerFactory: ControllerFactory?
  let processObjectIDResolver: ProcessObjectIDResolver?
  let processTargetResolver: ProcessTargetResolver?
  let processObjectLivenessProvider: ProcessObjectLivenessProvider?
  let runtimeIdentityProvider: RuntimeIdentityProvider
  let liveRuntimeIdentityProvider: RuntimeIdentityProvider
  let processObjectTranslator: ProcessObjectTranslator?
  let captureAuthorizationProbe: CaptureAuthorizationProbe?
  let applicationCaptureProvider: (@Sendable () async -> AppRuntimeDiscovery.Capture)?
  let processLifetimeLiveness: @Sendable (AppProcessLifetimeIdentity) -> Bool

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
    self.applicationCaptureProvider = nil
    self.processLifetimeLiveness = RuntimeProcessIdentity.mayStillBeRunning
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
    captureAuthorizationProbe: CaptureAuthorizationProbe? = nil,
    applicationCaptureProvider: (@Sendable () async -> AppRuntimeDiscovery.Capture)? = nil,
    processLifetimeLiveness: @escaping @Sendable (AppProcessLifetimeIdentity) -> Bool = RuntimeProcessIdentity.mayStillBeRunning
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
    self.applicationCaptureProvider = applicationCaptureProvider
    self.processLifetimeLiveness = processLifetimeLiveness
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
        resultingApp: snapshot.apps.app(preferringLogicalID: intent.appID),
        backendStatus: snapshot.backendStatus,
        detail: "The audio backend is shutting down."
      )
    }
    guard let initialIndex = snapshot.apps.firstIndex(preferringLogicalID: intent.appID) else {
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

    // Exclusion is the user's explicit capture opt-out. Discovery and URL
    // commands cannot create it, and a collision must not prevent that opt-out.
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

    if snapshot.apps[acceptedIndex].hasAmbiguousIdentity {
      clearStagedIntentIfCurrent(intent, logicalID: logicalID)
      return AppIntentApplyResult(
        appID: intent.appID,
        generation: intent.generation,
        outcome: .unsupported,
        resultingApp: snapshot.apps[acceptedIndex],
        backendStatus: snapshot.backendStatus,
        detail: AppRuntimeDiscovery.identityCollisionNote
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
            resultingApp: snapshot.apps.app(preferringLogicalID: entry.appID),
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

      guard let appIndex = snapshot.apps.firstIndex(preferringLogicalID: entry.appID) else {
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
    // An explicit repair is the one place a fresh authorization verdict is
    // worth a system-wide probe tap; the periodic refresh trusts the cache.
    refreshCaptureAuthorization(force: true)
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
    // Only routes that follow the system default were built on the device
    // that just changed. A route pinned to its own output device keeps its
    // live tap: rebuilding it would interrupt audio on a device that did not
    // move, and a pinned device that disappeared is handled by the inventory
    // reconciliation instead.
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter {
          $0.targetDeviceUID == nil
            && ($0.routingState == .managed || controllers[$0.id]?.isActive == true)
        }
        .map(\.logicalID)
    )
    let pinnedRuntimeIDs = Set(snapshot.apps.filter { $0.targetDeviceUID != nil }.map(\.id))

    retainCleanupDegradations(disposeControllers(keeping: pinnedRuntimeIDs))
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
    guard let app = snapshot.apps.app(preferringLogicalID: appID) else {
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

  func applyRoute(
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
      // The aggregate will carry this device's input streams ahead of the
      // tap's (a headset's microphone, an interface's inputs). The controller
      // needs the count to enable only the tap's streams for its IO proc.
      let subDeviceInputStreamCount = inputStreamCount(forDeviceUID: outputDeviceUID)
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
        audioFormatPlan: audioFormatPlan,
        subDeviceInputStreamCount: subDeviceInputStreamCount
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
    let discoveryCapture: AppRuntimeDiscovery.Capture
    if let applicationCaptureProvider {
      discoveryCapture = await applicationCaptureProvider()
    } else {
      discoveryCapture = await AppRuntimeDiscovery.captureRunningApplications(
        currentBundleID: currentBundleID,
        knownIconData: knownIcons
      )
    }
    let incumbentIdentities = (previousSnapshot?.apps ?? []).reduce(into: [String: AppRuntimeIdentity]()) { result, app in
      result[app.logicalID] = app.runtimeIdentity
    }
    let runningApps = await Task.detached { [currentBundleID, audible, discoveryCapture, incumbentIdentities] in
      AppRuntimeDiscovery.discoverRunningApps(
        from: discoveryCapture,
        currentBundleID: currentBundleID,
        audiblePIDs: audible.pids,
        audibleParentBundlePaths: audible.parentBundlePaths,
        incumbentIdentities: incumbentIdentities
      )
    }.value
    guard !isShuttingDown else { return snapshot }
    let previousByLogicalID = dictionaryByLogicalID(previousSnapshot?.apps ?? [])
    let now = Date()

    var mergedApps = runningApps.map { candidate -> AudioApp in
      guard let previous = previousByLogicalID[candidate.logicalID] else {
        return candidate
      }

      let liveController = controllers[previous.id].flatMap { $0.isActive ? $0 : nil }
      let conflictsWithLiveOwner: Bool
      if let liveController, let owner = previous.runtimeIdentity {
        let sameFamily =
          candidate.runtimeIdentity.map {
            AppDiscoveryPolicy.runtimeFamilyMatches(target: owner, candidate: $0)
          } ?? false
        var ownerLifetimes = liveController.targetProcessFamily.processLifetimeIdentities
        ownerLifetimes.insert(owner.lifetime)
        conflictsWithLiveOwner = !sameFamily && ownerLifetimes.contains(where: processLifetimeLiveness)
      } else {
        conflictsWithLiveOwner = false
      }
      if liveController != nil && (candidate.hasAmbiguousIdentity || conflictsWithLiveOwner) {
        var retained = previous
        retained.hasAmbiguousIdentity = true
        retained.routingState = .error
        retained.notes = AppRuntimeDiscovery.identityCollisionNote
        retained.routeHealthContext = nil
        return retained
      }

      var app = candidate
      app.desiredVolume = previous.desiredVolume
      app.appliedVolume = candidate.hasAmbiguousIdentity ? nil : previous.appliedVolume ?? previous.desiredVolume
      app.isMuted = previous.isMuted
      app.isPinned = previous.isPinned
      app.compatibility = previous.compatibility
      app.volumeBoost = previous.volumeBoost
      app.muteSource = previous.muteSource
      app.targetDeviceUID = previous.targetDeviceUID
      app.routeHealthContext = candidate.hasAmbiguousIdentity ? nil : previous.routeHealthContext
      if app.routeHealthContext != nil {
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
      if previous.routingState == .error && !previous.hasAmbiguousIdentity
        && !candidate.hasAmbiguousIdentity && candidate.routingState != .live
      {
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
      if mergedApps[index].hasAmbiguousIdentity { continue }
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
}

// Unlike the store's `matchingAppKey` lookup, these prefer a logical-ID match
// over a runtime-ID match when both exist, so intents follow the logical app.
private extension Array where Element == AudioApp {
  func firstIndex(preferringLogicalID appKey: String) -> Index? {
    firstIndex { $0.logicalID == appKey } ?? firstIndex { $0.id == appKey }
  }

  func app(preferringLogicalID appKey: String) -> AudioApp? {
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
