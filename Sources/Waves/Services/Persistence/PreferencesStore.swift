import Foundation
import OSLog

final class PreferencesStore: @unchecked Sendable {
  private let url: URL
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue: DispatchQueue
  private let writer: CoalescingPersistenceWriter<UserPreferences>

  convenience init(fileManager: FileManager = .default) {
    let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
    let url: URL
    if let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
      do {
        try PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
      } catch {
        logger.error("Failed to create preferences directory: \(error.localizedDescription)")
      }
      url = directory.appendingPathComponent("preferences.json")
    } else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? PersistenceSecurity.preparePrivateDirectory(fallbackDirectory, fileManager: fileManager)
      url = fallbackDirectory.appendingPathComponent("preferences.json")
    }
    self.init(url: url, writeData: PrivateAtomicPersistenceFile.write)
  }

  /// Test-only entry point: keeps the store's file inside `directory` instead
  /// of the real Application Support location. `writeData` is injectable so
  /// focused tests can verify that asynchronous write failures reach callers.
  convenience init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    try? PersistenceSecurity.preparePrivateDirectory(directory)
    self.init(
      url: directory.appendingPathComponent("preferences.json"),
      writeData: writeData
    )
  }

  private init(url: URL, writeData: @escaping PersistenceDataWrite) {
    self.url = url
    let queue = DispatchQueue(label: "com.waves.preferences.store", qos: .userInitiated)
    self.queue = queue
    self.writer = CoalescingPersistenceWriter(queue: queue) { preferences in
      let encoder = JSONEncoder()
      let data = try PersistedSchema.encode(preferences, using: encoder)
      try writeData(data, url)
    }
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// preferences file. Read-and-cleared by the caller (AppStore) so it can
  /// surface a one-time "your settings were reset" toast instead of failing
  /// silently.
  private(set) var didRecoverFromCorruptFile = false

  func load() -> UserPreferences {
    queue.sync {
      // A missing file is the normal first-launch case: return defaults without
      // writing anything yet.
      guard FileManager.default.fileExists(atPath: url.path) else {
        return UserPreferences()
      }
      PersistenceSecurity.secureExistingFile(at: url)
      do {
        // Check file size before loading
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
          logger.error("Preferences file exceeds size limit: \(fileSize) bytes")
          backupCorruptFile()
          didRecoverFromCorruptFile = true
          return UserPreferences()
        }

        let data = try Data(contentsOf: url)
        // UserPreferences decodes leniently by design (per-field forward
        // compat), so valid JSON of the wrong shape ([], null, a scalar) would
        // otherwise "load" as defaults and be overwritten on the next save.
        // Require a top-level object so those files take the backup path.
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
          logger.warning("Preferences file is not a JSON object. Preserving file and using defaults.")
          backupCorruptFile()
          didRecoverFromCorruptFile = true
          return UserPreferences()
        }
        return try PersistedSchema.decode(UserPreferences.self, from: data, using: decoder)
      } catch {
        // Preserve the unreadable file for recovery instead of silently
        // overwriting the user's saved preferences with defaults.
        logger.warning("Failed to load preferences: \(error.localizedDescription). Preserving file and using defaults.")
        backupCorruptFile()
        didRecoverFromCorruptFile = true
        return UserPreferences()
      }
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

  private func backupCorruptFile() {
    let backupURL = url.appendingPathExtension("corrupt")
    try? FileManager.default.removeItem(at: backupURL)
    do {
      try FileManager.default.moveItem(at: url, to: backupURL)
      try? PersistenceSecurity.setPrivateFilePermissions(backupURL)
      logger.warning("Moved unreadable preferences file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable preferences file: \(error.localizedDescription)")
    }
  }

  func save(_ preferences: UserPreferences) async throws {
    do {
      try await writer.save(preferences)
    } catch {
      logger.error("Failed to save preferences: \(error.localizedDescription)")
      throw error
    }
  }

  func flush() async throws {
    do {
      try await writer.flush()
    } catch {
      logger.error("Failed to flush preferences: \(error.localizedDescription)")
      throw error
    }
  }
}
