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
  /// Whether the current mute was set by the user or applied automatically
  /// (e.g. auto-pause during a call). Lets auto-resume avoid overriding a mute
  /// the user set themselves, and survives relaunch.
  public var muteSource: MuteSource
  /// Persistent UID of the output device this app should play to, or nil to
  /// follow the system default output. Enables per-app output routing.
  public var targetDeviceUID: String?

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
    volumeBoost: Float = 1.0,
    muteSource: MuteSource = .user,
    targetDeviceUID: String? = nil
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

    self.muteSource = muteSource
    self.targetDeviceUID = targetDeviceUID.map { String($0.prefix(256)) }
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case logicalID
    case pid
    case bundleID
    case displayName
    case iconName
    case iconTIFFData
    case category
    case isActive
    case peakLevel
    case rmsLevel
    case desiredVolume
    case appliedVolume
    case isMuted
    case isPinned
    case routingState
    case compatibility
    case notes
    case volumeBoost
    case muteSource
    case targetDeviceUID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let logicalID = try container.decodeIfPresent(String.self, forKey: .logicalID)
    let pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
    let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
    let displayName = try container.decode(String.self, forKey: .displayName)
    let iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
    let iconTIFFData = try container.decodeIfPresent(Data.self, forKey: .iconTIFFData)
    let category = try container.decodeIfPresent(AppCategory.self, forKey: .category) ?? .unknown
    let isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    let peakLevel = try container.decodeIfPresent(Float.self, forKey: .peakLevel) ?? 0
    let rmsLevel = try container.decodeIfPresent(Float.self, forKey: .rmsLevel) ?? 0
    let desiredVolume = try container.decodeIfPresent(Float.self, forKey: .desiredVolume) ?? 1
    let appliedVolume = try container.decodeIfPresent(Float.self, forKey: .appliedVolume)
    let isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    let isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    let routingState = try container.decodeIfPresent(RoutingState.self, forKey: .routingState) ?? .recent
    let compatibility = try container.decodeIfPresent(CompatibilityState.self, forKey: .compatibility) ?? .planned
    let notes = try container.decodeIfPresent(String.self, forKey: .notes)
    let volumeBoost = try container.decodeIfPresent(Float.self, forKey: .volumeBoost) ?? 1.0
    let muteSource = try container.decodeIfPresent(MuteSource.self, forKey: .muteSource) ?? .user
    let targetDeviceUID = try container.decodeIfPresent(String.self, forKey: .targetDeviceUID)

    self.init(
      id: id,
      logicalID: logicalID,
      pid: pid,
      bundleID: bundleID,
      displayName: displayName,
      iconName: iconName,
      iconTIFFData: iconTIFFData,
      category: category,
      isActive: isActive,
      peakLevel: peakLevel,
      rmsLevel: rmsLevel,
      desiredVolume: desiredVolume,
      appliedVolume: appliedVolume,
      isMuted: isMuted,
      isPinned: isPinned,
      routingState: routingState,
      compatibility: compatibility,
      notes: notes,
      volumeBoost: volumeBoost,
      muteSource: muteSource,
      targetDeviceUID: targetDeviceUID
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(logicalID, forKey: .logicalID)
    try container.encodeIfPresent(pid, forKey: .pid)
    try container.encodeIfPresent(bundleID, forKey: .bundleID)
    try container.encode(displayName, forKey: .displayName)
    try container.encodeIfPresent(iconName, forKey: .iconName)
    try container.encodeIfPresent(iconTIFFData, forKey: .iconTIFFData)
    try container.encode(category, forKey: .category)
    try container.encode(isActive, forKey: .isActive)
    try container.encode(peakLevel, forKey: .peakLevel)
    try container.encode(rmsLevel, forKey: .rmsLevel)
    try container.encode(desiredVolume, forKey: .desiredVolume)
    try container.encodeIfPresent(appliedVolume, forKey: .appliedVolume)
    try container.encode(isMuted, forKey: .isMuted)
    try container.encode(isPinned, forKey: .isPinned)
    try container.encode(routingState, forKey: .routingState)
    try container.encode(compatibility, forKey: .compatibility)
    try container.encodeIfPresent(notes, forKey: .notes)
    try container.encode(volumeBoost, forKey: .volumeBoost)
    try container.encode(muteSource, forKey: .muteSource)
    try container.encodeIfPresent(targetDeviceUID, forKey: .targetDeviceUID)
  }
}

public enum MuteSource: String, Codable, Hashable, Sendable {
  /// Muted by the user directly.
  case user
  /// Muted automatically by Waves (e.g. auto-pause during a call).
  case autoConferencing
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
      "Ready"
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
