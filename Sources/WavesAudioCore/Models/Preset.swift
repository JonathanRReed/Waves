import Foundation

public struct Preset: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var entries: [PresetEntry]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    entries: [PresetEntry],
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.entries = entries
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct PresetEntry: Codable, Hashable, Sendable {
  public var appID: String
  public var desiredVolume: Float
  public var isMuted: Bool
  public var volumeBoost: Float

  public init(appID: String, desiredVolume: Float, isMuted: Bool, volumeBoost: Float = 1.0) {
    // Validate appID length to prevent excessive memory usage
    self.appID = String(appID.prefix(256))

    // Clamp desiredVolume to valid range [0.0, 1.0]
    self.desiredVolume = max(0.0, min(1.0, desiredVolume))

    self.isMuted = isMuted

    // Clamp volumeBoost to the user-facing range [1.0, 4.0]
    self.volumeBoost = max(1.0, min(4.0, volumeBoost))
  }

  private enum CodingKeys: String, CodingKey {
    case appID
    case desiredVolume
    case isMuted
    case volumeBoost
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let appID = try container.decode(String.self, forKey: .appID)
    let desiredVolume = try container.decode(Float.self, forKey: .desiredVolume)
    let isMuted = try container.decode(Bool.self, forKey: .isMuted)
    let volumeBoost = try container.decodeIfPresent(Float.self, forKey: .volumeBoost) ?? 1.0
    self.init(appID: appID, desiredVolume: desiredVolume, isMuted: isMuted, volumeBoost: volumeBoost)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(appID, forKey: .appID)
    try container.encode(desiredVolume, forKey: .desiredVolume)
    try container.encode(isMuted, forKey: .isMuted)
    try container.encode(volumeBoost, forKey: .volumeBoost)
  }
}
