import Foundation

public protocol AudioControlBackend: AnyObject, Sendable {
  func start() async throws
  func stop() async
  func currentSnapshot() async -> AudioSessionSnapshot
  func refresh() async throws -> AudioSessionSnapshot
  func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws
  func setMuted(_ isMuted: Bool, forAppID appID: String) async throws
  func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws
  func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws
  func pinApp(_ isPinned: Bool, appID: String) async throws
  func applyProfile(_ profile: Profile) async throws -> AudioSessionSnapshot
  func saveCurrentProfile(named name: String) async throws -> Profile
  func recoverRoutes() async throws -> AudioSessionSnapshot
  func autoRestoreDevice() async throws -> AudioSessionSnapshot
  func diagnosticsReport() async -> DiagnosticsReport

  /// Enables or disables automatic route recovery on a default-output-device
  /// change. When disabled, the backend's internal device-change handler must
  /// not call `autoRestoreDevice()` on its own — the device-change-detected
  /// signal (`deviceChangeEvents`) should still fire so observers can refresh
  /// read-only state (current device, device list), just without re-tapping
  /// every managed app's route or restoring per-device volume presets.
  func setAutoRestoreDeviceEnabled(_ enabled: Bool) async

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
}

public struct AudioLevels: Hashable, Sendable {
  public var peak: Float
  public var rms: Float

  public init(peak: Float, rms: Float) {
    self.peak = peak
    self.rms = rms
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
