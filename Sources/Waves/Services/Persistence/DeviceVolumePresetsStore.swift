import Foundation
import OSLog

final class DeviceVolumePresetsStore: @unchecked Sendable {
  private let url: URL
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue: DispatchQueue
  private let writer: CoalescingPersistenceWriter<DeviceVolumePresets>

  convenience init(fileManager: FileManager = .default) {
    let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
    let url: URL
    if let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
      do {
        try PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
      } catch {
        logger.error("Failed to create volume presets directory: \(error.localizedDescription)")
      }
      url = directory.appendingPathComponent("deviceVolumePresets.json")
    } else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? PersistenceSecurity.preparePrivateDirectory(fallbackDirectory, fileManager: fileManager)
      url = fallbackDirectory.appendingPathComponent("deviceVolumePresets.json")
    }
    self.init(url: url, writeData: PrivateAtomicPersistenceFile.write)
  }

  /// Test-only entry point: keeps the store's file inside `directory` instead
  /// of the real Application Support location.
  convenience init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    try? PersistenceSecurity.preparePrivateDirectory(directory)
    self.init(
      url: directory.appendingPathComponent("deviceVolumePresets.json"),
      writeData: writeData
    )
  }

  private init(url: URL, writeData: @escaping PersistenceDataWrite) {
    self.url = url
    let queue = DispatchQueue(label: "com.waves.volumepresets.store", qos: .userInitiated)
    self.queue = queue
    self.writer = CoalescingPersistenceWriter(queue: queue) { presets in
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try PersistedSchema.encode(presets, using: encoder)
      try writeData(data, url)
    }
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// presets file. Read-and-cleared by the caller (AppStore) so it can surface
  /// a one-time "your presets were reset" toast instead of failing silently.
  private(set) var didRecoverFromCorruptFile = false

  func load() -> DeviceVolumePresets {
    queue.sync {
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
        return try PersistedSchema.decode(DeviceVolumePresets.self, from: data, using: decoder)
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

  func save(_ presets: DeviceVolumePresets) async throws {
    do {
      try await writer.save(presets)
    } catch {
      logger.error("Failed to save volume presets: \(error.localizedDescription)")
      throw error
    }
  }

  func flush() async throws {
    do {
      try await writer.flush()
    } catch {
      logger.error("Failed to flush volume presets: \(error.localizedDescription)")
      throw error
    }
  }
}
