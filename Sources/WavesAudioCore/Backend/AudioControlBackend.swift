import Foundation

public protocol AudioControlBackend: AnyObject, Sendable {
  func start() async throws
  func stop() async
  func currentSnapshot() async -> AudioSessionSnapshot
  func refresh() async throws -> AudioSessionSnapshot
  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws
  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws
  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws
  func setEqualizer(_ settings: EqualizerSettings, forAppID appID: String) async throws
  func adaptiveAnalysis() async -> [String: AdaptiveAnalysisLevels]
  func setAdaptiveGains(_ gainsDB: [String: Float]) async
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws
  func pinApp(_ isPinned: Bool, appID: String) async throws
  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot
  func saveCurrentProfile(named name: String) async throws -> Profile
  func recoverRoutes() async throws -> AudioSessionSnapshot
  func autoRestoreDevice() async throws -> AudioSessionSnapshot
  func diagnosticsReport() async -> DiagnosticsReport

  /// All output-capable devices currently available, for output switching.
  func availableOutputDevices() async -> [AudioDevice]

  /// Sets the system default output device by its persistent UID.
  func setDefaultOutputDevice(uid: String) async throws

  /// Routes a specific app to a chosen output device (by UID), or nil to follow
  /// the system default. Rebuilds the app's managed route if it has one.
  func setOutputDevice(uid: String?, forAppID appID: String) async throws

  /// Emits once after the default output device changes and the backend has
  /// re-established managed routes, so observers can refresh state and restore
  /// per-device volume presets.
  nonisolated var deviceChangeEvents: AsyncStream<Void> { get }

  /// Tears down managed routes for an application that has quit, so its process
  /// tap and aggregate device are released promptly instead of lingering until
  /// the next manual refresh. `clearMuteState` must be true ONLY for the
  /// exclusion path (so a later whole-session rebuild does not resurrect a mute
  /// the user cleared by excluding the app); plain app termination passes false
  /// to preserve the user's saved mute.
  func releaseControllers(forBundleID bundleID: String?, pid: Int32, clearMuteState: Bool) async

  /// Current per-app output levels keyed by logical ID, for live meters. Cheap
  /// to call; intended to be polled only while a UI surface is visible.
  func audioLevels() async -> [String: AudioLevels]

  /// Applies one complete app intent. The default adapter preserves legacy
  /// conformers until they implement backend-owned generation checks.
  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult

  /// Applies a profile and reports one ordered result per source entry.
  func applyProfileWithResults(_ profile: Profile, generation: UInt64) async -> ProfileApplyResult

  /// Coarse operating capability used while legacy backends expose only boolean
  /// component/permission status.
  func audioCapabilityMode() async -> AudioCapabilityMode

  /// Structured capture-authorization result. Legacy backends map an ambiguous
  /// false permission boolean to `.undetermined`, never a guessed denial.
  func captureAuthorizationResult() async -> CaptureAuthorizationResult

  /// Stops the backend and reports cleanup confidence.
  func shutdownWithResult() async -> BackendShutdownResult
}

public extension AudioControlBackend {
  func applyAppIntent(_ intent: AppRouteIntent) async -> AppIntentApplyResult {
    let snapshot = await currentSnapshot()
    return AppIntentApplyResult(
      appID: intent.appID,
      generation: intent.generation,
      outcome: .unsupported,
      resultingApp: snapshot.apps.app(matchingAppKey: intent.appID),
      backendStatus: snapshot.backendStatus,
      detail: "This backend does not implement generation-aware complete-intent application."
    )
  }

  func applyProfileWithResults(_ profile: Profile, generation: UInt64) async -> ProfileApplyResult {
    let snapshot = await currentSnapshot()
    let rows = profile.entries.enumerated().map { entryIndex, entry in
      ProfileRowApplyResult(
        entryIndex: entryIndex,
        appID: entry.appID,
        generation: generation,
        outcome: entry.hasLevels ? .unsupported : .membershipOnly,
        resultingApp: nil,
        detail: entry.hasLevels
          ? "This backend does not implement generation-aware profile application."
          : nil
      )
    }
    return ProfileApplyResult(rows: rows, backendStatus: snapshot.backendStatus)
  }

  func audioCapabilityMode() async -> AudioCapabilityMode {
    let status = await currentSnapshot().backendStatus
    return status.isAudioComponentInstalled && status.hasRequiredPermissions ? .full : .limited
  }

  func captureAuthorizationResult() async -> CaptureAuthorizationResult {
    let status = await currentSnapshot().backendStatus
    guard status.isAudioComponentInstalled else { return .unsupported }
    return status.hasRequiredPermissions ? .authorized : .undetermined
  }

  func shutdownWithResult() async -> BackendShutdownResult {
    await stop()
    return BackendShutdownResult(completion: .unverified)
  }

}

private extension Array where Element == AudioApp {
  func app(matchingAppKey appKey: String) -> AudioApp? {
    first { $0.logicalID == appKey } ?? first { $0.id == appKey }
  }
}

public struct AudioLevels: Hashable, Sendable {
  public var peak: Float
  public var rms: Float

  public init(peak: Float, rms: Float) {
    self.peak = peak
    self.rms = rms
  }
}

/// Analysis values used by Adaptive Mix. These values are transient, contain
/// no retained audio samples, and are separate from the final-output UI meters.
public struct AdaptiveAnalysisLevels: Hashable, Sendable {
  public var rms: Float
  public var voiceBandEnergy: Float

  public init(rms: Float, voiceBandEnergy: Float) {
    self.rms = rms.isFinite ? max(0, rms) : 0
    self.voiceBandEnergy = voiceBandEnergy.isFinite ? max(0, voiceBandEnergy) : 0
  }
}

public struct DiagnosticsReport: Codable, Hashable, Sendable {
  public var generatedAt: Date
  public var summary: String
  public var checks: [DiagnosticsCheck]

  public init(generatedAt: Date = .now, summary: String, checks: [DiagnosticsCheck]) {
    self.generatedAt = generatedAt
    self.summary = summary
    self.checks = checks
  }
}

public struct DiagnosticsCheck: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public var title: String
  public var status: DiagnosticsStatus
  public var detail: String

  public init(
    id: UUID = UUID(),
    title: String,
    status: DiagnosticsStatus,
    detail: String
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.detail = detail
  }
}

public enum DiagnosticsStatus: String, Codable, Hashable, Sendable {
  case passed
  case warning
  case failed
  case informational
}
