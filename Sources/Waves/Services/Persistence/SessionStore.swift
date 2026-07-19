import Foundation
import OSLog
import WavesAudioCore

final class SessionStore: @unchecked Sendable {
  private let url: URL
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue: DispatchQueue
  private let writer: CoalescingPersistenceWriter<AudioSessionSnapshot>

  convenience init(fileManager: FileManager = .default) {
    let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
    let url: URL
    if let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
      do {
        try PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
      } catch {
        logger.error("Failed to create session directory: \(error.localizedDescription)")
      }
      url = directory.appendingPathComponent("session.json")
    } else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? PersistenceSecurity.preparePrivateDirectory(fallbackDirectory, fileManager: fileManager)
      url = fallbackDirectory.appendingPathComponent("session.json")
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
      url: directory.appendingPathComponent("session.json"),
      writeData: writeData
    )
  }

  private init(url: URL, writeData: @escaping PersistenceDataWrite) {
    self.url = url
    let queue = DispatchQueue(label: "com.waves.session.store", qos: .userInitiated)
    self.queue = queue
    self.writer = CoalescingPersistenceWriter(queue: queue) { snapshot in
      let payload = Self.persistencePayload(from: snapshot)
      let encoder = JSONEncoder()
      let data = try PersistedSchema.encode(payload, using: encoder)
      try writeData(data, url)
    }
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// session file. Read-and-cleared by the caller (AppStore) so it can
  /// surface a one-time "your session was reset" toast instead of failing
  /// silently.
  private(set) var didRecoverFromCorruptFile = false

  func load() -> AudioSessionSnapshot? {
    queue.sync {
      // A missing file is the normal first-launch case: no session to restore,
      // and nothing to log or back up.
      guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
      }
      PersistenceSecurity.secureExistingFile(at: url)
      do {
        // Check file size before loading
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
          logger.error("Session file exceeds size limit: \(fileSize) bytes")
          backupCorruptFile()
          didRecoverFromCorruptFile = true
          return nil
        }

        let data = try Data(contentsOf: url)
        return try PersistedSchema.decode(AudioSessionSnapshot.self, from: data, using: decoder)
      } catch {
        // Preserve the unreadable file for recovery instead of letting the next
        // save overwrite it (e.g. a session.json from a newer schema version).
        logger.warning("Failed to load session: \(error.localizedDescription). Preserving file and using defaults.")
        backupCorruptFile()
        didRecoverFromCorruptFile = true
        return nil
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
      logger.warning("Moved unreadable session file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to back up unreadable session file: \(error.localizedDescription)")
    }
  }

  func save(_ snapshot: AudioSessionSnapshot) async throws {
    do {
      try await writer.save(snapshot)
    } catch {
      logger.error("Failed to save session: \(error.localizedDescription)")
      throw error
    }
  }

  func flush() async throws {
    do {
      try await writer.flush()
    } catch {
      logger.error("Failed to flush session: \(error.localizedDescription)")
      throw error
    }
  }

  private static func persistencePayload(from snapshot: AudioSessionSnapshot) -> AudioSessionSnapshot {
    // Manual mapping excludes iconTIFFData from session persistence for space
    // efficiency. Icon data is large and can be regenerated on app launch. If
    // AudioApp fields are added, they must be mapped here.
    AudioSessionSnapshot(
      apps: snapshot.apps.map { app in
        AudioApp(
          id: app.id,
          logicalID: app.logicalID,
          pid: app.pid,
          bundleID: app.bundleID,
          displayName: app.displayName,
          iconName: app.iconName,
          iconTIFFData: nil,
          category: app.category,
          isActive: app.isActive,
          peakLevel: app.peakLevel,
          rmsLevel: app.rmsLevel,
          desiredVolume: app.desiredVolume,
          appliedVolume: app.appliedVolume,
          isMuted: app.isMuted,
          isPinned: app.isPinned,
          routingState: app.routingState,
          compatibility: app.compatibility,
          notes: app.notes,
          volumeBoost: app.volumeBoost,
          muteSource: app.muteSource,
          targetDeviceUID: app.targetDeviceUID
        )
      },
      currentDevice: snapshot.currentDevice,
      recentDeviceIDs: snapshot.recentDeviceIDs,
      supportMatrix: snapshot.supportMatrix,
      backendStatus: snapshot.backendStatus,
      updatedAt: snapshot.updatedAt
    )
  }
}
