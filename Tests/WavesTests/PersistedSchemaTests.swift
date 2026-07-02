import Foundation
import Testing

@testable import Waves
import WavesAudioCore

@Test func versionedEnvelopeRoundTrips() throws {
  var prefs = UserPreferences()
  prefs.enableURLScheme = true
  prefs.sortMode = .category

  let data = try PersistedSchema.encode(prefs, using: JSONEncoder())
  let decoded = try PersistedSchema.decode(UserPreferences.self, from: data, using: JSONDecoder())

  #expect(decoded.enableURLScheme == true)
  #expect(decoded.sortMode == .category)
}

@Test func encodedPayloadCarriesSchemaVersion() throws {
  let data = try PersistedSchema.encode(UserPreferences(), using: JSONEncoder())
  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
  #expect(json?["schemaVersion"] as? Int == PersistedSchema.current)
  #expect(json?["payload"] != nil)
}

@Test func decodeAcceptsLegacyUnversionedFile() throws {
  // A file written before envelopes existed is a bare payload with no
  // schemaVersion wrapper; it must still decode.
  let legacy = Data("""
  { "showRecentApps": false, "sortMode": "activity" }
  """.utf8)
  let decoded = try PersistedSchema.decode(UserPreferences.self, from: legacy, using: JSONDecoder())
  #expect(decoded.showRecentApps == false)
  #expect(decoded.sortMode == .activity)
}

@Test func decodeAcceptsLegacyUnversionedArray() throws {
  // Profiles (formerly presets) were historically stored as a bare JSON array.
  let legacy = Data("[]".utf8)
  let decoded = try PersistedSchema.decode([Profile].self, from: legacy, using: JSONDecoder())
  #expect(decoded.isEmpty)
}

// MARK: - Store corrupt-file recovery

private func makeTemporaryStoreDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("WavesStoreTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@Test func preferencesStoreBacksUpValidJSONOfWrongShape() throws {
  // UserPreferences decodes leniently field-by-field, so a wrong-shape file
  // ([], null, scalar) produces no decode error; the store must still treat it
  // as corrupt — backing it up rather than letting the next save overwrite it.
  let directory = try makeTemporaryStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let fileURL = directory.appendingPathComponent("preferences.json")
  try Data("[]".utf8).write(to: fileURL)

  let store = PreferencesStore(directory: directory)
  let prefs = store.load()

  #expect(prefs.showRecentApps == true) // defaults
  #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("corrupt").path))
  #expect(store.consumeDidRecoverFromCorruptFile() == true)
  #expect(store.consumeDidRecoverFromCorruptFile() == false) // read-and-cleared
}

@Test func sessionStoreTreatsMissingFileAsFirstLaunch() throws {
  // A fresh install has no session.json; that must not be reported (or logged)
  // as corruption recovery, and no .corrupt backup should appear.
  let directory = try makeTemporaryStoreDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let store = SessionStore(directory: directory)

  #expect(store.load() == nil)
  #expect(store.consumeDidRecoverFromCorruptFile() == false)
  let backupURL = directory.appendingPathComponent("session.json").appendingPathExtension("corrupt")
  #expect(!FileManager.default.fileExists(atPath: backupURL.path))
}
