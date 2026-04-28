import Foundation
import WavesAudioCore

struct SessionStore {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(fileManager: FileManager = .default) {
    let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("session.json")
  }

  func load() -> AudioSessionSnapshot? {
    guard let data = try? Data(contentsOf: url),
          let snapshot = try? decoder.decode(AudioSessionSnapshot.self, from: data)
    else {
      return nil
    }

    return snapshot
  }

  func save(_ snapshot: AudioSessionSnapshot) {
    let payload = AudioSessionSnapshot(
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
          notes: app.notes
        )
      },
      currentDevice: snapshot.currentDevice,
      recentDeviceIDs: snapshot.recentDeviceIDs,
      supportMatrix: snapshot.supportMatrix,
      backendStatus: snapshot.backendStatus,
      updatedAt: snapshot.updatedAt
    )

    guard let data = try? encoder.encode(payload) else {
      return
    }

    try? data.write(to: url, options: .atomic)
  }
}
