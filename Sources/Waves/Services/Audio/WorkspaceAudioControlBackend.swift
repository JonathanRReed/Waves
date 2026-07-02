import AppKit
import ApplicationServices
import AudioToolbox
import Darwin
import Foundation
import OSLog
import WavesAudioCore

actor WorkspaceAudioControlBackend: AudioControlBackend {
  // Start from a neutral, empty session. Using `.preview` here would seed the
  // live backend with fabricated apps, volumes, and a fake error string that
  // could surface before the first real snapshot is built.
  private var snapshot: AudioSessionSnapshot = .empty
  private let currentBundleID = Bundle.main.bundleIdentifier
  private var controllers: [String: PerAppTapController] = [:]
  private var levelUpdateTask: Task<Void, Never>?
  private var routeMaintenanceTick = 0
  private var staleRouteTicks: [String: Int] = [:]
  private let routeMaintenanceTickInterval = 20
  private let staleRouteThresholdTicks = 24
  private let staleRouteLevelThreshold: Float = 0.0005
  private var deviceChangeListenerToken: UInt32 = 0
  private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
  private let logger = Logger(subsystem: "com.waves.backend", category: "AudioBackend")

  nonisolated let deviceChangeEvents: AsyncStream<Void>
  private nonisolated let deviceChangeContinuation: AsyncStream<Void>.Continuation

  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.deviceChangeEvents = stream
    self.deviceChangeContinuation = continuation
  }

  func start() async throws {
    snapshot = await buildSnapshot(merging: snapshot)
    startLevelUpdateTask()
    addDeviceChangeListener()
  }

  func stop() async {
    removeDeviceChangeListener()
    stopLevelUpdateTask()
    disposeControllers(keeping: [])
    deviceChangeContinuation.finish()
  }

  func currentSnapshot() async -> AudioSessionSnapshot {
    snapshot
  }

  func refresh() async throws -> AudioSessionSnapshot {
    snapshot = await buildSnapshot(merging: snapshot)
    return snapshot
  }

  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    // Validate volume: handle NaN and infinity by treating them as 1.0, then
    // fall through to the normal apply path so appliedVolume/routingState/notes
    // stay consistent with desiredVolume instead of being left stale.
    if !volume.isFinite {
      logger.warning("Invalid volume value for \(appID): \(volume), defaulting to 1.0")
    }
    let target: Float = volume.isFinite ? max(0.0, min(1.0, volume)) : 1.0
    snapshot.apps[index].desiredVolume = target

    // On unsupported OSes (macOS < 14.2) no route can ever be established, so
    // don't attempt one: it would throw unsupportedOperation, flash an .error
    // chip + a generic failure toast, and only be corrected on the next
    // snapshot rebuild. Stay calmly monitor-only with the explanatory note —
    // matching how buildSnapshot demotes unsupported apps — and don't throw.
    guard supportsPerAppRouting else {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].notes = "Per-app route requires macOS 14.2+"
      snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : target
      return
    }

    // applyRoute suspends (tap-retry backoff) and the actor is reentrant, so a
    // concurrent refresh/buildSnapshot can replace `snapshot.apps` while it is
    // awaited. Every write after the await must re-resolve the row by appID —
    // the captured index would trap or land on the wrong app — and skip it if
    // the row vanished. Same pattern in the other setters below.
    //
    // buildSnapshot's merge (see its `app.desiredVolume = previous.desiredVolume`)
    // copies desiredVolume from whatever `previousSnapshot` it was handed — if
    // that snapshot was captured before this call's write above, a concurrent
    // rebuild finishing during this await clobbers `desiredVolume` back to the
    // pre-change value even though `target` is what's actually being applied.
    // Re-asserting `target` (the locally captured, authoritative value, not a
    // re-read of the possibly-clobbered snapshot) after re-resolution in BOTH
    // branches below closes that window.
    do {
      try await applyRoute(for: snapshot.apps[index], toVolume: target, muted: snapshot.apps[index].isMuted)
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].desiredVolume = target
        snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : target
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].notes = nil
      }
      refreshGlobalRouteHealth()
    } catch {
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].desiredVolume = target
        snapshot.apps[index].routingState = .error
        snapshot.apps[index].notes = error.localizedDescription
        snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : target
      }
      refreshGlobalRouteHealth(latestError: error.localizedDescription)
      throw error
    }
  }

  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    let previousMuted = snapshot.apps[index].isMuted
    snapshot.apps[index].isMuted = isMuted

    // Unsupported OS: Waves can't mute per-app below macOS 14.2, so don't claim
    // a mute that isn't real — revert the flag (mirrors the apply-failure path)
    // and stay monitor-only. Otherwise the row would show the muted glyph while
    // the app is still audible. The store gates its success toast on .managed,
    // so no misleading "muted" confirmation is shown.
    guard supportsPerAppRouting else {
      snapshot.apps[index].isMuted = previousMuted
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].notes = "Per-app route requires macOS 14.2+"
      return
    }

    // Re-resolve the row after the await (see setDesiredVolume): a concurrent
    // rebuild during applyRoute's suspension can replace `snapshot.apps`.
    do {
      try await applyRoute(for: snapshot.apps[index], toVolume: snapshot.apps[index].desiredVolume, muted: isMuted)
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].isMuted = isMuted
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].peakLevel = isMuted ? 0 : max(0.0, snapshot.apps[index].peakLevel)
        snapshot.apps[index].rmsLevel = isMuted ? 0 : max(0.0, snapshot.apps[index].rmsLevel)
        snapshot.apps[index].appliedVolume = isMuted ? 0 : snapshot.apps[index].desiredVolume
        snapshot.apps[index].notes = nil
      }
      refreshGlobalRouteHealth()
    } catch {
      // The mute could not be applied (no tap established), so revert the
      // snapshot flag — otherwise the row shows the muted glyph while audio
      // still plays at full volume. routingState=.error surfaces the failure.
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].isMuted = previousMuted
        snapshot.apps[index].routingState = .error
        snapshot.apps[index].notes = error.localizedDescription
        snapshot.apps[index].peakLevel = 0
        snapshot.apps[index].rmsLevel = 0
        snapshot.apps[index].appliedVolume = previousMuted ? 0 : snapshot.apps[index].desiredVolume
      }
      refreshGlobalRouteHealth(latestError: error.localizedDescription)
      throw error
    }
  }

  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    let clampedBoost = max(1.0, min(4.0, boost))
    snapshot.apps[index].volumeBoost = clampedBoost

    // Unsupported OS: stay monitor-only instead of attempting a doomed route
    // that would throw and flash an error chip + toast (see setDesiredVolume).
    guard supportsPerAppRouting else {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].notes = "Per-app route requires macOS 14.2+"
      return
    }

    // Re-apply the route with the new boost. applyRoute -> controller.apply
    // already writes the updated boost together with the current volume/mute in
    // a single queued write, so there's no need for a separate (redundant,
    // off-queue) controller.setVolumeBoost call that could clobber a concurrent
    // volume/mute change with a stale captured value.
    // Re-resolve the row after the await (see setDesiredVolume): a concurrent
    // rebuild during applyRoute's suspension can replace `snapshot.apps` — and
    // its merge copies volumeBoost from whatever previousSnapshot it was
    // handed, which can clobber this row's boost back to the pre-change value
    // if that snapshot was captured before the write above. Re-assert
    // `clampedBoost` (the locally captured, authoritative value) after
    // re-resolution in both branches to close that window.
    do {
      try await applyRoute(for: snapshot.apps[index], toVolume: snapshot.apps[index].desiredVolume, muted: snapshot.apps[index].isMuted)
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].volumeBoost = clampedBoost
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].notes = nil
      }
      refreshGlobalRouteHealth()
    } catch {
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].volumeBoost = clampedBoost
        snapshot.apps[index].routingState = .error
        snapshot.apps[index].notes = error.localizedDescription
      }
      refreshGlobalRouteHealth(latestError: error.localizedDescription)
      throw error
    }
  }

  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {
    if snapshot.currentDevice?.id == deviceID {
      snapshot.currentDevice?.volumeControlMode = mode
    }
  }

  func pinApp(_ isPinned: Bool, appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isPinned = isPinned
  }

  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot {
    for entry in profile.entries {
      // Membership-only entries are pure grouping — they must never tap or alter
      // the app's audio. Only entries that set a level establish a route.
      guard entry.hasLevels else { continue }
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) else {
        continue
      }

      // Apply only the fields the entry sets; keep the app's current value for
      // the rest so e.g. a mute-only entry doesn't also slam the volume to a
      // fabricated default.
      let targetVolume = entry.desiredVolume ?? snapshot.apps[index].desiredVolume
      let targetMuted = entry.isMuted ?? snapshot.apps[index].isMuted
      let targetBoost = entry.volumeBoost ?? snapshot.apps[index].volumeBoost
      snapshot.apps[index].desiredVolume = targetVolume
      snapshot.apps[index].isMuted = targetMuted
      snapshot.apps[index].volumeBoost = targetBoost

      // Re-resolve the row after the await (see setDesiredVolume): a concurrent
      // rebuild during applyRoute's suspension can replace `snapshot.apps`.
      do {
        try await applyRoute(
          for: snapshot.apps[index],
          toVolume: targetVolume,
          muted: targetMuted
        )
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) {
          snapshot.apps[index].appliedVolume = targetMuted ? 0 : targetVolume
          snapshot.apps[index].routingState = .managed
          snapshot.apps[index].notes = nil
        }
        refreshGlobalRouteHealth()
      } catch {
        if let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) {
          snapshot.apps[index].routingState = .error
          snapshot.apps[index].notes = error.localizedDescription
          snapshot.apps[index].appliedVolume = targetMuted ? 0 : targetVolume
        }
        refreshGlobalRouteHealth(latestError: error.localizedDescription)
      }
    }

    snapshot.updatedAt = .now
    return snapshot
  }

  func saveCurrentProfile(named name: String) async throws -> Profile {
    Profile(
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
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter { $0.routingState == .managed || controllers[$0.id]?.isActive == true }
        .map(\.logicalID)
    )

    disposeControllers(keeping: [])
    // buildSnapshot (and the subsequent reattachRoutes) is the single source of
    // route-health truth here: it recomputes backendStatus from scratch, so any
    // isRouteRecoveryHealthy/lastError assignment made before it would be
    // immediately overwritten and has no observable effect.
    snapshot = await buildSnapshot(merging: snapshot)

    if !managedLogicalIDs.isEmpty {
      await reattachRoutes(forLogicalIDs: managedLogicalIDs)
    }

    return snapshot
  }

  func autoRestoreDevice() async throws -> AudioSessionSnapshot {
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter { $0.routingState == .managed || controllers[$0.id]?.isActive == true }
        .map(\.logicalID)
    )

    disposeControllers(keeping: [])
    snapshot = await buildSnapshot(merging: snapshot)
    snapshot.updatedAt = .now

    if !managedLogicalIDs.isEmpty {
      await reattachRoutes(forLogicalIDs: managedLogicalIDs)
    }

    return snapshot
  }

  func diagnosticsReport() async -> DiagnosticsReport {
    // Re-probe real capture authorization so opening Advanced reflects the
    // current TCC state rather than the result cached at the last refresh.
    // The probe creates and immediately destroys a private tap with no IO
    // proc, so it is side-effect-free and cheap.
    refreshCaptureAuthorization()

    // A hard route failure is one where the OS and capture permission are both
    // fine yet real routes errored — that is genuinely broken, not transient or
    // unsupported, so the Route recovery check should read as .failed (red).
    let hasRouteErrors = snapshot.apps.contains { $0.routingState == .error }
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
          detail: snapshot.backendStatus.isRouteRecoveryHealthy
            ? "Per-app routing is active and can be reapplied."
            : "There were active route setup or control errors. Recover routes and retry."
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
    switch captureAuthorization {
    case .authorized: return .passed
    case .notGranted: return .failed
    case .undetermined, .unsupported: return .warning
    }
  }

  private var captureAuthorizationDetail: String {
    switch captureAuthorization {
    case .authorized:
      return "Audio capture is granted. Waves can apply per-app volume, mute, and boost."
    case .notGranted:
      return "Audio capture is not granted, so per-app controls cannot take effect. Allow Waves to record audio in System Settings › Privacy & Security › Microphone, then refresh."
    case .undetermined:
      return "Audio capture status is not yet known. Refresh to check."
    case .unsupported:
      return "Per-app routing needs macOS 14.2 or newer."
    }
  }

  private var recoverabilitySummary: String {
    if snapshot.backendStatus.isAudioComponentInstalled {
      let managed = snapshot.apps.filter { $0.routingState == .managed }.count
      return "Per-app routing is active for this session. Managed routes currently available: \(managed)."
    }

    return "Per-app routing is not available on this OS version."
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

  /// Whether the system has actually granted Core Audio capture (TCC). This is
  /// distinct from OS support: a 14.2+ machine supports taps but the user may
  /// never have granted capture, in which case routing silently does nothing.
  private(set) var captureAuthorization: CaptureAuthorization = .undetermined

  /// Probes real audio-capture authorization by creating and immediately
  /// destroying a private global process tap (no IO proc is started, so no
  /// audio is captured). A successful create means TCC granted; a failure means
  /// it is not currently granted. The result is cached on `captureAuthorization`.
  @discardableResult
  func refreshCaptureAuthorization() -> CaptureAuthorization {
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
    if status == noErr {
      if tapID != .unknown {
        _ = AudioHardwareDestroyProcessTap(tapID)
      }
      captureAuthorization = .authorized
    } else {
      // Core Audio does not expose a dedicated "denied" code, so any failure to
      // create a tap is reported as "not granted" rather than guessed-at detail.
      logger.warning("Audio-capture permission probe failed (OSStatus: \(status))")
      captureAuthorization = .notGranted
    }
    return captureAuthorization
  }

  private func applyRoute(for app: AudioApp, toVolume volume: Float, muted: Bool, forceRebuild: Bool = false) async throws {
    guard supportsPerAppRouting else {
      throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
    }

    let processObjectIDs = try resolveProcessObjectIDs(for: app)

    // Reuse the live tap for parameter-only changes as long as it already covers
    // every process we'd tap now. For browsers/Electron the audible-helper PID
    // set churns (renderer/"Audio Service" PIDs spawn and die), so an exact-match
    // guard would tear down and rebuild the whole process tap + aggregate device
    // on every volume nudge — an audible glitch and heavy Core Audio churn. A
    // subset check rebuilds only when a genuinely new audio-producing process
    // appears that the current tap doesn't yet capture.
    if !forceRebuild,
       let controller = controllers[app.id],
       controller.isActive,
       controller.covers(processObjectIDs) {
      controller.apply(volume: volume, volumeBoost: app.volumeBoost, muted: muted)
      return
    }

    if let existing = controllers.removeValue(forKey: app.id) {
      // Fully tear down the old route. invalidate() only stops the IO proc and
      // would leak the aggregate device and process tap.
      existing.dispose()
    }

    let controller = try await createControllerWithRetry(for: app, processObjectIDs: processObjectIDs)
    // The actor can suspend at the await above, so a reentrant applyRoute may
    // have installed a controller for this app meanwhile. Dispose it before
    // replacing, otherwise we orphan a live tap/aggregate (leak + double audio).
    if let raced = controllers.removeValue(forKey: app.id) {
      raced.dispose()
    }
    controllers[app.id] = controller
    controller.apply(volume: volume, volumeBoost: app.volumeBoost, muted: muted)
    // A freshly-created process tap proves capture is currently authorized, so
    // refresh the cached state. Otherwise refreshGlobalRouteHealth() (called by
    // the per-app setters right after this) would recompute health from a stale
    // .notGranted/.undetermined and leave route health/onboarding warning even
    // though the route just succeeded.
    captureAuthorization = .authorized
  }

  private func createControllerWithRetry(for app: AudioApp, processObjectIDs: [AudioObjectID]) async throws -> PerAppTapController {
    let maxRetries = 3
    var lastError: Error?
    var currentProcessObjectIDs = processObjectIDs

    for attempt in 1...maxRetries {
      do {
        let controller = try createController(for: app, processObjectIDs: currentProcessObjectIDs)
        if attempt > 1 {
          logger.info("Successfully created controller for \(app.displayName) on attempt \(attempt)")
        }
        return controller
      } catch {
        lastError = error
        logger.warning("Failed to create controller for \(app.displayName) on attempt \(attempt): \(error.localizedDescription)")

        // Clean up any partial state before retry
        if attempt < maxRetries {
          // Exponential backoff: 100ms, 400ms, 1600ms
          let backoffMs = UInt64(100 * Int(pow(4.0, Double(attempt - 1))))
          try await Task.sleep(nanoseconds: backoffMs * 1_000_000)

          // Re-resolve process object IDs in case they changed. Tolerate a
          // transient resolution failure (e.g. the app quit or lost all
          // audible process objects between attempts) so the loop continues to
          // the final friendly managedRouteUnavailable message instead of
          // letting the raw resolution error escape early.
          if let refreshedProcessObjectIDs = try? resolveProcessObjectIDs(for: app),
            refreshedProcessObjectIDs != currentProcessObjectIDs {
            logger.info("Process object IDs changed for \(app.displayName) during retry")
            currentProcessObjectIDs = refreshedProcessObjectIDs
          }
        }
      }
    }

    // The technical cause (OSStatus, attempt count) is already logged above.
    // Surface a plain-language, actionable message to the user.
    logger.error("Giving up on managed route for \(app.displayName) after \(maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown error")")
    throw BackendError.managedRouteUnavailable(
      "Waves couldn't take over audio for \(app.displayName). If this keeps happening, check that audio capture is allowed in System Settings › Privacy & Security."
    )
  }

  private func createController(for app: AudioApp, processObjectIDs: [AudioObjectID]) throws -> PerAppTapController {

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
      do {
        try withStatusCheck(
          AudioHardwareCreateProcessTap(tapDescription, &tapID),
          action: "create process tap"
        )
      } catch {
        throw error
      }

      let tapUID: String
      do {
        tapUID = try readTapUID(tapID)
      } catch {
        // Destroy the tap we just created so a UID-read failure does not leak it.
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw error
      }
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

      var aggregateID: AudioObjectID = .unknown
      do {
        try withStatusCheck(
          AudioHardwareCreateAggregateDevice(aggregateDeviceDescription as CFDictionary, &aggregateID),
          action: "create aggregate device"
        )
      } catch {
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw error
      }

      let tapFormat = readTapFormat(tapID)
      let controller = try PerAppTapController(
        appID: app.id,
        appName: app.displayName,
        targetProcessObjectIDs: processObjectIDs,
        tapID: tapID,
        aggregateDeviceID: aggregateID,
        volume: app.desiredVolume,
        volumeBoost: app.volumeBoost,
        muted: app.isMuted,
        tapFormat: tapFormat
      )

      do {
        try controller.start()
      } catch {
        controller.dispose()
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

    // macOS only assigns a Core Audio "process object" to a process once it has
    // actually engaged the audio subsystem — a process that has never produced
    // sound (a menu-bar utility, a CLI tool, a background helper) never gets
    // one, so this resolution fails every time, not just this once. That's the
    // common case in practice; a genuinely audio-capable app whose process
    // object isn't ready yet would normally succeed on retry (see
    // createControllerWithRetry). Say so plainly and point at the fix —
    // excluding it via the row's context menu — instead of a bare technical
    // error that looks identical for a real, recoverable failure.
    throw BackendError.managedRouteUnavailable(
      "\(app.displayName) doesn't appear to produce audio, so Waves can't create a managed route for it. "
        + "If this app never plays sound, right-click its row and choose “Exclude from Waves” to stop this warning."
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
    let deviceID = try currentDefaultOutputDeviceID()

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
    let uid = try currentDefaultOutputDeviceUID()
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
    guard supportsPerAppRouting else { return [] }
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
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].targetDeviceUID = uid

    // Force a rebuild so the route moves to the new device (process objects are
    // unchanged, so applyRoute alone would reuse the existing controller).
    if let existing = controllers.removeValue(forKey: snapshot.apps[index].id) {
      existing.dispose()
    }

    // Only (re)establish a managed route if the app already had one; otherwise
    // just record the preference for the next time it's managed.
    let app = snapshot.apps[index]
    let wasManaged = app.routingState == .managed || app.routingState == .live
    guard wasManaged else { return }

    // Re-resolve the row after the await (see setDesiredVolume): a concurrent
    // rebuild during applyRoute's suspension can replace `snapshot.apps`.
    do {
      try await applyRoute(for: app, toVolume: app.desiredVolume, muted: app.isMuted)
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].appliedVolume =
          snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
        snapshot.apps[index].notes = nil
      }
      refreshGlobalRouteHealth()
    } catch {
      if let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) {
        snapshot.apps[index].routingState = .error
        snapshot.apps[index].notes = error.localizedDescription
      }
      refreshGlobalRouteHealth(latestError: error.localizedDescription)
      throw error
    }
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

  private func readTapFormat(_ tapID: AudioObjectID) -> TapAudioFormat {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &asbdSize, &asbd)

    guard status == noErr else {
      return .fallback
    }

    if (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32 {
      return TapAudioFormat(streamDescription: asbd, sampleFormat: .float32)
    }

    if (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 {
      if asbd.mBitsPerChannel == 16 {
        return TapAudioFormat(streamDescription: asbd, sampleFormat: .int16)
      }
      if asbd.mBitsPerChannel == 32 {
        return TapAudioFormat(streamDescription: asbd, sampleFormat: .int32)
      }
    }

    return TapAudioFormat(streamDescription: asbd, sampleFormat: .unknown)
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
    disposeControllers(keeping: runningIDs)

    let hasRouteErrors = mergedApps.contains { $0.routingState == .error }
    // Mirror refreshGlobalRouteHealth: carry lastError forward only while some
    // app is still in .error, so surfaces never show a stale error message next
    // to an otherwise healthy status.
    let backendError = hasRouteErrors ? snapshot.backendStatus.lastError : nil
    let currentDevice = (try? currentOutputDevice())
      ?? previousSnapshot?.currentDevice
      ?? AudioDevice(
        id: "system-output",
        name: "System Output",
        kind: .unknown,
        isCurrent: true,
        isManagedRouteAvailable: supportsPerAppRouting
      )

    return AudioSessionSnapshot(
      apps: mergedApps,
      currentDevice: currentDevice,
      recentDeviceIDs: Array(Set((previousSnapshot?.recentDeviceIDs ?? []) + [currentDevice.id])).sorted(),
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
        isRouteRecoveryHealthy: supportsPerAppRouting && captureAuthorization == .authorized && !hasRouteErrors,
        lastError: backendError
      ),
      updatedAt: now
    )
  }

  func audioLevels() async -> [String: AudioLevels] {
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
    let targetIDs = snapshot.apps.filter { app in
      (bundleID != nil && app.bundleID == bundleID) || (app.pid != nil && app.pid == pid)
    }.map(\.id)

    guard !targetIDs.isEmpty else { return }

    for id in targetIDs {
      if let controller = controllers.removeValue(forKey: id) {
        controller.dispose()
      }
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

  private func disposeControllers(keeping appIDs: Set<String>) {
    let stale = Set(controllers.keys).subtracting(appIDs)
    for appID in stale {
      controllers[appID]?.dispose()
      controllers.removeValue(forKey: appID)
      staleRouteTicks.removeValue(forKey: appID)
    }
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

  /// Recompute the GLOBAL route-recovery health from the whole snapshot, mirroring
  /// buildSnapshot's formula. Health is healthy only when per-app routing is
  /// available, capture is authorized, and NO app is in `.error` — a single
  /// successful apply/reattach must never advertise the session as healthy while
  /// another app remains errored. `lastError` is cleared only when nothing is
  /// errored; otherwise the most recent error is preserved.
  private func refreshGlobalRouteHealth(latestError: String? = nil) {
    let hasRouteErrors = snapshot.apps.contains { $0.routingState == .error }
    snapshot.backendStatus.isRouteRecoveryHealthy =
      supportsPerAppRouting && captureAuthorization == .authorized && !hasRouteErrors
    if hasRouteErrors {
      // Keep an error message visible: prefer a freshly-observed one, otherwise
      // retain whatever the badge already shows.
      snapshot.backendStatus.lastError = latestError ?? snapshot.backendStatus.lastError
    } else {
      snapshot.backendStatus.lastError = nil
    }
  }

  private func reattachRoutes(forLogicalIDs logicalIDs: Set<String>) async {
    var lastError: String?

    // applyRoute suspends (tap-retry backoff) and the actor is reentrant, so a
    // concurrent refresh/buildSnapshot can replace `snapshot.apps` mid-loop.
    // Iterate by logicalID and re-resolve the row after every await — a stale
    // index would trap or write onto the wrong app. Rows that vanished are
    // skipped.
    let targetLogicalIDs = snapshot.apps.map(\.logicalID).filter { logicalIDs.contains($0) }
    for logicalID in targetLogicalIDs {
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
          snapshot.apps[index].routingState = .error
          snapshot.apps[index].notes = error.localizedDescription
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
    guard !controllers.isEmpty else { return }

    let appIndexMap = snapshot.apps.enumerated().reduce(into: [String: Int]()) { result, pair in
      result[pair.element.logicalID] = pair.offset
    }

    var routeIDsNeedingRebuild = Set<String>()

    for (appID, controller) in controllers {
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
    let managedIDs = snapshot.apps
      .filter { $0.routingState == .managed || forceRebuildIDs.contains($0.logicalID) || forceRebuildIDs.contains($0.id) }
      .map(\.logicalID)
    guard !managedIDs.isEmpty else { return }

    var changed = false
    var lastError: String?

    for appID in managedIDs {
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
          snapshot.apps[currentIndex].routingState = .error
          snapshot.apps[currentIndex].notes = error.localizedDescription
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
    // Avoid registering a second listener (and leaking the previous block) if
    // start() runs more than once.
    guard deviceChangeListenerToken == 0 else { return }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { [weak self] in
        await self?.handleDeviceChange()
      }
    }

    let status = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      listenerBlock
    )

    if status == noErr {
      deviceChangeListenerToken = 1
      deviceChangeListenerBlock = listenerBlock
    } else {
      logger.error("Failed to add device change listener: \(status)")
    }
  }

  private func removeDeviceChangeListener() {
    guard deviceChangeListenerToken != 0 else { return }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    guard let listenerBlock = deviceChangeListenerBlock else {
      deviceChangeListenerToken = 0
      return
    }

    _ = AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      DispatchQueue.main,
      listenerBlock
    )

    deviceChangeListenerToken = 0
    deviceChangeListenerBlock = nil
  }

  private func handleDeviceChange() async {
    // Always re-tap managed routes to the new device — this is core "per-app
    // control keeps working after you switch devices" functionality, not the
    // optional convenience the "Auto-restore device" preference describes
    // (restoring each device's *remembered volume level*, handled separately
    // by AppStore's preferences.autoRestoreDevice-gated restoreDeviceVolumePresets
    // calls). Skipping this on a real device change would silently leave every
    // previously-managed app's Core Audio taps disposed-and-not-reattached —
    // i.e. break per-app volume/mute control entirely — until the user noticed
    // and manually hit "Recover Routes."
    do {
      _ = try await autoRestoreDevice()
      logger.info("Output device changed, managed routes restored")
    } catch {
      refreshGlobalRouteHealth(latestError: error.localizedDescription)
      logger.error("Output device change recovery failed: \(error.localizedDescription)")
    }
    // Notify observers (the store) so they can refresh UI state and restore
    // per-device volume presets, regardless of whether restoration succeeded.
    deviceChangeContinuation.yield()
  }
}

/// Real Core Audio capture (TCC) authorization, as opposed to mere OS support.
enum CaptureAuthorization {
  case authorized
  case notGranted
  case undetermined
  case unsupported
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
}

private struct TapAudioFormat {
  var streamDescription: AudioStreamBasicDescription
  var sampleFormat: TapSampleFormat

  static var fallback: TapAudioFormat {
    TapAudioFormat(
      streamDescription: AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8,
        mFramesPerPacket: 1,
        mBytesPerFrame: 8,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
      ),
      sampleFormat: .float32
    )
  }
}

private final class TapRenderStateBox {
  let state: UnsafeMutablePointer<TapRenderState>
  private let stateLock = NSLock()
  private var stateBox = TapRenderState(volume: 1.0, volumeBoost: 1.0, isMuted: 0, isActive: 0, peakLevel: 0, rmsLevel: 0)

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

  func write(volume: Float, volumeBoost: Float, muted: Bool, isActive: UInt32, peakLevel: Float, rmsLevel: Float) {
    stateLock.lock()
    state.pointee.volume = volume
    state.pointee.volumeBoost = volumeBoost
    state.pointee.isMuted = muted ? 1 : 0
    state.pointee.isActive = isActive
    state.pointee.peakLevel = peakLevel
    state.pointee.rmsLevel = rmsLevel
    stateBox.volume = volume
    stateBox.volumeBoost = volumeBoost
    stateBox.isMuted = muted ? 1 : 0
    stateBox.isActive = isActive
    stateBox.peakLevel = peakLevel
    stateBox.rmsLevel = rmsLevel
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

  func writeLevels(peakLevel: Float, rmsLevel: Float) {
    // Invoked from the realtime IO render thread, which must never block. If the
    // lock is contended, skip this update — level meters are cosmetic and the
    // next render cycle will refresh them.
    guard stateLock.try() else { return }
    state.pointee.peakLevel = peakLevel
    state.pointee.rmsLevel = rmsLevel
    stateBox.peakLevel = peakLevel
    stateBox.rmsLevel = rmsLevel
    stateLock.unlock()
  }

  func readLevels() -> (peak: Float, rms: Float) {
    stateLock.lock()
    let levels = (state.pointee.peakLevel, state.pointee.rmsLevel)
    stateLock.unlock()
    return levels
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
  private let tapFormat: TapAudioFormat
  private let callbackQueue: DispatchQueue
  private let callbackQueueKey = DispatchSpecificKey<UUID>()
  private let callbackQueueToken = UUID()
  private var ioProcID: AudioDeviceIOProcID?
  private var didDispose = false

  init(
    appID: String,
    appName: String,
    targetProcessObjectIDs: [AudioObjectID],
    tapID: AudioObjectID,
    aggregateDeviceID: AudioObjectID,
    volume: Float,
    volumeBoost: Float,
    muted: Bool,
    tapFormat: TapAudioFormat
  ) throws {
    self.appID = appID
    self.appName = appName
    self.targetProcessObjectIDs = targetProcessObjectIDs
    self.tapID = tapID
    self.aggregateDeviceID = aggregateDeviceID
    self.tapFormat = tapFormat
    self.callbackQueue = DispatchQueue(label: "com.waves.backend.tap.\(appID)", qos: .userInitiated)
    let initialState = TapRenderState(volume: volume, volumeBoost: volumeBoost, isMuted: muted ? 1 : 0, isActive: 1, peakLevel: 0, rmsLevel: 0)
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

  func getCurrentLevels() -> (peak: Float, rms: Float) {
    stateBox.readLevels()
  }

  func start() throws {
    var procID: AudioDeviceIOProcID?
    let sampleFormat = tapFormat.sampleFormat

    let status = AudioDeviceCreateIOProcIDWithBlock(
      &procID,
      aggregateDeviceID,
      callbackQueue
    ) { _, inputData, _, outOutputData, _ in
      guard let currentState = self.stateBox.tryRead() else {
        self.zeroOutput(outOutputData)
        return
      }

      guard currentState.isActive != 0 else {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0)
        self.zeroOutput(outOutputData)
        return
      }

      if currentState.isMuted != 0 {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0)
        self.zeroOutput(outOutputData)
        return
      }

      let volume = currentState.volume
      let volumeBoost = currentState.volumeBoost
      if volume == 0.0 {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0)
        self.zeroOutput(outOutputData)
        return
      }

      self.renderTappedAudio(
        inputData,
        to: outOutputData,
        sampleFormat: sampleFormat,
        volume: volume,
        volumeBoost: volumeBoost
      )
    }

    if status != noErr {
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
      _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
      ioProcID = nil
      throw BackendError.managedRouteUnavailable(
        "Failed to start aggregate device for \(appName) (OSStatus: \(startStatus))."
      )
    }
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

  func invalidate() {
    guard ioProcID != nil else { return }

    guard aggregateDeviceID != .unknown else {
      ioProcID = nil
      return
    }

    guard let procID = ioProcID else { return }

    _ = AudioDeviceStop(aggregateDeviceID, procID)
    _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
    ioProcID = nil
    drainCallbackQueue()
  }

  func dispose() {
    guard !didDispose else { return }
    didDispose = true

    if let procID = ioProcID {
      _ = AudioDeviceStop(aggregateDeviceID, procID)
      _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
    }

    ioProcID = nil
    stateBox.setInactive()
    drainCallbackQueue()

    if aggregateDeviceID != .unknown {
      _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }

    if #available(macOS 14.2, *) {
      if tapID != .unknown {
        _ = AudioHardwareDestroyProcessTap(tapID)
      }
    }
  }

  deinit {
    dispose()
  }

  private func renderTappedAudio(
    _ inputData: UnsafePointer<AudioBufferList>?,
    to outputData: UnsafeMutablePointer<AudioBufferList>,
    sampleFormat: TapSampleFormat,
    volume: Float,
    volumeBoost: Float
  ) {
    guard let inputData else {
      zeroOutput(outputData)
      return
    }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

    var peak: Float = 0
    var sum: Float = 0
    var sampleCount: UInt32 = 0

    // Apply volume boost to the volume
    let effectiveVolume = volume * volumeBoost

    for index in outputBuffers.indices {
      let outputBuffer = outputBuffers[index]
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

      // Compute peak and RMS from the original input before scaling.
      let (bufferPeak, bufferSum, bufferSamples) = TapDSP.levels(
        from: inputPointer,
        byteCount: copyByteCount,
        format: sampleFormat
      )
      peak = max(peak, bufferPeak)
      sum += bufferSum
      sampleCount += bufferSamples

      TapDSP.scale(outputPointer, byteCount: copyByteCount, format: sampleFormat, gain: effectiveVolume)
    }

    stateBox.writeLevels(peakLevel: peak, rmsLevel: TapDSP.rms(sum: sum, sampleCount: sampleCount))
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
