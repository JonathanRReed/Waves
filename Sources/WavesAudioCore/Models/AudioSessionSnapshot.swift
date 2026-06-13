import Foundation

public struct AudioSessionSnapshot: Codable, Hashable, Sendable {
  public var apps: [AudioApp]
  public var currentDevice: AudioDevice?
  public var recentDeviceIDs: [String]
  public var supportMatrix: SupportMatrix
  public var backendStatus: BackendStatus
  public var updatedAt: Date

  public init(
    apps: [AudioApp],
    currentDevice: AudioDevice?,
    recentDeviceIDs: [String],
    supportMatrix: SupportMatrix,
    backendStatus: BackendStatus,
    updatedAt: Date = .now
  ) {
    self.apps = apps
    self.currentDevice = currentDevice
    self.recentDeviceIDs = recentDeviceIDs
    self.supportMatrix = supportMatrix
    self.backendStatus = backendStatus
    self.updatedAt = updatedAt
  }

  /// A neutral, empty session with no apps and no fabricated state. Used as the
  /// initial value for the live backend before the first real snapshot is built.
  public static var empty: AudioSessionSnapshot {
    AudioSessionSnapshot(
      apps: [],
      currentDevice: nil,
      recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: false,
        hasRequiredPermissions: false,
        isRouteRecoveryHealthy: false,
        lastError: nil
      )
    )
  }
}

public struct BackendStatus: Codable, Hashable, Sendable {
  public var isAudioComponentInstalled: Bool
  public var hasRequiredPermissions: Bool
  public var isRouteRecoveryHealthy: Bool
  public var lastError: String?

  public init(
    isAudioComponentInstalled: Bool,
    hasRequiredPermissions: Bool,
    isRouteRecoveryHealthy: Bool,
    lastError: String? = nil
  ) {
    self.isAudioComponentInstalled = isAudioComponentInstalled
    self.hasRequiredPermissions = hasRequiredPermissions
    self.isRouteRecoveryHealthy = isRouteRecoveryHealthy

    // Validate lastError length to prevent excessive memory usage
    self.lastError = lastError.map { String($0.prefix(1000)) }
  }
}
