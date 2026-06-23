import Foundation

/// A named **group of apps** the user cares about together (e.g. "Work",
/// "Gaming"). Each member may optionally carry a volume/mute/boost level; an
/// entry with no levels is membership-only, so a profile can be a pure grouping
/// or a saved mix — or anything in between.
public struct Profile: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var entries: [ProfileEntry]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    entries: [ProfileEntry],
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.entries = entries
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// The logical IDs of every app that belongs to this profile.
  public var appIDs: [String] { entries.map(\.appID) }

  /// True when at least one member carries explicit level settings, so applying
  /// the profile will change something. A pure grouping has none.
  public var carriesLevels: Bool { entries.contains(where: \.hasLevels) }
}

/// One app's membership in a profile. The level fields are optional: when all
/// are nil the entry is *membership-only* (the app belongs to the profile but
/// the profile leaves its audio untouched when applied). Legacy presets, which
/// always stored concrete levels, decode unchanged into level-bearing entries.
public struct ProfileEntry: Codable, Hashable, Sendable {
  public var appID: String
  public var desiredVolume: Float?
  public var isMuted: Bool?
  public var volumeBoost: Float?

  /// Whether this entry sets any level. Membership-only entries return false.
  public var hasLevels: Bool {
    desiredVolume != nil || isMuted != nil || volumeBoost != nil
  }

  public init(
    appID: String,
    desiredVolume: Float? = nil,
    isMuted: Bool? = nil,
    volumeBoost: Float? = nil
  ) {
    // Validate appID length to prevent excessive memory usage
    self.appID = String(appID.prefix(256))

    // Clamp desiredVolume to valid range [0.0, 1.0] when present
    self.desiredVolume = desiredVolume.map { max(0.0, min(1.0, $0)) }

    self.isMuted = isMuted

    // Clamp volumeBoost to the user-facing range [1.0, 4.0] when present
    self.volumeBoost = volumeBoost.map { max(1.0, min(4.0, $0)) }
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
    // decodeIfPresent across all three: a legacy entry carries concrete values
    // (preserved as a level-bearing entry); a new membership-only entry omits
    // them entirely and decodes to nil.
    let desiredVolume = try container.decodeIfPresent(Float.self, forKey: .desiredVolume)
    let isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted)
    let volumeBoost = try container.decodeIfPresent(Float.self, forKey: .volumeBoost)
    self.init(appID: appID, desiredVolume: desiredVolume, isMuted: isMuted, volumeBoost: volumeBoost)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(appID, forKey: .appID)
    // Omit unset levels so a membership-only entry stays compact and reads as
    // "no override" rather than a fabricated default.
    try container.encodeIfPresent(desiredVolume, forKey: .desiredVolume)
    try container.encodeIfPresent(isMuted, forKey: .isMuted)
    try container.encodeIfPresent(volumeBoost, forKey: .volumeBoost)
  }
}
