import Foundation
import OSLog

final class DeviceVolumePresetsStore: @unchecked Sendable {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.waves.volumepresets", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue = DispatchQueue(label: "com.waves.volumepresets.store", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? PersistenceSecurity.preparePrivateDirectory(fallbackDirectory, fileManager: fileManager)
      url = fallbackDirectory.appendingPathComponent("deviceVolumePresets.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
    } catch {
      logger.error("Failed to create volume presets directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("deviceVolumePresets.json")
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// presets file. Read-and-cleared by the caller (AppStore) so it can surface
  /// a one-time "your presets were reset" toast instead of failing silently.
  private(set) var didRecoverFromCorruptFile = false

  func load() -> DeviceVolumePresets {
    return queue.sync {
      // A missing file is the normal first-launch case: return defaults without
      // writing anything yet.
      guard FileManager.default.fileExists(atPath: url.path) else {
        return DeviceVolumePresets()
      }
      PersistenceSecurity.secureExistingFile(at: url)
      do {
        // Check file size before loading
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
          logger.error("Volume presets file exceeds size limit: \(fileSize) bytes")
          backupCorruptFile()
          didRecoverFromCorruptFile = true
          return DeviceVolumePresets()
        }

        let data = try Data(contentsOf: url)
        let presets = try PersistedSchema.decode(DeviceVolumePresets.self, from: data, using: decoder)
        return presets
      } catch {
        // Preserve the unreadable file for recovery instead of wiping the
        // user's saved per-device volumes.
        logger.warning("Failed to load volume presets: \(error.localizedDescription). Preserving file and using defaults.")
        backupCorruptFile()
        didRecoverFromCorruptFile = true
        return DeviceVolumePresets()
      }
    }
  }

  /// Reads and clears `didRecoverFromCorruptFile`, so a caller can check once
  /// (e.g. right after `load()` at startup) without the flag lingering true
  /// across later, unrelated reconciliation calls.
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
      logger.warning("Moved unreadable volume presets file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable volume presets file: \(error.localizedDescription)")
    }
  }

  func save(_ presets: DeviceVolumePresets) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        self.encoder.outputFormatting = .prettyPrinted
        let data = try PersistedSchema.encode(presets, using: self.encoder)
        try data.write(to: self.url, options: .atomic)
        try PersistenceSecurity.setPrivateFilePermissions(self.url)
      } catch {
        self.logger.error("Failed to save volume presets: \(error.localizedDescription)")
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
