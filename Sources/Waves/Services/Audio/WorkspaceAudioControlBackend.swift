import AppKit
import AudioToolbox
import Foundation
import WavesAudioCore

actor WorkspaceAudioControlBackend: AudioControlBackend {
  private var snapshot: AudioSessionSnapshot = .preview
  private var presets: [Preset]
  private let currentBundleID = Bundle.main.bundleIdentifier
  private var controllers: [String: PerAppTapController] = [:]

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
  }

  func applyPreset(_ preset: Preset) async throws -> AudioSessionSnapshot {
    for entry in preset.entries {
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) else {
        continue
      }

      snapshot.apps[index].desiredVolume = entry.desiredVolume
      snapshot.apps[index].isMuted = entry.isMuted

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
      reattachRoutes(forLogicalIDs: managedLogicalIDs)
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

    let processObjectIDs = try resolveProcessObjectIDs(for: app)

    if let controller = controllers[app.id], controller.isActive, controller.matches(processObjectIDs) {
      controller.apply(volume: volume, muted: muted)
      return
    }

    if let existing = controllers[app.id] {
      existing.invalidate()
      controllers.removeValue(forKey: app.id)
    }

    let controller = try createController(for: app, processObjectIDs: processObjectIDs)
    controllers[app.id] = controller
    controller.apply(volume: volume, muted: muted)
  }

  private func createController(for app: AudioApp, processObjectIDs: [AudioObjectID]) throws -> PerAppTapController {

    if #available(macOS 14.2, *) {
      let defaultOutputDeviceUID = try currentDefaultOutputDeviceUID()

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

      let tapUID = try readTapUID(tapID)
      let aggregateDeviceDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Waves-\(app.displayName)",
        kAudioAggregateDeviceUIDKey: "com.waves.aggregate.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: defaultOutputDeviceUID,
        kAudioAggregateDeviceClockDeviceKey: defaultOutputDeviceUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
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
          Self.bundleFamilyMatches(appBundleID: bundleID, candidateBundleID: runningApp.bundleIdentifier)
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
    let runningApps = await Task.detached { [currentBundleID] in
      Self.discoverRunningApps(currentBundleID: currentBundleID)
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
      return app
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
      } else {
        mergedApps[index].routingState = RoutingState.monitorOnly
        mergedApps[index].notes = nil
      }
    }

    let runningIDs: Set<String> = Set(mergedApps.map(\.id))
    disposeControllers(keeping: runningIDs)

    let backendError = snapshot.backendStatus.lastError
    let hasRouteErrors = mergedApps.contains { $0.routingState == .error }
    let managedCount = mergedApps.filter { $0.routingState == .managed }.count

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
        isRouteRecoveryHealthy: supportsPerAppRouting && !hasRouteErrors && managedCount > 0,
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

  private static func discoverRunningApps(currentBundleID: String?) -> [AudioApp] {
    let candidateApps = NSWorkspace.shared.runningApplications
      .filter { app in
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        guard app.activationPolicy != .prohibited else { return false }
        guard let localizedName = app.localizedName, !localizedName.isEmpty else { return false }
        guard app.bundleIdentifier != currentBundleID else { return false }
        guard Self.isManageableApp(named: localizedName, bundleID: app.bundleIdentifier) else { return false }
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
          id: logicalID,
          logicalID: logicalID,
          pid: pid,
          bundleID: bundleID,
          displayName: name,
          iconName: Self.iconName(for: category),
          iconTIFFData: nil,
          category: category,
          isActive: app.isActive,
          peakLevel: 0,
          rmsLevel: 0,
          desiredVolume: 1,
          appliedVolume: 1,
          isMuted: false,
          isPinned: false,
          routingState: .monitorOnly,
          compatibility: .supported,
          notes: nil
        )
      }
  }

  private func dictionaryByLogicalID(_ apps: [AudioApp]) -> [String: AudioApp] {
    apps.reduce(into: [:]) { result, app in
      result[app.logicalID] = app
    }
  }

  private static func logicalAppID(bundleID: String?, displayName: String, pid: Int32? = nil) -> String {
    let normalizedName = normalizedProcessName(displayName)

    if let bundleID, !bundleID.isEmpty {
      if isCompanionAudioProcess(named: displayName, bundleID: bundleID) {
        if let pid {
          return "\(bundleID)::\(normalizedName)::pid-\(pid)"
        }
        return "\(bundleID)::\(normalizedName)"
      }
      return bundleID
    }

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

  private static func normalizedProcessName(_ displayName: String) -> String {
    displayName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9]+"#,
        with: "-",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private static func isManageableApp(named displayName: String, bundleID: String?) -> Bool {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()

    let excludedMarkers = [
      "daemon",
      "updater",
      "launcher",
      "agent",
      "service",
      "crashpad",
      "login item",
      "xpc",
      "helper",
      "web content",
      "networking",
      "graphics and media",
      "isolated",
      "renderer",
      "gpu",
      "utility process",
      "plugincontainer",
      "content synchronizer",
      "extension helper",
    ]

    if excludedMarkers.contains(where: { token.contains($0) }) {
      return false
    }

    return true
  }

  private static func isCompanionAudioProcess(named displayName: String, bundleID: String?) -> Bool {
    let token = [bundleID ?? "", displayName].joined(separator: " ").lowercased()
    let companionMarkers = [
      "helper",
      "web content",
      "networking",
      "graphics and media",
      "isolated",
      "renderer",
      "gpu",
      "utility process",
      "plugincontainer",
      "content synchronizer",
      "extension helper",
    ]

    return companionMarkers.contains(where: { token.contains($0) })
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

    if let localizedName = app.localizedName,
      !isCompanionAudioProcess(named: localizedName, bundleID: app.bundleIdentifier)
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

  private static func bundleFamilyMatches(appBundleID: String, candidateBundleID: String?) -> Bool {
    guard let candidateBundleID, !candidateBundleID.isEmpty else { return false }
    if candidateBundleID == appBundleID {
      return true
    }
    return candidateBundleID.hasPrefix(appBundleID + ".")
  }

  private func withStatusCheck(_ status: OSStatus, action: String) throws {
    if status != noErr {
      throw BackendError.managedRouteUnavailable("\(action) failed (OSStatus: \(status)).")
    }
  }

  private func reattachRoutes(forLogicalIDs logicalIDs: Set<String>) {
    var recoveredAnyRoute = false
    var lastError: String?

    for index in snapshot.apps.indices {
      guard logicalIDs.contains(snapshot.apps[index].logicalID) else { continue }

      do {
        try applyRoute(
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
}

private extension AudioObjectID {
  static let unknown = AudioObjectID(kAudioObjectUnknown)
}

private struct TapRenderState {
  var volume: Float
  var isMuted: UInt32
  var isActive: UInt32
}

private enum TapSampleFormat {
  case float32
  case int16
  case int32
  case unknown
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

private final class PerAppTapController {
  let appID: String
  let appName: String
  let targetProcessObjectIDs: [AudioObjectID]
  let tapID: AudioObjectID
  let aggregateDeviceID: AudioObjectID

  private let state: UnsafeMutablePointer<TapRenderState>
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
    state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
    state.pointee = TapRenderState(volume: volume, isMuted: muted ? 1 : 0, isActive: 1)
    self.callbackQueue.setSpecific(key: callbackQueueKey, value: callbackQueueToken)
  }

  var isActive: Bool {
    state.pointee.isActive != 0 && ioProcID != nil && aggregateDeviceID != .unknown
  }

  func matches(_ processObjectIDs: [AudioObjectID]) -> Bool {
    targetProcessObjectIDs == processObjectIDs
  }

  func apply(volume: Float, muted: Bool) {
    state.pointee.volume = max(0.0, min(1.0, volume))
    state.pointee.isMuted = muted ? 1 : 0
  }

  func start() throws {
    var procID: AudioDeviceIOProcID?
    let statePointer = state
    let sampleFormat = tapFormat.sampleFormat

    let status = AudioDeviceCreateIOProcIDWithBlock(
      &procID,
      aggregateDeviceID,
      callbackQueue
    ) { _, inputData, _, outOutputData, _ in
      let currentState = statePointer.pointee
      guard currentState.isActive != 0 else {
        self.zeroOutput(outOutputData)
        return
      }

      if currentState.isMuted != 0 {
        self.zeroOutput(outOutputData)
        return
      }

      let volume = currentState.volume
      if volume == 0.0 {
        self.zeroOutput(outOutputData)
        return
      }

      self.renderTappedAudio(
        inputData,
        to: outOutputData,
        sampleFormat: sampleFormat,
        volume: volume
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
    state.pointee.isActive = 0
    drainCallbackQueue()

    if aggregateDeviceID != .unknown {
      _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }

    if #available(macOS 14.2, *) {
      if tapID != .unknown {
        _ = AudioHardwareDestroyProcessTap(tapID)
      }
    }

    state.deinitialize(count: 1)
    state.deallocate()
  }

    deinit {
    dispose()
  }

  private static func scaleSigned16(_ sample: Int16, volume: Float) -> Int16 {
    let scaled = Float(sample) * volume
    if scaled >= Float(Int16.max) {
      return Int16.max
    }
    if scaled <= Float(Int16.min) {
      return Int16.min
    }

    return Int16(scaled.rounded())
  }

  private static func scaleSigned32(_ sample: Int32, volume: Float) -> Int32 {
    let scaled = Float(sample) * volume
    if scaled >= Float(Int32.max) {
      return Int32.max
    }
    if scaled <= Float(Int32.min) {
      return Int32.min
    }

    return Int32(scaled.rounded())
  }

  private func renderTappedAudio(
    _ inputData: UnsafePointer<AudioBufferList>?,
    to outputData: UnsafeMutablePointer<AudioBufferList>,
    sampleFormat: TapSampleFormat,
    volume: Float
  ) {
    guard let inputData else {
      zeroOutput(outputData)
      return
    }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

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

      scaleOutput(outputPointer, byteCount: copyByteCount, sampleFormat: sampleFormat, volume: volume)
    }
  }

  private func scaleOutput(
    _ data: UnsafeMutableRawPointer,
    byteCount: Int,
    sampleFormat: TapSampleFormat,
    volume: Float
  ) {
    guard volume != 1.0 else { return }

    switch sampleFormat {
    case .float32:
      let typedPointer = data.assumingMemoryBound(to: Float.self)
      let sampleTotal = byteCount / MemoryLayout<Float>.size
      for index in 0..<sampleTotal {
        typedPointer[index] *= volume
      }
    case .int16:
      let typedPointer = data.assumingMemoryBound(to: Int16.self)
      let sampleTotal = byteCount / MemoryLayout<Int16>.size
      for index in 0..<sampleTotal {
        typedPointer[index] = Self.scaleSigned16(typedPointer[index], volume: volume)
      }
    case .int32:
      let typedPointer = data.assumingMemoryBound(to: Int32.self)
      let sampleTotal = byteCount / MemoryLayout<Int32>.size
      for index in 0..<sampleTotal {
        typedPointer[index] = Self.scaleSigned32(typedPointer[index], volume: volume)
      }
    case .unknown:
      break
    }
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

