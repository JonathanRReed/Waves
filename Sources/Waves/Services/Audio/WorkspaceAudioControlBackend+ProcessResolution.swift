import AppKit
import AudioToolbox
import Darwin
import Foundation
import WavesAudioCore

// MARK: - Process, tap, and format resolution
//
// Core Audio object IDs and PIDs can go stale between enumeration and use;
// everything here treats a vanished object as ordinary lifecycle, not a fault.

extension WorkspaceAudioControlBackend {
  func resolveProcessTarget(for app: AudioApp) throws -> ResolvedProcessTarget {
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

  func revalidateProcessTarget(
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

  func readTapUID(_ tapID: AudioObjectID) throws -> String {
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

  func getAudibleProcesses() -> AudibleProcessIndex {
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

  func isProcessRunningOutput(
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

  func readTapFormatPlan(_ tapID: AudioObjectID) throws -> AudioFormatPlan {
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
}
