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
  public static let maxErrorLength = 1_000

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
    self.lastError = lastError.map { String($0.prefix(Self.maxErrorLength)) }
  }

  /// Capability state is meaningful only after a live backend probe. Persisted
  /// sessions are deliberately restored in this neutral state so stale values
  /// cannot briefly present permissions or route health as current truth.
  public static var unprobed: BackendStatus {
    BackendStatus(
      isAudioComponentInstalled: false,
      hasRequiredPermissions: false,
      isRouteRecoveryHealthy: false,
      lastError: nil
    )
  }

  private enum CodingKeys: String, CodingKey {
    case isAudioComponentInstalled
    case hasRequiredPermissions
    case isRouteRecoveryHealthy
    case lastError
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      isAudioComponentInstalled: try container.decode(Bool.self, forKey: .isAudioComponentInstalled),
      hasRequiredPermissions: try container.decode(Bool.self, forKey: .hasRequiredPermissions),
      isRouteRecoveryHealthy: try container.decode(Bool.self, forKey: .isRouteRecoveryHealthy),
      lastError: try container.decodeIfPresent(String.self, forKey: .lastError)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(isAudioComponentInstalled, forKey: .isAudioComponentInstalled)
    try container.encode(hasRequiredPermissions, forKey: .hasRequiredPermissions)
    try container.encode(isRouteRecoveryHealthy, forKey: .isRouteRecoveryHealthy)
    try container.encodeIfPresent(lastError, forKey: .lastError)
  }
}
