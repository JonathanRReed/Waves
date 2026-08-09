import Foundation
import WavesAudioCore

final class SessionStore: @unchecked Sendable {
  private let engine: JSONPersistenceEngine<AudioSessionSnapshot>

  convenience init(fileManager: FileManager = .default) {
    self.init(
      url: PersistenceLocation.applicationSupportDirectory(fileManager: fileManager)
        .appendingPathComponent("session.json"),
      fileManager: fileManager,
      writeData: PrivateAtomicPersistenceFile.write
    )
  }

  /// Test-only entry point: keeps the store's file inside `directory` instead
  /// of the real Application Support location.
  convenience init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    self.init(
      url: directory.appendingPathComponent("session.json"),
      fileManager: .default,
      writeData: writeData
    )
  }

  private init(
    url: URL,
    fileManager: FileManager,
    writeData: @escaping PersistenceDataWrite
  ) {
    engine = JSONPersistenceEngine(
      url: url,
      queueLabel: "com.waves.session.store",
      displayName: "session",
      fileManager: fileManager,
      writeData: writeData,
      codec: JSONPersistenceCodec(
        encode: { snapshot in
          try SessionPayloadCodec.encode(
            Self.persistencePayload(from: snapshot),
            using: JSONEncoder()
          )
        },
        decode: { data in
          try SessionPayloadCodec.decode(from: data, using: JSONDecoder())
        }
      )
    )
  }

  func load() -> AudioSessionSnapshot? {
    guard case .loaded(var snapshot) = engine.load() else { return nil }
    snapshot.backendStatus = .unprobed
    return snapshot
  }

  func consumeDidRecoverFromCorruptFile() -> Bool {
    engine.consumeDidRecoverFromCorruptFile()
  }

  func save(_ snapshot: AudioSessionSnapshot) async throws {
    try await engine.save(snapshot)
  }

  func flush() async throws {
    try await engine.flush()
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
          targetDeviceUID: app.targetDeviceUID,
          routeHealthContext: app.routeHealthContext
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
