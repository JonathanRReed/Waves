import Foundation
import OSLog

final class PreferencesStore: @unchecked Sendable {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.waves.preferences", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue = DispatchQueue(label: "com.waves.preferences.store", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
      url = fallbackDirectory.appendingPathComponent("preferences.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create preferences directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("preferences.json")
  }

  /// Test-only entry point: keeps the store's file inside `directory` instead
  /// of the real Application Support location.
  init(directory: URL) {
    url = directory.appendingPathComponent("preferences.json")
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// preferences file. Read-and-cleared by the caller (AppStore) so it can
  /// surface a one-time "your settings were reset" toast instead of failing
  /// silently.
  private(set) var didRecoverFromCorruptFile = false

  func load() -> UserPreferences {
    return queue.sync {
      // A missing file is the normal first-launch case: return defaults without
      // writing anything yet.
      guard FileManager.default.fileExists(atPath: url.path) else {
        return UserPreferences()
      }
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
        let preferences = try PersistedSchema.decode(UserPreferences.self, from: data, using: decoder)
        return preferences
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
      logger.warning("Moved unreadable preferences file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable preferences file: \(error.localizedDescription)")
    }
  }

  func save(_ preferences: UserPreferences) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let data = try PersistedSchema.encode(preferences, using: self.encoder)
        try data.write(to: self.url, options: .atomic)
      } catch {
        self.logger.error("Failed to save preferences: \(error.localizedDescription)")
      }
    }
  }

  /// Blocks until every write already queued by `save` has completed. For app
  /// termination only — a change made in the same instant as quit would
  /// otherwise be lost when the process exits mid-queue.
  func flush() {
    queue.sync {}
  }
}
