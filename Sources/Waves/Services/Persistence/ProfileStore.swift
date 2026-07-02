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

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// profiles file. Read-and-cleared by the caller (AppStore) so it can
  /// surface a one-time "your profiles were reset" toast instead of failing
  /// silently.
  private(set) var didRecoverFromCorruptFile = false

  func load(defaults: [Profile]) -> [Profile] {
    return queue.sync {
      let fileManager = FileManager.default

      // First launch after the Presets→Profiles rename: adopt the old file if a
      // new one doesn't exist yet, so saved mixes survive the upgrade.
      if !fileManager.fileExists(atPath: url.path),
         fileManager.fileExists(atPath: legacyURL.path) {
        if let migrated = loadFile(at: legacyURL) {
          // Written synchronously (we already hold the queue — an enqueued
          // save couldn't run until load() returns) and the legacy file is
          // retired only AFTER the new file is durably on disk: otherwise a
          // crash between the rename and the deferred write would leave
          // neither file, silently losing every saved profile. Retired =
          // renamed rather than deleted, so a future corrupt profiles.json
          // can't silently resurrect stale pre-rename data as current while
          // the contents stay recoverable by hand.
          do {
            let data = try PersistedSchema.encode(migrated, using: encoder)
            try data.write(to: url, options: .atomic)
            retireLegacyFile()
          } catch {
            // Leave presets.json in place so migration retries next launch.
            logger.error("Failed to persist migrated profiles: \(error.localizedDescription)")
          }
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
    } catch {
      logger.error("Failed to retire migrated legacy presets file: \(error.localizedDescription)")
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

  /// Blocks until every write already queued by `save` has completed. For app
  /// termination only — a change made in the same instant as quit would
  /// otherwise be lost when the process exits mid-queue.
  func flush() {
    queue.sync {}
  }
}
