import Foundation
import OSLog
import WavesAudioCore

final class ProfileStore: @unchecked Sendable {
  private let url: URL
  /// Legacy location from when profiles were called "presets". Migrated on first
  /// load so existing users keep their saved mixes.
  private let legacyURL: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.waves.profiles", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue = DispatchQueue(label: "com.waves.profiles.store", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
      url = fallbackDirectory.appendingPathComponent("profiles.json")
      legacyURL = fallbackDirectory.appendingPathComponent("presets.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create profiles directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("profiles.json")
    legacyURL = directory.appendingPathComponent("presets.json")
  }

  func load(defaults: [Profile]) -> [Profile] {
    return queue.sync {
      let fileManager = FileManager.default

      // First launch after the Presets→Profiles rename: adopt the old file if a
      // new one doesn't exist yet, so saved mixes survive the upgrade.
      if !fileManager.fileExists(atPath: url.path),
         fileManager.fileExists(atPath: legacyURL.path) {
        if let migrated = loadFile(at: legacyURL) {
          save(migrated)
          return migrated
        }
      }

      // A missing file is the normal first-launch case: seed defaults on disk.
      guard fileManager.fileExists(atPath: url.path) else {
        save(defaults)
        return defaults
      }

      return loadFile(at: url) ?? defaults
    }
  }

  private func loadFile(at fileURL: URL) -> [Profile]? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
        logger.error("Profiles file exceeds size limit: \(fileSize) bytes")
        backupCorruptFile(fileURL)
        return nil
      }

      let data = try Data(contentsOf: fileURL)
      return try PersistedSchema.decode([Profile].self, from: data, using: decoder)
    } catch {
      // Preserve the unreadable file for recovery instead of destroying the
      // user's saved profiles.
      logger.warning("Failed to load profiles at \(fileURL.lastPathComponent): \(error.localizedDescription). Preserving file.")
      backupCorruptFile(fileURL)
      return nil
    }
  }

  private func backupCorruptFile(_ fileURL: URL) {
    let backupURL = fileURL.appendingPathExtension("corrupt")
    try? FileManager.default.removeItem(at: backupURL)
    do {
      try FileManager.default.moveItem(at: fileURL, to: backupURL)
      logger.warning("Moved unreadable profiles file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable profiles file: \(error.localizedDescription)")
    }
  }

  func save(_ profiles: [Profile]) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let data = try PersistedSchema.encode(profiles, using: self.encoder)
        try data.write(to: self.url, options: .atomic)
      } catch {
        self.logger.error("Failed to save profiles: \(error.localizedDescription)")
      }
    }
  }
}
