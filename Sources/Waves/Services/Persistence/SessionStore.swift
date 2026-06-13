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
      try? fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
      url = fallbackDirectory.appendingPathComponent("session.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create session directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("session.json")
  }

  func load() -> AudioSessionSnapshot? {
    return queue.sync {
      do {
        // Check file size before loading
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
          logger.error("Session file exceeds size limit: \(fileSize) bytes")
          return nil
        }

        let data = try Data(contentsOf: url)
        let snapshot = try PersistedSchema.decode(AudioSessionSnapshot.self, from: data, using: decoder)
        return snapshot
      } catch {
        logger.warning("Failed to load session: \(error.localizedDescription)")
        return nil
      }
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
            volumeBoost: app.volumeBoost
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
      } catch {
        self.logger.error("Failed to save session: \(error.localizedDescription)")
      }
    }
  }
}
