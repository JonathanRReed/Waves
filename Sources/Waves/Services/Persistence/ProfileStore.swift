import Foundation
import OSLog
import WavesAudioCore

final class ProfileStore: @unchecked Sendable {
  /// Legacy location from when profiles were called "presets". Migrated on
  /// first load so existing users keep their saved mixes.
  private let legacyURL: URL
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let engine: JSONPersistenceEngine<[Profile]>

  convenience init(fileManager: FileManager = .default) {
    self.init(
      directory: PersistenceLocation.applicationSupportDirectory(fileManager: fileManager),
      fileManager: fileManager,
      writeData: PrivateAtomicPersistenceFile.write
    )
  }

  /// Test-only entry point: keeps current and legacy profile files inside
  /// `directory` and permits an injected failing write operation.
  convenience init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    self.init(directory: directory, fileManager: .default, writeData: writeData)
  }

  private init(
    directory: URL,
    fileManager: FileManager,
    writeData: @escaping PersistenceDataWrite
  ) {
    self.fileManager = fileManager
    legacyURL = directory.appendingPathComponent("presets.json")
    engine = JSONPersistenceEngine(
      url: directory.appendingPathComponent("profiles.json"),
      queueLabel: "com.waves.profiles.store",
      displayName: "profiles",
      fileManager: fileManager,
      writeData: writeData,
      codec: JSONPersistenceCodec(
        encode: { profiles in
          try PersistedSchema.encode(profiles, using: JSONEncoder())
        },
        decode: { data in
          try ProfilePayloadDecoder.decodePersistedProfiles(
            from: data,
            using: JSONDecoder()
          )
        }
      )
    )
  }

  func load(defaults: [Profile]) -> [Profile] {
    switch engine.load() {
    case .loaded(let profiles):
      return profiles
    case .recoveredFromCorruption:
      return defaults
    case .missing:
      break
    }

    // First launch after the Presets to Profiles rename: adopt the old file if
    // present, then retire it only after the replacement is durable.
    if case .loaded(let migrated) = engine.load(from: legacyURL) {
      do {
        try engine.writeSynchronously(migrated)
        retireLegacyFile()
      } catch {
        logger.error("Failed to persist migrated profiles: \(error.localizedDescription)")
      }
      return migrated
    }

    // A missing or damaged legacy file is the first-launch/default path.
    do {
      try engine.writeSynchronously(defaults)
    } catch {
      logger.error("Failed to seed default profiles: \(error.localizedDescription)")
    }
    return defaults
  }

  func consumeDidRecoverFromCorruptFile() -> Bool {
    engine.consumeDidRecoverFromCorruptFile()
  }

  func save(_ profiles: [Profile]) async throws {
    try await engine.save(profiles)
  }

  func flush() async throws {
    try await engine.flush()
  }

  private func retireLegacyFile() {
    let retiredURL = legacyURL.appendingPathExtension("migrated")
    try? fileManager.removeItem(at: retiredURL)
    do {
      try fileManager.moveItem(at: legacyURL, to: retiredURL)
      try PersistenceSecurity.setPrivateFilePermissions(retiredURL, fileManager: fileManager)
    } catch {
      logger.error("Failed to retire migrated legacy presets file: \(error.localizedDescription)")
    }
  }
}
