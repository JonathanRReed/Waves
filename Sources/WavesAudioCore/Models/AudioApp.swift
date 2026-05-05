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
  public var peakLevel: Float
  public var rmsLevel: Float
  public var desiredVolume: Float
  public var appliedVolume: Float?
  public var isMuted: Bool
  public var isPinned: Bool
  public var routingState: RoutingState
  public var compatibility: CompatibilityState
  public var notes: String?
  public var volumeBoost: Float

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
    peakLevel: Float = 0,
    rmsLevel: Float = 0,
    desiredVolume: Float = 1,
    appliedVolume: Float? = nil,
    isMuted: Bool = false,
    isPinned: Bool = false,
    routingState: RoutingState = .recent,
    compatibility: CompatibilityState = .planned,
    notes: String? = nil,
    volumeBoost: Float = 1.0
  ) {
    // Validate string lengths to prevent excessive memory usage
    self.id = String(id.prefix(256))
    self.logicalID = (logicalID ?? id).isEmpty ? id : String((logicalID ?? id).prefix(256))
    self.pid = pid
    self.bundleID = bundleID.map { String($0.prefix(256)) }
    self.displayName = String(displayName.prefix(256))

    // Validate iconTIFFData size (max 10MB to prevent excessive memory usage)
    self.iconTIFFData = iconTIFFData.map { data in
      data.count > 10_485_760 ? Data(data.prefix(10_485_760)) : data
    }

    self.iconName = iconName
    self.category = category
    self.isActive = isActive
    self.peakLevel = peakLevel
    self.rmsLevel = rmsLevel

    // Clamp desiredVolume to valid range [0.0, 1.0]
    self.desiredVolume = max(0.0, min(1.0, desiredVolume))

    // Clamp appliedVolume to valid range [0.0, 1.0] if present
    self.appliedVolume = appliedVolume.map { max(0.0, min(1.0, $0)) }

    self.isMuted = isMuted
    self.isPinned = isPinned
    self.routingState = routingState
    self.compatibility = compatibility

    // Validate notes length
    self.notes = notes.map { String($0.prefix(1000)) }

    // Clamp volumeBoost to reasonable range [0.0, 10.0]
    self.volumeBoost = max(0.0, min(10.0, volumeBoost))
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
