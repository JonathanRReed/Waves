import Foundation

final class PreferencesStore: @unchecked Sendable {
  private let engine: JSONPersistenceEngine<UserPreferences>

  convenience init(fileManager: FileManager = .default) {
    let directory = PersistenceLocation.applicationSupportDirectory(fileManager: fileManager)
    self.init(
      url: directory.appendingPathComponent("preferences.json"),
      fileManager: fileManager,
      writeData: PrivateAtomicPersistenceFile.write
    )
  }

  /// Test-only entry point: keeps the store's file inside `directory` instead
  /// of the real Application Support location. `writeData` is injectable so
  /// focused tests can verify that asynchronous write failures reach callers.
  convenience init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    self.init(
      url: directory.appendingPathComponent("preferences.json"),
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
      queueLabel: "com.waves.preferences.store",
      displayName: "preferences",
      fileManager: fileManager,
      writeData: writeData,
      codec: JSONPersistenceCodec(
        encode: { preferences in
          try PersistedSchema.encode(preferences, using: JSONEncoder())
        },
        decode: { data in
          // UserPreferences decodes additively field by field, so reject a
          // wrong-shaped top level before it can masquerade as defaults.
          guard (try JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw DecodingError.dataCorrupted(
              .init(codingPath: [], debugDescription: "Preferences payload is not a JSON object.")
            )
          }
          return try PersistedSchema.decode(
            UserPreferences.self,
            from: data,
            using: JSONDecoder()
          )
        }
      )
    )
  }

  func load() -> UserPreferences {
    switch engine.load() {
    case .loaded(let preferences): preferences
    case .missing, .recoveredFromCorruption: UserPreferences()
    }
  }

  func consumeDidRecoverFromCorruptFile() -> Bool {
    engine.consumeDidRecoverFromCorruptFile()
  }

  func save(_ preferences: UserPreferences) async throws {
    try await engine.save(preferences)
  }

  func flush() async throws {
    try await engine.flush()
  }
}
