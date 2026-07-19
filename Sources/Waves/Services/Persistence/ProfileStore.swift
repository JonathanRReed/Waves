import Foundation
import OSLog
import WavesAudioCore

final class ProfileStore: @unchecked Sendable {
  private let url: URL
  /// Legacy location from when profiles were called "presets". Migrated on first
  /// load so existing users keep their saved mixes.
  private let legacyURL: URL
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue: DispatchQueue
  private let writeData: PersistenceDataWrite
  private let writer: CoalescingPersistenceWriter<[Profile]>

  convenience init(fileManager: FileManager = .default) {
    let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
    let directory: URL
    if let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
      do {
        try PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
      } catch {
        logger.error("Failed to create profiles directory: \(error.localizedDescription)")
      }
    } else {
      logger.error("Failed to get application support directory")
      directory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
    }
    self.init(directory: directory, writeData: PrivateAtomicPersistenceFile.write)
    PersistenceSecurity.secureExistingFile(at: url, fileManager: fileManager)
    PersistenceSecurity.secureExistingFile(at: legacyURL, fileManager: fileManager)
  }

  /// Test-only entry point: keeps current and legacy profile files inside
  /// `directory` and permits an injected failing write operation.
  convenience init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    try? PersistenceSecurity.preparePrivateDirectory(directory)
    self.init(
      url: directory.appendingPathComponent("profiles.json"),
      legacyURL: directory.appendingPathComponent("presets.json"),
      writeData: writeData
    )
    PersistenceSecurity.secureExistingFile(at: url)
    PersistenceSecurity.secureExistingFile(at: legacyURL)
  }

  private init(
    url: URL,
    legacyURL: URL,
    writeData: @escaping PersistenceDataWrite
  ) {
    self.url = url
    self.legacyURL = legacyURL
    self.writeData = writeData
    let queue = DispatchQueue(label: "com.waves.profiles.store", qos: .userInitiated)
    self.queue = queue
    self.writer = CoalescingPersistenceWriter(queue: queue) { profiles in
      try Self.write(profiles, to: url, using: writeData)
    }
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// profiles file. Read-and-cleared by the caller (AppStore) so it can
  /// surface a one-time "your profiles were reset" toast instead of failing
  /// silently.
  private(set) var didRecoverFromCorruptFile = false

  func load(defaults: [Profile]) -> [Profile] {
    queue.sync {
      let fileManager = FileManager.default

      // First launch after the Presets→Profiles rename: adopt the old file if a
      // new one doesn't exist yet, so saved mixes survive the upgrade.
      if !fileManager.fileExists(atPath: url.path),
         fileManager.fileExists(atPath: legacyURL.path) {
        if let migrated = loadFile(at: legacyURL) {
          // Persist synchronously while this queue is serialized, and retire the
          // legacy file only after the new atomic write succeeds. A failed write
          // leaves presets.json in place so migration retries next launch.
          do {
            try Self.write(migrated, to: url, using: writeData)
            retireLegacyFile()
          } catch {
            logger.error("Failed to persist migrated profiles: \(error.localizedDescription)")
          }
          return migrated
        }
      }

      // A missing file is the normal first-launch case: seed defaults on disk.
      guard fileManager.fileExists(atPath: url.path) else {
        do {
          try Self.write(defaults, to: url, using: writeData)
        } catch {
          logger.error("Failed to seed default profiles: \(error.localizedDescription)")
        }
        return defaults
      }

      return loadFile(at: url) ?? defaults
    }
  }

  private func loadFile(at fileURL: URL) -> [Profile]? {
    PersistenceSecurity.secureExistingFile(at: fileURL)
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
        logger.error("Profiles file exceeds size limit: \(fileSize) bytes")
        backupCorruptFile(fileURL)
        didRecoverFromCorruptFile = true
        return nil
      }

      let data = try Data(contentsOf: fileURL)
      return try PersistedSchema.decode([Profile].self, from: data, using: decoder)
    } catch {
      // Preserve the unreadable file for recovery instead of destroying the
      // user's saved profiles.
      logger.warning("Failed to load profiles at \(fileURL.lastPathComponent): \(error.localizedDescription). Preserving file.")
      backupCorruptFile(fileURL)
      didRecoverFromCorruptFile = true
      return nil
    }
  }

  /// Reads and clears `didRecoverFromCorruptFile`, so a caller can check once
  /// (e.g. right after `load()` at startup) without the flag lingering true
  /// across later, unrelated calls.
  func consumeDidRecoverFromCorruptFile() -> Bool {
    queue.sync {
      defer { didRecoverFromCorruptFile = false }
      return didRecoverFromCorruptFile
    }
  }

  private func retireLegacyFile() {
    let retiredURL = legacyURL.appendingPathExtension("migrated")
    try? FileManager.default.removeItem(at: retiredURL)
    do {
      try FileManager.default.moveItem(at: legacyURL, to: retiredURL)
      try? PersistenceSecurity.setPrivateFilePermissions(retiredURL)
    } catch {
      logger.error("Failed to retire migrated legacy presets file: \(error.localizedDescription)")
    }
  }

  private func backupCorruptFile(_ fileURL: URL) {
    let backupURL = fileURL.appendingPathExtension("corrupt")
    try? FileManager.default.removeItem(at: backupURL)
    do {
      try FileManager.default.moveItem(at: fileURL, to: backupURL)
      try? PersistenceSecurity.setPrivateFilePermissions(backupURL)
      logger.warning("Moved unreadable profiles file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable profiles file: \(error.localizedDescription)")
    }
  }

  func save(_ profiles: [Profile]) async throws {
    do {
      try await writer.save(profiles)
    } catch {
      logger.error("Failed to save profiles: \(error.localizedDescription)")
      throw error
    }
  }

  func flush() async throws {
    do {
      try await writer.flush()
    } catch {
      logger.error("Failed to flush profiles: \(error.localizedDescription)")
      throw error
    }
  }

  private static func write(
    _ profiles: [Profile],
    to url: URL,
    using writeData: PersistenceDataWrite
  ) throws {
    let encoder = JSONEncoder()
    let data = try PersistedSchema.encode(profiles, using: encoder)
    try writeData(data, url)
  }
}
