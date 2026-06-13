import AppKit
import ApplicationServices
import AudioToolbox
import Foundation
import OSLog
import WavesAudioCore

actor WorkspaceAudioControlBackend: AudioControlBackend {
  // Start from a neutral, empty session. Using `.preview` here would seed the
  // live backend with fabricated apps, volumes, and a fake error string that
  // could surface before the first real snapshot is built.
  private var snapshot: AudioSessionSnapshot = .empty
  private var presets: [Preset]
  private let currentBundleID = Bundle.main.bundleIdentifier
  private var controllers: [String: PerAppTapController] = [:]
  private var levelUpdateTask: Task<Void, Never>?
  private var deviceChangeListenerToken: UInt32 = 0
  private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
  private let logger = Logger(subsystem: "com.waves.backend", category: "AudioBackend")

  nonisolated let deviceChangeEvents: AsyncStream<Void>
  private nonisolated let deviceChangeContinuation: AsyncStream<Void>.Continuation

  init(presets: [Preset] = Preset.defaults) {
    self.presets = presets
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

    // Validate volume: handle NaN and infinity
    guard volume.isFinite else {
      logger.warning("Invalid volume value for \(appID): \(volume), defaulting to 1.0")
      snapshot.apps[index].desiredVolume = 1.0
      return
    }

    let target = max(0.0, min(1.0, volume))
    snapshot.apps[index].desiredVolume = target

    do {
      try await applyRoute(for: snapshot.apps[index], toVolume: target, muted: snapshot.apps[index].isMuted)
      snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : target
      snapshot.apps[index].routingState = .managed
      snapshot.apps[index].notes = nil
      snapshot.backendStatus.lastError = nil
      snapshot.backendStatus.isRouteRecoveryHealthy = true
    } catch {
      snapshot.apps[index].routingState = .error
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.apps[index].appliedVolume = snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
      snapshot.backendStatus.lastError = error.localizedDescription
      snapshot.backendStatus.isRouteRecoveryHealthy = false
      throw error
    }
  }

  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isMuted = isMuted

    do {
      try await applyRoute(for: snapshot.apps[index], toVolume: snapshot.apps[index].desiredVolume, muted: isMuted)
      snapshot.apps[index].routingState = .managed
      snapshot.apps[index].peakLevel = isMuted ? 0 : max(0.0, snapshot.apps[index].peakLevel)
      snapshot.apps[index].rmsLevel = isMuted ? 0 : max(0.0, snapshot.apps[index].rmsLevel)
      snapshot.apps[index].appliedVolume = isMuted ? 0 : snapshot.apps[index].desiredVolume
      snapshot.apps[index].notes = nil
      snapshot.backendStatus.lastError = nil
      snapshot.backendStatus.isRouteRecoveryHealthy = true
    } catch {
      snapshot.apps[index].routingState = .error
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
      snapshot.apps[index].appliedVolume = isMuted ? 0 : snapshot.apps[index].desiredVolume
      snapshot.backendStatus.lastError = error.localizedDescription
      snapshot.backendStatus.isRouteRecoveryHealthy = false
      throw error
    }
  }

  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == appID || $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    let clampedBoost = max(1.0, min(4.0, boost))
    snapshot.apps[index].volumeBoost = clampedBoost

    // Update the controller if it exists
    if let controller = controllers[snapshot.apps[index].id] {
      controller.setVolumeBoost(clampedBoost)
    }

    // Re-apply the route with the new boost
    do {
      try await applyRoute(for: snapshot.apps[index], toVolume: snapshot.apps[index].desiredVolume, muted: snapshot.apps[index].isMuted)
      snapshot.apps[index].routingState = .managed
      snapshot.apps[index].notes = nil
      snapshot.backendStatus.lastError = nil
      snapshot.backendStatus.isRouteRecoveryHealthy = true
    } catch {
      snapshot.apps[index].routingState = .error
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.backendStatus.lastError = error.localizedDescription
      snapshot.backendStatus.isRouteRecoveryHealthy = false
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

  func applyPreset(_ preset: Preset) async throws -> AudioSessionSnapshot {
    for entry in preset.entries {
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) else {
        continue
      }

      snapshot.apps[index].desiredVolume = entry.desiredVolume
      snapshot.apps[index].isMuted = entry.isMuted
      snapshot.apps[index].volumeBoost = entry.volumeBoost

      do {
        try await applyRoute(
          for: snapshot.apps[index],
          toVolume: entry.desiredVolume,
          muted: entry.isMuted
        )
        snapshot.apps[index].appliedVolume = entry.isMuted ? 0 : entry.desiredVolume
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].notes = nil
      } catch {
        snapshot.apps[index].routingState = .error
        snapshot.apps[index].notes = error.localizedDescription
        snapshot.apps[index].appliedVolume = entry.isMuted ? 0 : entry.desiredVolume
        snapshot.backendStatus.lastError = error.localizedDescription
        snapshot.backendStatus.isRouteRecoveryHealthy = false
      }
    }

    snapshot.updatedAt = .now
    return snapshot
  }

  func saveCurrentPreset(named name: String) async throws -> Preset {
    let preset = Preset(
      name: name,
      entries: snapshot.apps.map {
        PresetEntry(
          appID: $0.logicalID,
          desiredVolume: $0.desiredVolume,
          isMuted: $0.isMuted,
          volumeBoost: $0.volumeBoost
        )
      }
    )
    presets.append(preset)
    return preset
  }

  func recoverRoutes() async throws -> AudioSessionSnapshot {
    let managedLogicalIDs = Set(
      snapshot.apps
        .filter { $0.routingState == .managed || controllers[$0.id]?.isActive == true }
        .map(\.logicalID)
    )

    disposeControllers(keeping: [])
    snapshot.backendStatus.isRouteRecoveryHealthy = true
    snapshot.backendStatus.lastError = nil
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
    DiagnosticsReport(
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
          status: snapshot.backendStatus.isRouteRecoveryHealthy ? .passed : .warning,
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

  private func applyRoute(for app: AudioApp, toVolume volume: Float, muted: Bool) async throws {
    guard supportsPerAppRouting else {
      throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
    }

    let processObjectIDs = try resolveProcessObjectIDs(for: app)

    if let controller = controllers[app.id], controller.isActive, controller.matches(processObjectIDs) {
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

          // Re-resolve process object IDs in case they changed
          let refreshedProcessObjectIDs = try resolveProcessObjectIDs(for: app)
          if refreshedProcessObjectIDs != currentProcessObjectIDs {
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
    }

    if let pid = app.pid {
      candidatePIDs.insert(pid)
    }

    let processObjectIDs = try candidatePIDs
      .compactMap { pid -> AudioObjectID? in
        guard let processObjectID = try translateProcessID(forPID: pid), processObjectID != .unknown else {
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

    throw BackendError.managedRouteUnavailable(
      "Unable to resolve active Core Audio process objects for \(app.displayName)."
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
      if kind == .aggregate, name.lowercased().contains("waves") { continue }
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

    do {
      try await applyRoute(for: app, toVolume: app.desiredVolume, muted: app.isMuted)
      snapshot.apps[index].routingState = .managed
      snapshot.apps[index].appliedVolume = app.isMuted ? 0 : app.desiredVolume
      snapshot.apps[index].notes = nil
      snapshot.backendStatus.lastError = nil
    } catch {
      snapshot.apps[index].routingState = .error
      snapshot.apps[index].notes = error.localizedDescription
      snapshot.backendStatus.lastError = error.localizedDescription
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

  private func getAudibleProcessPIDs() -> Set<pid_t> {
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
      return Set<pid_t>()
    }

    let processObjectCount = Int(size) / MemoryLayout<AudioObjectID>.size
    guard processObjectCount > 0 else {
      return Set<pid_t>()
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
      return Set<pid_t>()
    }

    var audiblePIDs = Set<pid_t>()
    for processObjectID in processObjectIDs where processObjectID != .unknown {
      guard isProcessRunningOutput(processObjectID) else { continue }
      if let pid = readProcessPID(processObjectID) {
        audiblePIDs.insert(pid)
      }
    }

    return audiblePIDs
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
    let audiblePIDs = getAudibleProcessPIDs()
    let runningApps = await Task.detached { [currentBundleID, audiblePIDs] in
      Self.discoverRunningApps(currentBundleID: currentBundleID, audiblePIDs: audiblePIDs)
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
      } else {
        retained.routingState = .monitorOnly
      }
      retained.notes = nil
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
      } else {
        mergedApps[index].routingState = RoutingState.monitorOnly
        mergedApps[index].notes = nil
      }
    }

    let runningIDs: Set<String> = Set(mergedApps.map(\.id))
    disposeControllers(keeping: runningIDs)

    let backendError = snapshot.backendStatus.lastError
    let hasRouteErrors = mergedApps.contains { $0.routingState == .error }
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

  func releaseControllers(forBundleID bundleID: String?, pid: Int32) async {
    let targetIDs = snapshot.apps.filter { app in
      (bundleID != nil && app.bundleID == bundleID) || (app.pid != nil && app.pid == pid)
    }.map(\.id)

    guard !targetIDs.isEmpty else { return }

    for id in targetIDs {
      if let controller = controllers.removeValue(forKey: id) {
        controller.dispose()
      }
    }

    for index in snapshot.apps.indices where targetIDs.contains(snapshot.apps[index].id) {
      snapshot.apps[index].routingState = .monitorOnly
      snapshot.apps[index].isActive = false
      snapshot.apps[index].appliedVolume = nil
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
    }
  }

  private func disposeControllers(keeping appIDs: Set<String>) {
    let stale = Set(controllers.keys).subtracting(appIDs)
    for appID in stale {
      controllers[appID]?.dispose()
      controllers.removeValue(forKey: appID)
    }
  }

  private static func discoverRunningApps(currentBundleID: String?, audiblePIDs: Set<pid_t>) -> [AudioApp] {
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
        let isAudible = !audiblePIDs.isEmpty && !familyPIDs.isDisjoint(with: audiblePIDs)
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

  private func reattachRoutes(forLogicalIDs logicalIDs: Set<String>) async {
    var recoveredAnyRoute = false
    var lastError: String?

    for index in snapshot.apps.indices {
      guard logicalIDs.contains(snapshot.apps[index].logicalID) else { continue }

      do {
        try await applyRoute(
          for: snapshot.apps[index],
          toVolume: snapshot.apps[index].desiredVolume,
          muted: snapshot.apps[index].isMuted
        )
        snapshot.apps[index].routingState = .managed
        snapshot.apps[index].appliedVolume =
          snapshot.apps[index].isMuted ? 0 : snapshot.apps[index].desiredVolume
        snapshot.apps[index].notes = nil
        recoveredAnyRoute = true
      } catch {
        snapshot.apps[index].routingState = .error
        snapshot.apps[index].notes = error.localizedDescription
        lastError = error.localizedDescription
      }
    }

    snapshot.backendStatus.isRouteRecoveryHealthy = recoveredAnyRoute
    snapshot.backendStatus.lastError = lastError
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

    for (appID, controller) in controllers {
      guard controller.isActive else { continue }

      let (peak, rms) = controller.getCurrentLevels()

      if let index = appIndexMap[appID] ?? snapshot.apps.firstIndex(where: { $0.id == appID }) {
        snapshot.apps[index].peakLevel = peak
        snapshot.apps[index].rmsLevel = rms
      }
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
    do {
      _ = try await autoRestoreDevice()
      logger.info("Output device changed, managed routes restored")
    } catch {
      snapshot.backendStatus.isRouteRecoveryHealthy = false
      snapshot.backendStatus.lastError = error.localizedDescription
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
        self.zeroOutput(outOutputData)
        return
      }

      if currentState.isMuted != 0 {
        self.zeroOutput(outOutputData)
        return
      }

      let volume = currentState.volume
      let volumeBoost = currentState.volumeBoost
      if volume == 0.0 {
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
