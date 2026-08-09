import Foundation
import WavesAudioCore

/// Explicit persistence payload for session state. Runtime-only capability
/// truth is normalized by `SessionStore` after decode. Missing fields from
/// older payloads receive neutral defaults, while present known fields with an
/// invalid type still throw and preserve the original file as corrupt.
enum SessionPayloadCodec {
  static func encode(_ snapshot: AudioSessionSnapshot, using encoder: JSONEncoder) throws -> Data {
    try PersistedSchema.encode(AdditiveSessionPayload(snapshot), using: encoder)
  }

  static func decode(from data: Data, using decoder: JSONDecoder) throws -> AudioSessionSnapshot {
    try PersistedSchema.decode(AdditiveSessionPayload.self, from: data, using: decoder).snapshot
  }

  private struct AdditiveSessionPayload: Codable {
    private enum CodingKeys: String, CodingKey {
      case apps
      case currentDevice
      case recentDeviceIDs
      case supportMatrix
      case backendStatus
      case updatedAt
    }

    var snapshot: AudioSessionSnapshot

    init(_ snapshot: AudioSessionSnapshot) {
      self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let apps = try container.decodeIfPresent([AudioApp].self, forKey: .apps) ?? []
      let currentDevice = try container.decodeIfPresent(AdditiveAudioDevice.self, forKey: .currentDevice)?.value
      let recentDeviceIDs = try container.decodeIfPresent([String].self, forKey: .recentDeviceIDs) ?? []
      let supportMatrix =
        try container.decodeIfPresent(AdditiveSupportMatrix.self, forKey: .supportMatrix)?.value
        ?? SupportMatrix(entries: [])
      let backendStatus =
        try container.decodeIfPresent(AdditiveBackendStatus.self, forKey: .backendStatus)?.value
        ?? .unprobed
      let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
      snapshot = AudioSessionSnapshot(
        apps: apps,
        currentDevice: currentDevice,
        recentDeviceIDs: recentDeviceIDs,
        supportMatrix: supportMatrix,
        backendStatus: backendStatus,
        updatedAt: updatedAt
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(snapshot.apps, forKey: .apps)
      try container.encodeIfPresent(snapshot.currentDevice.map(AdditiveAudioDevice.init), forKey: .currentDevice)
      try container.encode(snapshot.recentDeviceIDs, forKey: .recentDeviceIDs)
      try container.encode(AdditiveSupportMatrix(snapshot.supportMatrix), forKey: .supportMatrix)
      try container.encode(AdditiveBackendStatus(snapshot.backendStatus), forKey: .backendStatus)
      try container.encode(snapshot.updatedAt, forKey: .updatedAt)
    }
  }

  private struct AdditiveAudioDevice: Codable {
    private enum CodingKeys: String, CodingKey {
      case id
      case name
      case kind
      case isCurrent
      case isManagedRouteAvailable
      case volumeControlMode
    }

    var value: AudioDevice

    init(_ value: AudioDevice) {
      self.value = value
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      value = AudioDevice(
        id: try container.decode(String.self, forKey: .id),
        name: try container.decode(String.self, forKey: .name),
        kind: try container.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .unknown,
        isCurrent: try container.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false,
        isManagedRouteAvailable: try container.decodeIfPresent(Bool.self, forKey: .isManagedRouteAvailable) ?? false,
        volumeControlMode: try container.decodeIfPresent(VolumeControlMode.self, forKey: .volumeControlMode) ?? .software
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value.id, forKey: .id)
      try container.encode(value.name, forKey: .name)
      try container.encode(value.kind, forKey: .kind)
      try container.encode(value.isCurrent, forKey: .isCurrent)
      try container.encode(value.isManagedRouteAvailable, forKey: .isManagedRouteAvailable)
      try container.encode(value.volumeControlMode, forKey: .volumeControlMode)
    }
  }

  private struct AdditiveSupportMatrix: Codable {
    private enum CodingKeys: String, CodingKey {
      case entries
    }

    var value: SupportMatrix

    init(_ value: SupportMatrix) {
      self.value = value
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      value = SupportMatrix(
        entries: try container.decodeIfPresent([AdditiveSupportEntry].self, forKey: .entries)?.map(\.value) ?? []
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value.entries.map(AdditiveSupportEntry.init), forKey: .entries)
    }
  }

  private struct AdditiveSupportEntry: Codable {
    private enum CodingKeys: String, CodingKey {
      case appID
      case displayName
      case category
      case state
      case notes
    }

    var value: SupportMatrixEntry

    init(_ value: SupportMatrixEntry) {
      self.value = value
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let appID = try container.decode(String.self, forKey: .appID)
      value = SupportMatrixEntry(
        appID: appID,
        displayName: try container.decodeIfPresent(String.self, forKey: .displayName) ?? appID,
        category: try container.decodeIfPresent(AppCategory.self, forKey: .category) ?? .unknown,
        state: try container.decodeIfPresent(CompatibilityState.self, forKey: .state) ?? .planned,
        notes: try container.decodeIfPresent(String.self, forKey: .notes)
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value.appID, forKey: .appID)
      try container.encode(value.displayName, forKey: .displayName)
      try container.encode(value.category, forKey: .category)
      try container.encode(value.state, forKey: .state)
      try container.encodeIfPresent(value.notes, forKey: .notes)
    }
  }

  private struct AdditiveBackendStatus: Codable {
    private enum CodingKeys: String, CodingKey {
      case isAudioComponentInstalled
      case hasRequiredPermissions
      case isRouteRecoveryHealthy
      case lastError
    }

    var value: BackendStatus

    init(_ value: BackendStatus) {
      self.value = value
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      value = BackendStatus(
        isAudioComponentInstalled: try container.decodeIfPresent(Bool.self, forKey: .isAudioComponentInstalled) ?? false,
        hasRequiredPermissions: try container.decodeIfPresent(Bool.self, forKey: .hasRequiredPermissions) ?? false,
        isRouteRecoveryHealthy: try container.decodeIfPresent(Bool.self, forKey: .isRouteRecoveryHealthy) ?? false,
        lastError: try container.decodeIfPresent(String.self, forKey: .lastError)
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value.isAudioComponentInstalled, forKey: .isAudioComponentInstalled)
      try container.encode(value.hasRequiredPermissions, forKey: .hasRequiredPermissions)
      try container.encode(value.isRouteRecoveryHealthy, forKey: .isRouteRecoveryHealthy)
      try container.encodeIfPresent(value.lastError, forKey: .lastError)
    }
  }
}
