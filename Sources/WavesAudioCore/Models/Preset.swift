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

  public init(appID: String, desiredVolume: Float, isMuted: Bool) {
    // Validate appID length to prevent excessive memory usage
    self.appID = String(appID.prefix(256))

    // Clamp desiredVolume to valid range [0.0, 1.0]
    self.desiredVolume = max(0.0, min(1.0, desiredVolume))

    self.isMuted = isMuted
  }
}
