import Foundation
import OSLog
import WavesAudioCore

final class SessionStore: @unchecked Sendable {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.waves.session", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue = DispatchQueue(label: "com.waves.session.store", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      logger.error("Failed to get application support directory")
      let fallbackDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
      try? PersistenceSecurity.preparePrivateDirectory(fallbackDirectory, fileManager: fileManager)
      url = fallbackDirectory.appendingPathComponent("session.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
    } catch {
      logger.error("Failed to create session directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("session.json")
  }

  /// Test-only entry point: keeps the store's file inside `directory` instead
  /// of the real Application Support location.
  init(directory: URL) {
    try? PersistenceSecurity.preparePrivateDirectory(directory)
    url = directory.appendingPathComponent("session.json")
  }

  /// Set to true the moment `load()` has to back up and discard an unreadable
  /// session file. Read-and-cleared by the caller (AppStore) so it can
  /// surface a one-time "your session was reset" toast instead of failing
  /// silently.
  private(set) var didRecoverFromCorruptFile = false

  func load() -> AudioSessionSnapshot? {
    return queue.sync {
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
        let snapshot = try PersistedSchema.decode(AudioSessionSnapshot.self, from: data, using: decoder)
        return snapshot
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

  func save(_ snapshot: AudioSessionSnapshot) {
    queue.async { [weak self] in
      guard let self else { return }
      // Manual mapping to exclude iconTIFFData from session persistence for space efficiency.
      // This is intentional - icon data is large and can be regenerated on app launch.
      // If AudioApp fields are added, they must be mapped here.
      let payload = AudioSessionSnapshot(
        apps: snapshot.apps.map { app in
          AudioApp(
            id: app.id,
            logicalID: app.logicalID,
            pid: app.pid,
            bundleID: app.bundleID,
            displayName: app.displayName,
            iconName: app.iconName,
            iconTIFFData: nil, // Excluded to save space
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

      do {
        let data = try PersistedSchema.encode(payload, using: self.encoder)
        try data.write(to: self.url, options: .atomic)
        try PersistenceSecurity.setPrivateFilePermissions(self.url)
      } catch {
        self.logger.error("Failed to save session: \(error.localizedDescription)")
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
