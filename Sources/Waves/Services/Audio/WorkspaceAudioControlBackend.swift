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
  var equalizerSettingsByAppID: [String: EqualizerSettings] = [:]
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
  /// What `handBackEveryApp` did, once it has run: the controllers it handed
  /// back, for teardown, and what failed.
  private var shutdownHandBack: (handedBack: [PerAppTapController], degradations: [CleanupDegradation])?
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
  var routeRebuildBudget = RouteRebuildBudget()
  /// The output device and format each live route was built for.
  var routeOutputBindingByRuntimeID: [String: RouteOutputBinding] = [:]
  var devicesSeenNotAlive: Set<String> = []
  let deviceFormatListeners: DeviceFormatListenerLifecycle
  var wakeObserver: WakeObserverToken?
  let routeBudgetClock: @Sendable () -> Duration
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
  /// Parked controllers: silent for good, their native teardown not yet
  /// finished. See `retryParkedControllers`.
  var orphanedControllers: [PerAppTapController] = []
  /// Runtime IDs of apps a parked tap holds silent: they have no live route,
  /// and the tap's mute would not release on the last pass.
  var appsHeldSilentByParkedTaps: Set<String> = []
  /// Routes released fail open after an automatic repair failed or was
  /// refused, by logical ID. See `FailOpenRelease`.
  var failOpenReleases: [String: FailOpenRelease] = [:]
  /// Installed routes a managed release could not hand back, by runtime ID.
  /// Each still plays its app at the user's level; see `UnreleasedRoute`.
  var unreleasedRoutes: [String: UnreleasedRoute] = [:]
  /// Why a live route still needs rebuilding, by runtime ID, kept until a
  /// rebuild for it succeeds or the route changes hands. See
  /// `PendingRouteRepair`.
  var pendingRouteRepairs: [String: PendingRouteRepair] = [:]
  /// Logical IDs the user excluded, by their newest intent. Waves's capture
  /// authority, kept apart from a row's routing state, error and notes,
  /// which repairs and holds rewrite: no route is built for an app in it
  /// until an intent that does not exclude it (`applyRoute`).
  var excludedLogicalIDs: Set<String> = []
  /// Controllers whose release failed at quit, kept playing their apps
  /// until Waves exits; macOS removes their taps and aggregates with it.
  var controllersPlayingUntilExit: [PerAppTapController] = []
  let routeMaintenanceTickInterval = 20
  let staleRouteThresholdTicks = 24
  var deviceChangeListenerSelectors: [AudioObjectPropertySelector] = []
  var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
  let deviceChangeMailbox = AudioPropertyChangeMailbox()
  var deviceChangeTask: Task<Void, Never>?
  let routerObservationMailbox = AudioPropertyChangeMailbox()
  var routerObservationTask: Task<Void, Never>?
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
  /// Waits between controller-creation retries. Tests replace it with a gate so
  /// newer work can be interleaved deterministically while a repair is paused.
  typealias ControllerRetryPause = @Sendable (_ nanoseconds: UInt64) async throws -> Void
  /// One poll interval while a handoff waits for the outgoing renderer's mute
  /// fade. Tests replace it with one simulated render callback.
  typealias HandoffSilencePause = @Sendable () -> Void
  /// About 40 ms at the default 1 ms pause: one or two IO cycles at any
  /// common buffer size. See `PerAppTapController.silenceForHandoff`.
  static let handoffSilenceMaxPolls = 40
  /// The one deadline shutdown gives every controller's callback queue
  /// while it hands the apps back, well inside the app's 250 ms
  /// termination timeout. See `performCheckedShutdown`.
  static let shutdownHandBackWaitLimit: DispatchTimeInterval = .milliseconds(60)
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
  let controllerRetryPause: ControllerRetryPause
  let handoffSilencePause: HandoffSilencePause
  let outputDeviceUIDProvider: (@Sendable (AudioApp) -> String?)?
  /// Output devices by object ID, replacing the Core Audio device list in tests.
  let deviceInventoryProvider: (@Sendable () -> [AudioObjectID: String])?
  let deviceFormatObservationProvider: (@Sendable (String) -> DeviceFormatObservation)?
  /// Which processes are producing output, replacing the Core Audio scan in
  /// tests of the discovery merge.
  let audibleProcessIndexProvider: (@Sendable () -> AudibleProcessIndex)?

  nonisolated let deviceChangeEvents: AsyncStream<Void>
  nonisolated let deviceChangeContinuation: AsyncStream<Void>.Continuation

  init(
    verifiedRouterConflictProvider: VerifiedRouterConflictProvider? = nil,
    verifiedRouterActivityProvider: VerifiedRouterActivityProvider? = nil,
    perAppAudioController: PerAppAudioController = .waves,
    waveLinkCompatibilityEnabled: Bool = true
  ) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
    self.routeBudgetClock = Self.monotonicRouteTime
    self.controllerRetryPause = { try await Task.sleep(nanoseconds: $0) }
    self.handoffSilencePause = { usleep(1_000) }
    self.outputDeviceUIDProvider = nil
    self.deviceInventoryProvider = nil
    self.deviceFormatObservationProvider = nil
    self.audibleProcessIndexProvider = nil
    self.deviceFormatListeners = DeviceFormatListenerLifecycle(
      nativeCalls: .live(on: DispatchQueue(label: "com.waves.backend.device-format"))
    )
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
    processLifetimeLiveness: @escaping @Sendable (AppProcessLifetimeIdentity) -> Bool = RuntimeProcessIdentity.mayStillBeRunning,
    routeBudgetClock: (@Sendable () -> Duration)? = nil,
    controllerRetryPause: ControllerRetryPause? = nil,
    handoffSilencePause: HandoffSilencePause? = nil,
    outputDeviceUIDProvider: (@Sendable (AudioApp) -> String?)? = nil,
    deviceInventoryProvider: (@Sendable () -> [AudioObjectID: String])? = nil,
    deviceFormatObservationProvider: (@Sendable (String) -> DeviceFormatObservation)? = nil,
    audibleProcessIndexProvider: (@Sendable () -> AudibleProcessIndex)? = nil,
    deviceFormatListenerNativeCalls: DeviceFormatListenerNativeCalls? = nil
  ) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
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
    self.routeBudgetClock = routeBudgetClock ?? Self.monotonicRouteTime
    self.controllerRetryPause = controllerRetryPause ?? { try await Task.sleep(nanoseconds: $0) }
    self.handoffSilencePause = handoffSilencePause ?? { usleep(1_000) }
    self.outputDeviceUIDProvider = outputDeviceUIDProvider
    self.deviceInventoryProvider = deviceInventoryProvider
    self.deviceFormatObservationProvider = deviceFormatObservationProvider
    self.audibleProcessIndexProvider = audibleProcessIndexProvider
    self.deviceFormatListeners = DeviceFormatListenerLifecycle(
      nativeCalls: deviceFormatListenerNativeCalls
        ?? .live(on: DispatchQueue(label: "com.waves.backend.device-format"))
    )
    self.routerObservationListeners = RouterObservationListenerLifecycle(
      nativeCalls: routerObservationNativeCalls
        ?? .live(on: DispatchQueue(label: "com.waves.backend.router-observation"))
    )
    self.controllers = Dictionary(uniqueKeysWithValues: testingControllers.map { ($0.appID, $0) })
    self.isStarted = true
  }

  deinit {
    deviceChangeMailbox.finish()
    routerObservationMailbox.finish()
    deviceChangeTask?.cancel()
    routerObservationTask?.cancel()
  }

  func start() async throws {
    try ensureAcceptingOperations()
    guard !isStarted else { return }
    snapshot = await buildSnapshot()
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

  func reattachRoutesForTesting(
    _ logicalIDs: Set<String>,
    origin: RouteWorkOrigin = .userInitiated
  ) async {
    await reattachRoutes(forLogicalIDs: logicalIDs, origin: origin)
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
    enterShutdownState()

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

  func handBackAppsForShutdown() async {
    enterShutdownState()
    _ = handBackEveryApp()
  }

  private func enterShutdownState() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    isStarted = false
    lifecycleEpoch = lifecycleEpoch == .max ? 0 : lifecycleEpoch + 1
    stagedIntentByLogicalID.removeAll()
  }

  /// First, before anything that can be slow: hand every app back to its
  /// own output. Each installed route is a managed release (silence, then
  /// release the tap's mute); each parked one, already silent for good,
  /// only releases its mute. All of it shares one deadline for waits on
  /// the controllers' callback queues, so a blocked queue cannot use up
  /// the app's termination timeout. If Waves is killed after this, each
  /// tap left is removed by macOS with the process. Runs once.
  private func handBackEveryApp() -> (handedBack: [PerAppTapController], degradations: [CleanupDegradation]) {
    if let shutdownHandBack { return shutdownHandBack }
    var degradations: [CleanupDegradation] = []
    let handBackDeadline = DispatchTime.now() + Self.shutdownHandBackWaitLimit
    let installedControllers = controllers.sorted { $0.key < $1.key }.map(\.value)
    controllers.removeAll()
    unreleasedRoutes.removeAll()
    pendingRouteRepairs.removeAll()
    var handedBack: [PerAppTapController] = []
    for controller in installedControllers {
      let hold = controller.releaseHold(.managedRelease, until: handBackDeadline)
      degradations += hold.degradations
      guard hold.outcome == .released else {
        // Still muting the app, and still playing it at the user's level,
        // until Waves exits.
        controllersPlayingUntilExit.append(controller)
        degradations.append(
          CleanupDegradation(
            appID: controller.appID,
            stage: .controllerDisposal,
            detail:
              "Waves couldn't hand \(controller.appName) back before quitting, so it played through Waves until Waves exited. macOS removes the tap with Waves."
          ))
        continue
      }
      handedBack.append(controller)
    }
    for controller in orphanedControllers {
      degradations += controller.releaseTapMuteIfHeld(until: handBackDeadline)
    }
    shutdownHandBack = (handedBack, degradations)
    return (handedBack, degradations)
  }

  private func performCheckedShutdown() async -> BackendShutdownResult {
    var degradations = retainedCleanupDegradations
    retainedCleanupDegradations.removeAll()

    // Everything below goes through `record` rather than appending directly, so
    // the failures that happen *during shutdown* are logged like every in-session
    // failure is. They previously bypassed the only logging site, which is why a
    // degraded quit left nothing behind explaining which stage had failed.
    func record(_ new: [CleanupDegradation]) {
      guard !new.isEmpty else { return }
      logCleanupDegradations(new)
      degradations.append(contentsOf: new)
    }

    // Usually already done by `handBackAppsForShutdown`.
    let handBack = handBackEveryApp()
    record(handBack.degradations)
    let handedBack = handBack.handedBack

    // Close ingress before awaiting any work. Late native callbacks retain
    // their mailbox safely but cannot queue more work after shutdown begins.
    deviceChangeMailbox.finish()
    routerObservationMailbox.finish()
    let deviceTask = deviceChangeTask
    let routerTask = routerObservationTask
    deviceChangeTask = nil
    routerObservationTask = nil
    deviceTask?.cancel()
    routerTask?.cancel()

    let levelTask = levelUpdateTask
    levelUpdateTask = nil
    levelTask?.cancel()
    if let levelTask {
      await levelTask.value
    }

    record(removeDeviceChangeListener())
    record(removeRouterObservationListeners())
    if let deviceTask { await deviceTask.value }
    if let routerTask { await routerTask.value }
    defaultOutputDeviceChange.recordInitialUID(nil)

    // The slow part: stop and destroy what was handed back.
    for controller in handedBack {
      let controllerDegradations = controller.finishTeardown()
      record(controllerDegradations)
      if !controller.isTornDown {
        // A failed stop or IO-proc destroy can still be followed by a native
        // callback. Keep its Swift callback state alive until process exit.
        orphanedControllers.append(controller)
      }
      if !controllerDegradations.isEmpty {
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

    // One last attempt at anything a previous teardown could not finish, so
    // a stranded tap does not outlive the process if it can be avoided.
    for controller in orphanedControllers {
      record(controller.retryDispose())
    }
    orphanedControllers.removeAll(where: \.isTornDown)
    appsHeldSilentByParkedTaps.removeAll()
    failOpenReleases.removeAll()

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
    routeOutputBindingByRuntimeID.removeAll()
    devicesSeenNotAlive.removeAll()
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
    let rebuilt = await buildSnapshot()
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
      if intent.isExcluded, intent.generation >= latestAcceptedGenerationByLogicalID[intent.appID] ?? 0 {
        // No row, but a route may still be installed for the app: the
        // opt-out reaches it by what it was built for.
        excludedLogicalIDs.insert(intent.appID)
        for runtimeID in controllers.filter({ $0.value.targetProcessFamily.logicalID == intent.appID }).map(\.key) {
          releaseRoute(runtimeID: runtimeID, kind: .forcedRelease)
        }
      }
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
    if intent.isExcluded {
      excludedLogicalIDs.insert(logicalID)
    } else {
      excludedLogicalIDs.remove(logicalID)
    }
    // The user's newest intent replaces whatever an automatic repair left.
    failOpenReleases.removeValue(forKey: logicalID)
    resetReleasePacing(runtimeID: currentApp.id)
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
      routerActivity: currentRouterActivity(replacing: routerActivity)
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
          origin: .userInitiated,
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
    let routerActivity = currentRouterActivity()

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
    resetReleasePacing()
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter {
          Self.isRouteRecoveryCandidate(
            $0,
            hasActiveController: controllers[$0.id]?.isActive == true,
            reclaimMixedOutput: !waveLinkCompatibilityEnabled
          ) || failOpenReleases[$0.logicalID] != nil
        }
        .map(\.logicalID)
    )

    disposeControllers(keeping: [])
    // A route still installed now could not be handed back, and may carry
    // a pending repair or a spent recovery: it is replaced, never reused.
    let retainedRuntimeIDs = Set(controllers.keys)
    // Each route's authorization is captured now, before the snapshot rebuild
    // suspends: an exclusion or a yield that lands meanwhile must stop that
    // route's reattachment.
    let targets = repairContexts(forLogicalIDs: managedLogicalIDs)
    // An explicit repair is the user's say-so to try again: it must not
    // inherit a cooldown that automatic work ran into, nor an automatic
    // retry allowance that is spent.
    routeRebuildBudget.resetForUserRecovery()
    for logicalID in failOpenReleases.keys {
      failOpenReleases[logicalID]?.attemptsRemaining = FailOpenRelease.maximumAttempts
    }
    // buildSnapshot (and the subsequent reattachRoutes) is the single source of
    // route-health truth here: it recomputes backendStatus from scratch, so any
    // isRouteRecoveryHealthy/lastError assignment made before it would be
    // immediately overwritten and has no observable effect.
    snapshot = await buildSnapshot()
    try ensureAcceptingOperations()

    if !targets.isEmpty {
      await reattachRoutes(targets, origin: .userInitiated, forceRebuildRuntimeIDs: retainedRuntimeIDs)
      // A retained route that could not be replaced keeps saying why.
      publishRouteHolds()
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

  /// Moves every route that follows the system default onto the new default.
  ///
  /// Make before break: no controller is disposed up front. Disposing first
  /// released each app's tap before its replacement existed, so every managed
  /// app played at its own full level until the new route took over, then
  /// dropped back. Each route is now rebuilt in place by `applyRoute`, which
  /// silences the outgoing renderer, builds and starts the replacement, and
  /// only then disposes the old controller. See `reattachRoutes(_:mode:)` for
  /// what happens when the replacement cannot be built.
  ///
  /// Only routes that follow the system default were built on the device
  /// that just changed. A route pinned to its own output device keeps its
  /// live tap: rebuilding it would interrupt audio on a device that did not
  /// move, and a pinned device that disappeared is handled by the inventory
  /// reconciliation instead.
  ///
  /// Each route's authorization is captured before the snapshot rebuild,
  /// the pass's first suspension. An exclusion, a call mute, an output choice
  /// or a yield that lands while discovery runs then stops that route's move;
  /// capturing it afterwards would have authorized the move from the newer
  /// state.
  func autoRestoreDevice() async throws -> AudioSessionSnapshot {
    try ensureAcceptingOperations()
    let targets = snapshot.apps
      .filter {
        $0.targetDeviceUID == nil
          && ($0.routingState == .managed || controllers[$0.id]?.isActive == true)
      }
      .map(makeRepairContext)

    snapshot = await buildSnapshot()
    try ensureAcceptingOperations()
    snapshot.updatedAt = .now

    if !targets.isEmpty {
      await reattachRoutes(targets, origin: .automatic, mode: .rehome)
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

  /// Everything that can make background route work (maintenance, device
  /// changes, reattachment) stale while it is suspended. Background work has
  /// no intent generation of its own, so it records the newest accepted one,
  /// the controller it set out to replace, the output it was aimed at, and
  /// and whether another router holds the app. Any change to these means
  /// newer intent (an edit, an exclusion, an output choice), a yield to
  /// another router, or newer route work landed first, and the repair must
  /// not start or install. A batch captures every route's context when it
  /// selects the route, before its first suspension, not when the route's
  /// turn comes.
  ///
  /// The app's process lifetime is part of it. Discovery gives a relaunched
  /// app the same runtime and logical IDs, so without it a repair recorded
  /// for the old process would pass for the new one and capture it.
  ///
  /// The row's routing state itself is not compared: a snapshot rebuild
  /// recomputes it from controller and audibility state (a released row
  /// becomes monitor-only, an audible one live), so it changes without any
  /// newer intent. What a yield or an identity collision changes is
  /// recorded instead.
  struct RouteRepairContext: Sendable {
    let logicalID: String
    let runtimeID: String
    let acceptedGeneration: UInt64?
    let lifecycleEpoch: UInt64
    let incumbent: ObjectIdentifier?
    let targetDeviceUID: String?
    let routerHold: RouteHealthContext?
    let hasAmbiguousIdentity: Bool
    let processLifetime: AppProcessLifetimeIdentity?
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

  func makeRepairContext(for app: AudioApp) -> RouteRepairContext {
    RouteRepairContext(
      logicalID: app.logicalID,
      runtimeID: app.id,
      acceptedGeneration: latestAcceptedGenerationByLogicalID[app.logicalID],
      lifecycleEpoch: lifecycleEpoch,
      incumbent: controllers[app.id].map(ObjectIdentifier.init),
      targetDeviceUID: app.targetDeviceUID,
      routerHold: Self.routerHold(of: app),
      hasAmbiguousIdentity: app.hasAmbiguousIdentity,
      processLifetime: app.runtimeIdentity?.lifetime
    )
  }

  func repairContexts(forLogicalIDs logicalIDs: Set<String>) -> [RouteRepairContext] {
    snapshot.apps.filter { logicalIDs.contains($0.logicalID) }.map(makeRepairContext)
  }

  /// The router that holds `app`, if any: the part of its health context a
  /// yield (or a router's release) changes.
  static func routerHold(of app: AudioApp) -> RouteHealthContext? {
    switch app.routeHealthContext {
    case .verifiedRouterOwnership, .unattributableRouterFallback, .routerMixedOutput, .waveLinkBridge:
      app.routeHealthContext
    case nil, .geometryRecoveryInProgress, .geometryRecoveryExhausted:
      nil
    }
  }

  func isRepairCurrent(_ context: RouteRepairContext) -> Bool {
    guard context.lifecycleEpoch == lifecycleEpoch,
      latestAcceptedGenerationByLogicalID[context.logicalID] == context.acceptedGeneration,
      controllers[context.runtimeID].map(ObjectIdentifier.init) == context.incumbent,
      let app = snapshot.apps.first(where: { $0.logicalID == context.logicalID }),
      app.id == context.runtimeID,
      app.targetDeviceUID == context.targetDeviceUID,
      Self.routerHold(of: app) == context.routerHold,
      app.hasAmbiguousIdentity == context.hasAmbiguousIdentity,
      app.runtimeIdentity?.lifetime == context.processLifetime
    else { return false }
    return true
  }

  /// One check for whichever context the route work carries.
  func ensureRouteWorkCurrent(
    _ generationContext: IntentGenerationContext?,
    _ repairContext: RouteRepairContext?
  ) throws {
    if let generationContext {
      try ensureGenerationCurrent(generationContext)
    }
    if let repairContext {
      guard isStarted, !isShuttingDown else { throw IntentBackendStoppedError() }
      guard isRepairCurrent(repairContext) else { throw IntentSupersededError() }
    }
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
    // Exclusion is the user's capture opt-out: Waves must not render the
    // app by any controller, so this is a forced release.
    releaseInstalledController(runtimeID: runtimeID, kind: .forcedRelease)
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
    // A tap that would not let go holds the app silent: the row says so now,
    // not on the next maintenance pass.
    publishRouteHolds()
  }

  private func disposeControllerInstalledByGeneration(
    runtimeID: String,
    generation: UInt64
  ) {
    guard controllerGenerationByRuntimeID[runtimeID] == generation else { return }
    guard releaseInstalledController(runtimeID: runtimeID, kind: .managedRelease) == .released else { return }
    controllerGenerationByRuntimeID.removeValue(forKey: runtimeID)
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
    repairContext: RouteRepairContext? = nil,
    preservesGeometryRecovery: Bool = false,
    origin: RouteWorkOrigin,
    routerActivity: VerifiedRouterActivitySnapshot? = nil
  ) async throws {
    try ensureAcceptingOperations()
    guard supportsPerAppRouting else {
      throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
    }
    // A view of other routers taken before a router change is not trusted.
    var routerGeneration = routerActivity?.observationGeneration ?? routerObservationGeneration
    try ensureRouterAuthorityCurrent(for: app, since: &routerGeneration)
    if let conflict = competingAudioRouterConflict(for: app, routerActivity: routerActivity) {
      throw BackendError.unsupportedOperation(conflict.detail)
    }
    // The user's exclusion outranks every automatic path that reaches here.
    guard !excludedLogicalIDs.contains(app.logicalID) else { throw IntentSupersededError() }

    try ensureRouteWorkCurrent(generationContext, repairContext)
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
    // every process we'd tap now and renders where the route should play. A
    // target-device change explicitly forces a new controller, while
    // volume/mute/boost/EQ changes stay on the current route. A route left on
    // an old default (its move was overtaken by this very edit) is moved now.
    if !forceRebuild,
      let controller = controllers[app.id],
      controller.isActive,
      controller.covers(targetProcessFamily),
      isRouteOnItsExpectedDevice(app)
    {
      try ensureRouteWorkCurrent(generationContext, repairContext)
      controller.apply(volume: volume, volumeBoost: app.volumeBoost, muted: muted)
      controller.setEqualizer(stagedEqualizer)
      controller.setManagedAudioEqualizer(managedAudioEqualizerSettings)
      controller.setAdaptiveGainDB(adaptiveGainDBByAppID[app.logicalID] ?? 0)
      // Route work that succeeded on it commits it as the app's route again.
      unreleasedRoutes.removeValue(forKey: app.id)
      return
    }

    try ensureRouteWorkCurrent(generationContext, repairContext)
    // Make before break. The replacement is built and started silent while
    // the incumbent keeps playing; both taps keep the app's own output muted,
    // so the user hears the incumbent alone. Nothing touches the incumbent
    // until the replacement is authorized to take over, so work that fails,
    // or is overtaken while suspended in creation, leaves it exactly as it was.
    let (controller, outputBinding) = try await createControllerWithRetry(
      for: app,
      processTarget: processTarget,
      equalizerSettings: stagedEqualizer,
      generationContext: generationContext,
      repairContext: repairContext,
      origin: origin,
      routerGeneration: &routerGeneration
    )

    do {
      try ensureAcceptingOperations()
      // Background work was suspended in creation retries; newer intent or
      // newer route work for this app wins and this controller is discarded.
      // So does a router that started meanwhile.
      try ensureRouteWorkCurrent(generationContext, repairContext)
      try ensureRouterAuthorityCurrent(for: app, since: &routerGeneration)
      if let generationContext,
        let installedGeneration = controllerGenerationByRuntimeID[app.id],
        installedGeneration > generationContext.generation
      {
        throw IntentSupersededError()
      }
    } catch {
      discardUnusedReplacement(controller, runtimeID: app.id)
      throw error
    }

    // The handoff. Nothing below suspends, so no other route work can run
    // between silencing the incumbent and un-muting its replacement. The
    // replacement is un-muted only once every other renderer of the app is
    // confirmed silent; otherwise it is discarded and the incumbent stays.
    let incumbent = controllers[app.id]
    var silence = PerAppTapController.HandoffSilence.faded
    if confirmParkedRenderersSilent(forRuntimeID: app.id) {
      if let incumbent, incumbent.isActive {
        silence = incumbent.silenceForHandoff(maxPolls: Self.handoffSilenceMaxPolls, pause: handoffSilencePause)
      }
    } else {
      silence = .unconfirmed
    }
    guard silence != .unconfirmed else {
      discardUnusedReplacement(controller, runtimeID: app.id)
      throw HandoffSilenceUnconfirmedError(appName: app.displayName)
    }
    controllers[app.id] = controller
    // A fresh controller starts with a fresh geometry-recovery budget. Only
    // the rebuild the coordinator itself asked for carries it over, so that
    // rebuild's verification window and attempt count still apply.
    if !preservesGeometryRecovery {
      geometryRecoveryByRuntimeID.removeValue(forKey: app.id)
    }
    routeOutputBindingByRuntimeID[app.id] = outputBinding
    if let generationContext {
      controllerGenerationByRuntimeID[app.id] = generationContext.generation
    } else {
      controllerGenerationByRuntimeID.removeValue(forKey: app.id)
    }
    if let incumbent {
      retireController(incumbent)
    }
    unreleasedRoutes.removeValue(forKey: app.id)
    // The rebuild a pending repair asked for has happened.
    pendingRouteRepairs.removeValue(forKey: app.id)
    failOpenReleases.removeValue(forKey: app.logicalID)
    // Only now, with every other renderer of the app cut to silence, does the
    // replacement fade in to the app's level.
    controller.apply(volume: volume, volumeBoost: app.volumeBoost, muted: muted)
    controller.setEqualizer(stagedEqualizer)
    controller.setManagedAudioEqualizer(managedAudioEqualizerSettings)
    controller.setAdaptiveGainDB(adaptiveGainDBByAppID[app.logicalID] ?? 0)

    // A freshly-created process tap proves capture is currently authorized.
    captureAuthorization = .authorized
  }

  /// False only when the live route is known to render to a device other than
  /// the one it should play on now: its pinned target, or the current default.
  /// Unknown either way (no recorded binding, or no readable default) counts
  /// as true, so nothing is rebuilt on a guess. Every installed route records
  /// its device, so "no binding" means a controller this backend did not
  /// build. Cheap enough for every volume edit: a pinned route reads nothing,
  /// a default-following one reads the default device's UID.
  func isRouteOnItsExpectedDevice(_ app: AudioApp) -> Bool {
    guard let bound = routeOutputBindingByRuntimeID[app.id]?.deviceUID,
      let expected = expectedOutputDeviceUID(for: app)
    else { return true }
    return bound == expected
  }

  func startNewControllerForTesting(
    _ controller: PerAppTapController,
    runtimeID: String,
    start: @Sendable () throws -> Void
  ) throws {
    try startNewController(controller, runtimeID: runtimeID, start: start)
  }

  func routeOutputBindingForTesting(runtimeID: String) -> RouteOutputBinding? {
    routeOutputBindingByRuntimeID[runtimeID]
  }

  /// Starts a controller that was just built. One that will not start is a
  /// replacement that was never installed, and is discarded like any other:
  /// while the app's live route plays, its tap is not told to un-mute.
  func startNewController(
    _ controller: PerAppTapController,
    runtimeID: String,
    start: () throws -> Void
  ) throws {
    do {
      try start()
    } catch {
      logger.error(
        "Controller start failed for \(controller.appName, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      discardUnusedReplacement(controller, runtimeID: runtimeID)
      throw error
    }
  }

  /// Disposes a replacement that was built but not installed. It never left
  /// silence. While an incumbent's tap still keeps the app's own output muted
  /// it is retired without releasing its own tap mute; with no incumbent it
  /// is force-released, so the app is audible. It never carried the app and
  /// was never committed, so there is no level a managed release could put
  /// it back to.
  private func discardUnusedReplacement(_ replacement: PerAppTapController, runtimeID: String) {
    if controllers[runtimeID]?.isActive == true {
      retireController(replacement)
    } else {
      forceReleaseUninstalledController(replacement)
    }
  }

  private func createControllerWithRetry(
    for app: AudioApp,
    processTarget: ResolvedProcessTarget,
    equalizerSettings: EqualizerSettings,
    generationContext: IntentGenerationContext?,
    repairContext: RouteRepairContext?,
    origin: RouteWorkOrigin,
    routerGeneration: inout UInt64
  ) async throws -> (PerAppTapController, RouteOutputBinding?) {
    let maxRetries = 3
    var lastError: Error?
    var currentProcessTarget = processTarget

    for attempt in 1...maxRetries {
      try ensureAcceptingOperations()
      do {
        try ensureRouteWorkCurrent(generationContext, repairContext)
        // Every attempt after the first follows a suspension.
        try ensureRouterAuthorityCurrent(for: app, since: &routerGeneration)
        try spendRouteRebuildBudget(origin)
        let created = try createController(
          for: app,
          processTarget: currentProcessTarget,
          equalizerSettings: equalizerSettings
        )
        if attempt > 1 {
          logger.info("Successfully created controller for \(app.displayName) on attempt \(attempt)")
        }
        return created
      } catch let superseded as IntentSupersededError {
        throw superseded
      } catch let refused as RouteRebuildCeilingError {
        logger.warning("Automatic route rebuild for \(app.displayName, privacy: .public) refused: rebuild ceiling active")
        throw refused
      } catch {
        lastError = error
        logger.warning("Failed to create controller for \(app.displayName) on attempt \(attempt): \(error.localizedDescription)")

        if attempt < maxRetries {
          let backoffMs = UInt64(100 * Int(pow(4.0, Double(attempt - 1))))
          try ensureRouteWorkCurrent(generationContext, repairContext)
          try await controllerRetryPause(backoffMs * 1_000_000)
          try ensureAcceptingOperations()
          try ensureRouteWorkCurrent(generationContext, repairContext)

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

    try ensureRouteWorkCurrent(generationContext, repairContext)
    logger.error("Giving up on managed route for \(app.displayName) after \(maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown error")")
    throw BackendError.managedRouteUnavailable(
      "Waves couldn't take over audio for \(app.displayName). If this keeps happening, check that audio capture is allowed in System Settings › Privacy & Security."
    )
  }

  /// Builds and starts one controller. Also returns the output device it
  /// renders to and that device's format, read for this attempt before the
  /// tap exists: each attempt resolves the default itself, so a binding read
  /// once before the retries could describe a device an earlier, failed
  /// attempt used. A format change that lands during creation is then seen
  /// as a change afterwards rather than absorbed.
  private func createController(
    for app: AudioApp,
    processTarget: ResolvedProcessTarget,
    equalizerSettings: EqualizerSettings
  ) throws -> (PerAppTapController, RouteOutputBinding?) {
    try ensureAcceptingOperations()

    // Every new renderer starts silent. `applyRoute` un-mutes it only once it
    // is installed and the incumbent it replaces is silent.
    var silentApp = app
    silentApp.isMuted = true
    if let controllerFactory {
      try revalidateProcessTarget(processTarget, for: app)
      let outputBinding = currentOutputBinding(for: app)
      let controller = try controllerFactory(
        silentApp,
        processTarget.processObjectIDs,
        equalizerSettings,
        managedAudioEqualizerSettings,
        adaptiveGainDBByAppID[app.logicalID] ?? 0
      )
      controller.ownerProcessLifetime = app.runtimeIdentity?.lifetime
      return (controller, outputBinding)
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
      let binding = outputBinding(forDeviceUID: outputDeviceUID)

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
        volume: silentApp.desiredVolume,
        volumeBoost: silentApp.volumeBoost,
        muted: silentApp.isMuted,
        equalizerSettings: equalizerSettings,
        managedAudioEqualizerSettings: managedAudioEqualizerSettings,
        adaptiveGainDB: adaptiveGainDBByAppID[app.logicalID] ?? 0,
        audioFormatPlan: audioFormatPlan,
        subDeviceInputStreamCount: subDeviceInputStreamCount
      )
      controller.ownerProcessLifetime = app.runtimeIdentity?.lifetime

      controllerOwnsResources = true
      try startNewController(controller, runtimeID: app.id) { try controller.start() }

      return (controller, binding)
    }

    throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
  }

  /// Rediscovers running apps and merges the backend's control state into
  /// them. Discovery suspends (application capture, then detached work), and
  /// intents, exclusions, yields and route work all run meanwhile. The
  /// control state merged in is therefore read after the last suspension, from
  /// the snapshot as it is then: merging the copy taken before discovery
  /// started would overwrite whatever landed in between (an exclusion, a call
  /// mute, an output choice) with older values.
  private func buildSnapshot() async -> AudioSessionSnapshot {
    // Re-check real capture authorization so a snapshot honestly reflects whether
    // Waves can actually take over audio, not merely whether the OS supports it.
    refreshCaptureAuthorization()
    let audible = audibleProcessIndexProvider?() ?? getAudibleProcesses()
    let discoveryInputs = snapshot
    // Reuse encoded icons across discovery passes only while the captured
    // process identity still matches. Relaunches must capture fresh bytes.
    let knownIcons = discoveryInputs.apps.reduce(
      into: [String: AppRuntimeDiscovery.KnownIcon]()
    ) { result, app in
      guard let data = app.iconTIFFData, let runtimeIdentity = app.runtimeIdentity else { return }
      result[app.logicalID] = AppRuntimeDiscovery.KnownIcon(
        data: data,
        runtimeIdentity: runtimeIdentity
      )
    }
    let discoveryCapture: AppRuntimeDiscovery.Capture
    if let applicationCaptureProvider {
      discoveryCapture = await applicationCaptureProvider()
    } else {
      discoveryCapture = await AppRuntimeDiscovery.captureRunningApplications(
        currentBundleID: currentBundleID,
        knownIcons: knownIcons
      )
    }
    let incumbentIdentities = discoveryInputs.apps.reduce(into: [String: AppRuntimeIdentity]()) { result, app in
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
    // No suspension from here to the caller's assignment.
    let previousSnapshot = snapshot
    let previousByLogicalID = dictionaryByLogicalID(previousSnapshot.apps)
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
        && previous.runtimeIdentity?.lifetime == candidate.runtimeIdentity?.lifetime
      {
        app.routingState = .error
        app.notes = previous.notes
        app.hasNoAudioCapability = previous.hasNoAudioCapability
      }
      return app
    }

    var mergedLogicalIDs = Set(mergedApps.map(\.logicalID))
    for previous in previousSnapshot.apps {
      guard !mergedLogicalIDs.contains(previous.logicalID) else { continue }
      guard AppRuntimeDiscovery.isStillRunning(previous, in: discoveryCapture, currentBundleID: currentBundleID) else { continue }

      var retained = previous
      retained.isActive = false
      retained.isProducingOutput = false
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

    releaseRoutesMissing(from: &mergedApps, previous: previousSnapshot.apps)
    // A repair recorded for a process that is gone, or that relaunched under
    // the same IDs, ends here.
    let lifetimeByID = Dictionary(mergedApps.map { ($0.id, $0.runtimeIdentity?.lifetime) }, uniquingKeysWith: { first, _ in first })
    failOpenReleases = failOpenReleases.filter { _, release in
      guard let lifetime = lifetimeByID[release.context.runtimeID] else { return false }
      return lifetime == release.context.processLifetime
    }
    applyStickyRouteNotes(to: &mergedApps)

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
        previousRecentDeviceIDs: previousSnapshot.recentDeviceIDs
      )
    } catch {
      deviceReadiness = OutputDeviceReadiness(
        currentDevice: nil,
        previousRecentDeviceIDs: previousSnapshot.recentDeviceIDs,
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
        isRouteRecoveryHealthy: isRouteRecoveryHealthy(
          deviceIsReady: deviceReadiness.isReady,
          hasRouteErrors: hasRouteErrors
        ),
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
