import Foundation

/// Wraps persisted JSON in an explicit schema version so future, non-additive
/// format changes can be migrated deliberately instead of silently failing to
/// decode (which previously risked wiping user data).
struct VersionedPayload<Payload: Codable>: Codable {
  var schemaVersion: Int
  var payload: Payload
}

enum PersistedSchema {
  /// Current schema version shared by all Waves stores. Bump this and add a
  /// `migrate` case when a payload shape changes in a non-additive way.
  static let current = 1

  /// Encodes `payload` inside the current versioned envelope.
  static func encode<Payload: Codable>(_ payload: Payload, using encoder: JSONEncoder) throws -> Data {
    try encoder.encode(VersionedPayload(schemaVersion: current, payload: payload))
  }

  /// Decodes `payload`, accepting both the versioned envelope and a legacy
  /// unversioned file written before envelopes existed.
  static func decode<Payload: Codable>(
    _ type: Payload.Type,
    from data: Data,
    using decoder: JSONDecoder
  ) throws -> Payload {
    if let envelope = try? decoder.decode(VersionedPayload<Payload>.self, from: data) {
      // A file written by a newer build than this one may have an incompatible
      // payload shape. Refuse it (the caller backs it up and uses defaults)
      // rather than loading data we don't understand.
      guard envelope.schemaVersion <= current else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: [],
            debugDescription: "Unsupported schema version \(envelope.schemaVersion) (this build supports \(current))."
          )
        )
      }
      return migrate(envelope.payload, from: envelope.schemaVersion)
    }
    // Legacy file: a bare payload with no envelope (treated as schema 0).
    return try decoder.decode(Payload.self, from: data)
  }

  private static func migrate<Payload>(_ payload: Payload, from version: Int) -> Payload {
    // v1 is the first versioned schema; no migrations are needed yet. Future
    // versions add transformation cases here keyed on `version`.
    payload
  }
}

enum PersistenceSecurity {
  static func preparePrivateDirectory(_ directory: URL, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try setPrivateDirectoryPermissions(directory, fileManager: fileManager)
  }

  static func secureExistingFile(at url: URL, fileManager: FileManager = .default) {
    guard fileManager.fileExists(atPath: url.path) else { return }
    try? setPrivateFilePermissions(url, fileManager: fileManager)
  }

  static func setPrivateFilePermissions(_ url: URL, fileManager: FileManager = .default) throws {
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func setPrivateDirectoryPermissions(_ directory: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }
}
