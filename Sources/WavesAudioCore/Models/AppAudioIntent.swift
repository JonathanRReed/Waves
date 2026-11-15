import Foundation

/// Durable audio choices for one logical application.
///
/// Runtime-only state such as process IDs, meters, route health, applied volume,
/// and automatic conferencing mutes deliberately stays out of this model.
public struct PersistedAppAudioIntent: Codable, Hashable, Sendable {
  public let appID: String
  public let desiredVolume: Float
  public let isMuted: Bool
  public let volumeBoost: Float
  public let equalizerSettings: EqualizerSettings
  public let targetDeviceUID: String?

  public init(
    appID: String,
    desiredVolume: Float = 1,
    isMuted: Bool = false,
    volumeBoost: Float = 1,
    equalizerSettings: EqualizerSettings = EqualizerSettings(),
    targetDeviceUID: String? = nil
  ) {
    self.appID = String(appID.prefix(256))
    self.desiredVolume = LevelRange.volume.sanitized(desiredVolume)
    self.isMuted = isMuted
    self.volumeBoost = LevelRange.boost.sanitized(volumeBoost)
    self.equalizerSettings = equalizerSettings
    self.targetDeviceUID = targetDeviceUID.map { String($0.prefix(256)) }
  }

  private enum CodingKeys: String, CodingKey {
    case appID
    case desiredVolume
    case isMuted
    case volumeBoost
    case equalizerSettings
    case targetDeviceUID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      appID: try container.decode(String.self, forKey: .appID),
      // Decoded as Double so a value too large for Float is clamped instead of
      // failing the whole preferences file.
      desiredVolume: LevelRange.volume.sanitized(
        try container.decodeIfPresent(Double.self, forKey: .desiredVolume)),
      isMuted: try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
      volumeBoost: LevelRange.boost.sanitized(
        try container.decodeIfPresent(Double.self, forKey: .volumeBoost)),
      equalizerSettings: try container.decodeIfPresent(EqualizerSettings.self, forKey: .equalizerSettings)
        ?? EqualizerSettings(),
      targetDeviceUID: try container.decodeIfPresent(String.self, forKey: .targetDeviceUID)
    )
  }
}

public enum AppRouteIntentReason: Hashable, Sendable {
  case userEdit
  case startupRestore
  case devicePresetRestore
  case profileApply
  case automation
  case deviceChange
  case routeRecovery
}

/// Complete resolved route intent submitted to a backend.
///
/// This is intentionally not Codable. It carries orchestration metadata and is
/// valid only for the current process lifetime.
public struct AppRouteIntent: Hashable, Sendable {
  public let appID: String
  public let desiredVolume: Float
  public let isMuted: Bool
  public let volumeBoost: Float
  public let equalizerSettings: EqualizerSettings
  public let targetDeviceUID: String?
  public let generation: UInt64
  public let reason: AppRouteIntentReason
  public let isExcluded: Bool

  public init(
    appID: String,
    desiredVolume: Float,
    isMuted: Bool,
    volumeBoost: Float,
    equalizerSettings: EqualizerSettings,
    targetDeviceUID: String?,
    generation: UInt64,
    reason: AppRouteIntentReason,
    isExcluded: Bool = false
  ) {
    self.appID = String(appID.prefix(256))
    self.desiredVolume = max(0, min(1, desiredVolume.isFinite ? desiredVolume : 1))
    self.isMuted = isMuted
    self.volumeBoost = max(1, min(4, volumeBoost.isFinite ? volumeBoost : 1))
    self.equalizerSettings = equalizerSettings
    self.targetDeviceUID = targetDeviceUID.map { String($0.prefix(256)) }
    self.generation = generation
    self.reason = reason
    self.isExcluded = isExcluded
  }
}
