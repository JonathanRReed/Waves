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
  func applyPreset(_ preset: Preset) async throws -> AudioSessionSnapshot
  func saveCurrentPreset(named name: String) async throws -> Preset
  func recoverRoutes() async throws -> AudioSessionSnapshot
  func autoRestoreDevice() async throws -> AudioSessionSnapshot
  func diagnosticsReport() async -> DiagnosticsReport

  /// All output-capable devices currently available, for output switching.
  func availableOutputDevices() async -> [AudioDevice]

  /// Sets the system default output device by its persistent UID.
  func setDefaultOutputDevice(uid: String) async throws

  /// Emits once after the default output device changes and the backend has
  /// re-established managed routes, so observers can refresh state and restore
  /// per-device volume presets.
  nonisolated var deviceChangeEvents: AsyncStream<Void> { get }

  /// Tears down managed routes for an application that has quit, so its process
  /// tap and aggregate device are released promptly instead of lingering until
  /// the next manual refresh.
  func releaseControllers(forBundleID bundleID: String?, pid: Int32) async
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
