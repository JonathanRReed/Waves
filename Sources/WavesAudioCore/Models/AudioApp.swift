import Foundation

public struct AudioApp: Identifiable, Codable, Hashable, Sendable {
  public let id: String
  public let logicalID: String
  public let pid: Int32?
  public let bundleID: String?
  public let displayName: String
  public let iconName: String?
  public let iconTIFFData: Data?
  public let category: AppCategory

  public var isActive: Bool
  public var isAudible: Bool
  public var peakLevel: Float
  public var rmsLevel: Float
  public var desiredVolume: Float
  public var appliedVolume: Float?
  public var isMuted: Bool
  public var isPinned: Bool
  public var routingState: RoutingState
  public var compatibility: CompatibilityState
  public var lastSeenAt: Date
  public var notes: String?

  public init(
    id: String,
    logicalID: String? = nil,
    pid: Int32? = nil,
    bundleID: String? = nil,
    displayName: String,
    iconName: String? = nil,
    iconTIFFData: Data? = nil,
    category: AppCategory,
    isActive: Bool = false,
    isAudible: Bool = false,
    peakLevel: Float = 0,
    rmsLevel: Float = 0,
    desiredVolume: Float = 1,
    appliedVolume: Float? = nil,
    isMuted: Bool = false,
    isPinned: Bool = false,
    routingState: RoutingState = .recent,
    compatibility: CompatibilityState = .planned,
    lastSeenAt: Date = .now,
    notes: String? = nil
  ) {
    self.id = id
    self.logicalID = logicalID ?? id
    self.pid = pid
    self.bundleID = bundleID
    self.displayName = displayName
    self.iconName = iconName
    self.iconTIFFData = iconTIFFData
    self.category = category
    self.isActive = isActive
    self.isAudible = isAudible
    self.peakLevel = peakLevel
    self.rmsLevel = rmsLevel
    self.desiredVolume = desiredVolume
    self.appliedVolume = appliedVolume
    self.isMuted = isMuted
    self.isPinned = isPinned
    self.routingState = routingState
    self.compatibility = compatibility
    self.lastSeenAt = lastSeenAt
    self.notes = notes
  }
}

public enum RoutingState: String, Codable, CaseIterable, Hashable, Sendable {
  case live
  case recent
  case managed
  case monitorOnly = "monitor_only"
  case error

  public var displayName: String {
    switch self {
    case .live:
      "Live"
    case .recent:
      "Recent"
    case .managed:
      "Managed"
    case .monitorOnly:
      "Monitor only"
    case .error:
      "Error"
    }
  }
}

public enum AppCategory: String, Codable, CaseIterable, Hashable, Sendable {
  case browser
  case conferencing
  case media
  case communication
  case system
  case unknown

  public var displayName: String {
    switch self {
    case .browser:
      "Browser"
    case .conferencing:
      "Conferencing"
    case .media:
      "Media"
    case .communication:
      "Communication"
    case .system:
      "System"
    case .unknown:
      "Unknown"
    }
  }
}

public enum CompatibilityState: String, Codable, CaseIterable, Hashable, Sendable {
  case supported
  case validating
  case planned
  case unsupported

  public var displayName: String {
    switch self {
    case .supported:
      "Supported"
    case .validating:
      "Validating"
    case .planned:
      "Planned"
    case .unsupported:
      "Unsupported"
    }
  }
}
