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
  // Presets were historically stored as a bare JSON array.
  let legacy = Data("[]".utf8)
  let decoded = try PersistedSchema.decode([Preset].self, from: legacy, using: JSONDecoder())
  #expect(decoded.isEmpty)
}
