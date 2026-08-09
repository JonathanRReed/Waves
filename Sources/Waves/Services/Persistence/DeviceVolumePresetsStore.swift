import Foundation

final class DeviceVolumePresetsStore: @unchecked Sendable {
  private let engine: JSONPersistenceEngine<DeviceVolumePresets>

  convenience init(fileManager: FileManager = .default) {
    self.init(
      url: PersistenceLocation.applicationSupportDirectory(fileManager: fileManager)
        .appendingPathComponent("deviceVolumePresets.json"),
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
      url: directory.appendingPathComponent("deviceVolumePresets.json"),
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
      queueLabel: "com.waves.volumepresets.store",
      displayName: "device volume presets",
      fileManager: fileManager,
      writeData: writeData,
      codec: JSONPersistenceCodec(
        encode: { presets in
          let encoder = JSONEncoder()
          encoder.outputFormatting = .prettyPrinted
          return try PersistedSchema.encode(presets, using: encoder)
        },
        decode: { data in
          try PersistedSchema.decode(
            DeviceVolumePresets.self,
            from: data,
            using: JSONDecoder()
          )
        }
      )
    )
  }

  func load() -> DeviceVolumePresets {
    switch engine.load() {
    case .loaded(let presets): presets
    case .missing, .recoveredFromCorruption: DeviceVolumePresets()
    }
  }

  func consumeDidRecoverFromCorruptFile() -> Bool {
    engine.consumeDidRecoverFromCorruptFile()
  }

  func save(_ presets: DeviceVolumePresets) async throws {
    try await engine.save(presets)
  }

  func flush() async throws {
    try await engine.flush()
  }
}
