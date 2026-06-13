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
          return UserPreferences()
        }

        let data = try Data(contentsOf: url)
        let preferences = try PersistedSchema.decode(UserPreferences.self, from: data, using: decoder)
        return preferences
      } catch {
        // Preserve the unreadable file for recovery instead of silently
        // overwriting the user's saved preferences with defaults.
        logger.warning("Failed to load preferences: \(error.localizedDescription). Preserving file and using defaults.")
        backupCorruptFile()
        return UserPreferences()
      }
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
}
