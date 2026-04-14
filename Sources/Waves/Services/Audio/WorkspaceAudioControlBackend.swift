import AppKit
import AudioToolbox
import Foundation
import WavesAudioCore

actor WorkspaceAudioControlBackend: AudioControlBackend {
  private var snapshot: AudioSessionSnapshot = .preview
  private var presets: [Preset]
  private let currentBundleID = Bundle.main.bundleIdentifier
  private var controllers: [String: PerAppTapController] = [:]
  private let callbackQueue = DispatchQueue(label: "com.waves.backend.tap", qos: .userInitiated)

  init(presets: [Preset] = Preset.defaults) {
    self.presets = presets
  }

  func start() async throws {
    snapshot = await buildSnapshot(merging: snapshot)
  }

  func stop() async {
    disposeControllers(keeping: [])
  }

  func currentSnapshot() async -> AudioSessionSnapshot {
    snapshot
  }

  func refresh() async throws -> AudioSessionSnapshot {
    snapshot = await buildSnapshot(merging: snapshot)
    return snapshot
  }

  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    let target = max(0.0, min(1.0, volume))
    snapshot.apps[index].desiredVolume = target
    snapshot.apps[index].lastSeenAt = .now

    do {
      try applyRoute(for: snapshot.apps[index], toVolume: target, muted: snapshot.apps[index].isMuted)
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
    guard let index = snapshot.apps.firstIndex(where: { $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isMuted = isMuted
    snapshot.apps[index].lastSeenAt = .now

    do {
      try applyRoute(for: snapshot.apps[index], toVolume: snapshot.apps[index].desiredVolume, muted: isMuted)
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

  func pinApp(_ isPinned: Bool, appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(where: { $0.id == appID }) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isPinned = isPinned
    snapshot.apps[index].lastSeenAt = .now
  }

  func applyPreset(_ preset: Preset) async throws -> AudioSessionSnapshot {
    for entry in preset.entries {
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) else {
        continue
      }

      snapshot.apps[index].desiredVolume = entry.desiredVolume
      snapshot.apps[index].isMuted = entry.isMuted
      snapshot.apps[index].lastSeenAt = .now

      do {
        try applyRoute(
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
        PresetEntry(appID: $0.logicalID, desiredVolume: $0.desiredVolume, isMuted: $0.isMuted)
      }
    )
    presets.append(preset)
    return preset
  }

  func recoverRoutes() async throws -> AudioSessionSnapshot {
    disposeControllers(keeping: [])
    snapshot.backendStatus.isRouteRecoveryHealthy = true
    snapshot.backendStatus.lastError = nil
    snapshot = await buildSnapshot(merging: snapshot)
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

  private func applyRoute(for app: AudioApp, toVolume volume: Float, muted: Bool) throws {
    guard supportsPerAppRouting else {
      throw BackendError.unsupportedOperation("Per-app routing requires macOS 14.2 or newer.")
    }

    if let controller = controllers[app.id], controller.isActive {
      controller.apply(volume: volume, muted: muted)
      return
    }

    if let existing = controllers[app.id] {
      existing.invalidate()
      controllers.removeValue(forKey: app.id)
    }

    let controller = try createController(for: app)
    controllers[app.id] = controller
    controller.apply(volume: volume, muted: muted)
  }

  private func createController(for app: AudioApp) throws -> PerAppTapController {
    guard let pid = app.pid else {
      throw BackendError.unsupportedOperation("App \(app.displayName) has no process identifier.")
    }

    guard let processObjectID = try translateProcessID(forPID: pid), processObjectID != .unknown else {
      throw BackendError.managedRouteUnavailable(
        "Unable to resolve Core Audio process object for \(app.displayName)."
      )
    }

    let defaultOutputDeviceUID = try currentDefaultOutputDeviceUID()

    let tapDescription = CATapDescription(processes: [NSNumber(value: processObjectID)])
    tapDescription.name = "Waves-\(app.displayName)"
    tapDescription.uuid = UUID()
    tapDescription.muteBehavior = .mutedWhenTapped
    tapDescription.isPrivate = true

    var tapID: AudioObjectID = .unknown
    try withStatusCheck(
      AudioHardwareCreateProcessTap(tapDescription, &tapID),
      action: "create process tap"
    )

    let aggregateDeviceDescription: [CFString: Any] = [
      kAudioAggregateDeviceNameKey: "Waves-\(app.displayName)",
      kAudioAggregateDeviceUIDKey: "com.waves.aggregate.\(UUID().uuidString)",
      kAudioAggregateDeviceMainSubDeviceKey: defaultOutputDeviceUID,
      kAudioAggregateDeviceClockDeviceKey: defaultOutputDeviceUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: true,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [
        [
          kAudioSubDeviceUIDKey: defaultOutputDeviceUID,
          kAudioSubDeviceDriftCompensationKey: false,
        ],
      ],
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapDriftCompensationKey: true,
          kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
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
      throw
    }

    let isFloatFormat = readTapFormatIsFloat(tapID)
    let controller = PerAppTapController(
      appID: app.id,
      appName: app.displayName,
      tapID: tapID,
      aggregateDeviceID: aggregateID,
      volume: app.desiredVolume,
      muted: app.isMuted,
      floatFormat: isFloatFormat,
      callbackQueue: callbackQueue
    )

    do {
      try controller.start()
    } catch {
      controller.dispose()
      throw
    }

    return controller
  }

  private func currentDefaultOutputDeviceUID() throws -> String {
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

    var rawUID: CFString = "" as CFString
    try withStatusCheck(
      AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &rawUID),
      action: "read default output uid"
    )

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

    return processObjectID == .unknown ? nil : processObjectID
  }

  private func readTapFormatIsFloat(_ tapID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &asbdSize, &asbd)

    guard status == noErr else {
      return true
    }

    return (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
  }

  private func buildSnapshot(merging previousSnapshot: AudioSessionSnapshot?) async -> AudioSessionSnapshot {
    let runningApps = await MainActor.run { discoverRunningApps() }
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
      return app
    }

    for index in mergedApps.indices {
      if !supportsPerAppRouting {
        mergedApps[index].routingState = .monitorOnly
        mergedApps[index].notes = "Per-app route requires macOS 14.2+"
        mergedApps[index].compatibility = .planned
        continue
      }

      if let controller = controllers[mergedApps[index].id], controller.isActive {
        mergedApps[index].routingState = .managed
        mergedApps[index].appliedVolume = mergedApps[index].isMuted ? 0 : mergedApps[index].appliedVolume
        mergedApps[index].notes = nil
      } else {
        mergedApps[index].routingState = .monitorOnly
        mergedApps[index].notes = nil
      }
    }

    let runningIDs = Set(mergedApps.map(\.$id))
    disposeControllers(keeping: runningIDs)

    let backendError = snapshot.backendStatus.lastError

    return AudioSessionSnapshot(
      apps: mergedApps,
      currentDevice: previousSnapshot?.currentDevice
        ?? AudioDevice(
          id: "system-output",
          name: "System Output",
          kind: .builtInOutput,
          isCurrent: true,
          isManagedRouteAvailable: supportsPerAppRouting
        ),
      recentDeviceIDs: previousSnapshot?.recentDeviceIDs ?? ["system-output"],
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
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: !supportsPerAppRouting ? false : snapshot.backendStatus.isRouteRecoveryHealthy,
        lastError: backendError
      ),
      updatedAt: now
    )
  }

  private func disposeControllers(keeping appIDs: Set<String>) {
    let stale = Set(controllers.keys).subtracting(appIDs)
    for appID in stale {
      controllers[appID]?.dispose()
      controllers.removeValue(forKey: appID)
    }
  }

  @MainActor
  private func discoverRunningApps() -> [AudioApp] {
    let candidateApps = NSWorkspace.shared.runningApplications
      .filter { app in
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        guard app.activationPolicy != .prohibited else { return false }
        guard let localizedName = app.localizedName, !localizedName.isEmpty else { return false }
        guard app.bundleIdentifier != currentBundleID else { return false }
        guard Self.isUserFacingApp(named: localizedName, bundleID: app.bundleIdentifier) else { return false }
        return true
      }
      .sorted {
        ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
      }

    var representativesByLogicalID: [String: NSRunningApplication] = [:]
    for app in candidateApps {
      let logicalID = Self.logicalAppID(bundleID: app.bundleIdentifier, displayName: app.localizedName ?? "")
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
        let logicalID = Self.logicalAppID(bundleID: bundleID, displayName: name)
        let category = Self.inferCategory(bundleID: bundleID, displayName: name)
        let pid = app.processIdentifier

        return AudioApp(
          id: Self.runtimeAppID(logicalID: logicalID, pid: pid),
          logicalID: logicalID,
          pid: pid,
          bundleID: bundleID,
          displayName: name,
          iconName: Self.iconName(for: category),
          iconTIFFData: app.icon?.tiffRepresentation,
          category: category,
          isActive: app.isActive,
          isAudible: false,
          peakLevel: 0,
          rmsLevel: 0,
          desiredVolume: 1,
          appliedVolume: 1,
          isMuted: false,
          isPinned: false,
          routingState: .monitorOnly,
          compatibility: .supported,
          lastSeenAt: .now,
          notes: nil
        )
      }
  }

  private func dictionaryByLogicalID(_ apps: [AudioApp]) -> [String: AudioApp] {
    apps.reduce(into: [:]) { result, app in
      result[app.logicalID] = app
    }
  }

  private static func logicalAppID(bundleID: String?, displayName: String) -> String {
    if let bundleID, !bundleID.isEmpty {
      return bundleID
    }

    let normalizedName = displayName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9]+"#,
        with: "-",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return normalizedName.isEmpty ? "unknown-app" : "name-\(normalizedName)"
  }

  private static func runtimeAppID(logicalID: String, pid: Int32) -> String {
    "\(logicalID)#\(pid)"
  }

  private static func inferCategory(bundleID: String?, displayName: String) -> AppCategory {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()

    if token.contains("safari") || token.contains("chrome") || token.contains("firefox")
      || token.contains("arc") || token.contains("browser")
    {
      return .browser
    }

    if token.contains("zoom") || token.contains("meet") || token.contains("teams")
      || token.contains("webex") || token.contains("facetime")
    {
      return .conferencing
    }

    if token.contains("spotify") || token.contains("music") || token.contains("vlc")
      || token.contains("podcast") || token.contains("tv")
    {
      return .media
    }

    if token.contains("discord") || token.contains("slack") || token.contains("messages")
      || token.contains("telegram")
    {
      return .communication
    }

    if token.hasPrefix("com.apple.") {
      return .system
    }

    return .unknown
  }

  private static func isUserFacingApp(named displayName: String, bundleID: String?) -> Bool {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()

    let excludedMarkers = [
      "helper",
      "daemon",
      "updater",
      "launcher",
      "agent",
      "service",
      "web content",
      "networking",
      "graphics and media",
      "isolated",
      "renderer",
      "gpu",
      "utility process",
      "plugincontainer",
      "xpc",
    ]

    if excludedMarkers.contains(where: { token.contains($0) }) {
      let keepIfLikelyRealApp = inferCategory(bundleID: bundleID, displayName: displayName) != .unknown
      return keepIfLikelyRealApp
    }

    return true
  }

  private static func preferredRepresentative(
    current: NSRunningApplication,
    candidate: NSRunningApplication
  ) -> NSRunningApplication {
    score(candidate) >= score(current) ? candidate : current
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

    if ["helper", "web content", "networking", "graphics and media", "isolated", "renderer", "gpu", "utility process", "plugincontainer", "xpc"]
      .contains(where: { token.contains($0) })
    {
      value -= 6
    }

    return value
  }

  private static func iconName(for category: AppCategory) -> String {
    switch category {
    case .browser:
      return "globe"
    case .conferencing:
      return "video.fill"
    case .media:
      return "music.note"
    case .communication:
      return "bubble.left.and.bubble.right.fill"
    case .system:
      return "gearshape.fill"
    case .unknown:
      return "app.fill"
    }
  }

  private func withStatusCheck(_ status: OSStatus, action: String) throws {
    if status != noErr {
      throw BackendError.managedRouteUnavailable("\(action) failed (OSStatus: \(status)).")
    }
  }
}

private extension AudioObjectID {
  static let unknown = AudioObjectID(kAudioObjectUnknown)
}

private struct TapRenderState {
  var volume: Float
  var isMuted: UInt32
  var isActive: UInt32
}

private final class PerAppTapController {
  let appID: String
  let appName: String
  let tapID: AudioObjectID
  let aggregateDeviceID: AudioObjectID

  private let state: UnsafeMutablePointer<TapRenderState>
  private let floatFormat: Bool
  private let callbackQueue: DispatchQueue
  private let stateAccessQueue = DispatchQueue(label: "com.waves.backend.tap.state")
  private var ioProcID: AudioDeviceIOProcID?
  private var didDispose = false

  init(
    appID: String,
    appName: String,
    tapID: AudioObjectID,
    aggregateDeviceID: AudioObjectID,
    volume: Float,
    muted: Bool,
    floatFormat: Bool,
    callbackQueue: DispatchQueue
  ) {
    self.appID = appID
    self.appName = appName
    self.tapID = tapID
    self.aggregateDeviceID = aggregateDeviceID
    self.floatFormat = floatFormat
    self.callbackQueue = callbackQueue
    state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
    state.pointee = TapRenderState(volume: volume, isMuted: muted ? 1 : 0, isActive: 1)
  }

  var isActive: Bool {
    stateAccessQueue.sync {
      state.pointee.isActive != 0 && ioProcID != nil && aggregateDeviceID != .unknown
    }
  }

  func apply(volume: Float, muted: Bool) {
    stateAccessQueue.sync {
      state.pointee.volume = max(0.0, min(1.0, volume))
      state.pointee.isMuted = muted ? 1 : 0
    }
  }

  func start() throws {
    var procID: AudioDeviceIOProcID?
    let floatFormat = floatFormat
    let statePointer = state
    let stateAccessQueue = stateAccessQueue

    let status = AudioDeviceCreateIOProcIDWithBlock(
      &procID,
      aggregateDeviceID,
      callbackQueue
    ) { _, _, _, outOutputData, _ in
      let currentState = stateAccessQueue.sync { statePointer.pointee }
      guard currentState.isActive != 0 else {
        zeroOutput(outOutputData)
        return
      }

      if currentState.isMuted != 0 {
        zeroOutput(outOutputData)
        return
      }

      let volume = currentState.volume
      let isFloat = floatFormat
      if !isFloat || volume == 0.0 {
        zeroOutput(outOutputData)
        return
      }

      let buffers = UnsafeMutableAudioBufferListPointer(outOutputData)
      for buffer in buffers {
        guard let data = buffer.mData else { continue }
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard sampleCount > 0 else { continue }

        let floats = data.assumingMemoryBound(to: Float.self)
        for index in 0..<sampleCount {
          floats[index] *= volume
        }
      }
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

    let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
    if startStatus != noErr {
      _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
      ioProcID = nil
      throw BackendError.managedRouteUnavailable(
        "Failed to start aggregate device for \(appName) (OSStatus: \(startStatus))."
      )
    }
  }

  func invalidate() {
    guard ioProcID != nil else { return }

    guard aggregateDeviceID != .unknown else {
      ioProcID = nil
      return
    }

    guard let procID else { return }

    _ = AudioDeviceStop(aggregateDeviceID, procID)
    _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
    ioProcID = nil
  }

  func dispose() {
    guard !didDispose else { return }
    didDispose = true

    if let procID {
      _ = AudioDeviceStop(aggregateDeviceID, procID)
      _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
    }

    ioProcID = nil
    state.pointee.isActive = 0

    if aggregateDeviceID != .unknown {
      _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }

    if tapID != .unknown {
      _ = AudioHardwareDestroyProcessTap(tapID)
    }

    state.deinitialize(count: 1)
    state.deallocate()
  }

  deinit {
    dispose()
  }

  private func zeroOutput(_ outOutputData: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(outOutputData)
    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
  }
}
