import Foundation
import OSLog
import WavesAudioCore

final class PresetStore: @unchecked Sendable {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.waves.presets", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue = DispatchQueue(label: "com.waves.presets.store", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
      url = fallbackDirectory.appendingPathComponent("presets.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create presets directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("presets.json")
  }

  func load(defaults: [Preset]) -> [Preset] {
    return queue.sync {
      // A missing file is the normal first-launch case: seed defaults on disk.
      guard FileManager.default.fileExists(atPath: url.path) else {
        save(defaults)
        return defaults
      }
      do {
        // Check file size before loading
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
          logger.error("Presets file exceeds size limit: \(fileSize) bytes")
          backupCorruptFile()
          return defaults
        }

        let data = try Data(contentsOf: url)
        let presets = try PersistedSchema.decode([Preset].self, from: data, using: decoder)
        return presets
      } catch {
        // Preserve the unreadable file for recovery instead of destroying the
        // user's saved presets.
        logger.warning("Failed to load presets: \(error.localizedDescription). Preserving file and using defaults.")
        backupCorruptFile()
        return defaults
      }
    }
  }

  private func backupCorruptFile() {
    let backupURL = url.appendingPathExtension("corrupt")
    try? FileManager.default.removeItem(at: backupURL)
    do {
      try FileManager.default.moveItem(at: url, to: backupURL)
      logger.warning("Moved unreadable presets file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable presets file: \(error.localizedDescription)")
    }
  }

  func save(_ presets: [Preset]) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let data = try PersistedSchema.encode(presets, using: self.encoder)
        try data.write(to: self.url, options: .atomic)
      } catch {
        self.logger.error("Failed to save presets: \(error.localizedDescription)")
      }
    }
  }
}
