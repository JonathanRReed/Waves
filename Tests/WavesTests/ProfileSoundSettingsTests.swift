import Foundation
import Testing
import WavesAudioCore

@testable import Waves

// Profiles gained optional per-app EQ and output in 1.8. These tests pin the
// stored format in both directions: every 1.7.4 file reads unchanged and keeps
// leaving EQ and output alone, and a 1.8 file stays readable by 1.7.4.

/// `profiles.json` exactly as Waves 1.7.4 writes it: the schema-1 envelope,
/// a level-bearing profile, and a membership-only grouping.
private let profilesJSON174 = """
  {"schemaVersion":1,"payload":[\
  {"id":"8A1F6C2E-3B7D-4E59-9C10-2F4B6D8E0A11","name":"Meeting",\
  "entries":[{"appID":"us.zoom.xos","desiredVolume":1,"isMuted":false,"volumeBoost":1},\
  {"appID":"com.spotify.client","desiredVolume":0.2,"isMuted":true,"volumeBoost":1.5}],\
  "createdAt":784000000,"updatedAt":784000500},\
  {"id":"0C7E2D4B-91A3-4F6E-8B25-7D1E3C5A9F02","name":"Work",\
  "entries":[{"appID":"com.tinyspeck.slackmacgap"},{"appID":"com.apple.Safari"}],\
  "createdAt":784000000,"updatedAt":784000000}]}
  """

/// A single exported profile file as 1.7.4's Export… writes it (pretty-printed
/// schema-1 envelope around a one-element array).
private let exportedProfileJSON174 = """
  {
    "schemaVersion" : 1,
    "payload" : [
      {
        "id" : "5D3B9E71-2C84-4A06-B1F7-9E2A4C6D8B13",
        "name" : "Gaming",
        "entries" : [
          {
            "appID" : "com.hnc.Discord",
            "desiredVolume" : 0.65,
            "isMuted" : false
          },
          {
            "appID" : "com.valvesoftware.steam",
            "volumeBoost" : 2
          }
        ],
        "createdAt" : 784100000,
        "updatedAt" : 784100000
      }
    ]
  }
  """

@Test func profilesWrittenBy174DecodeUnchangedAndLeaveEqualizerAndOutputAlone() throws {
  let profiles = try ProfilePayloadDecoder.decodePersistedProfiles(
    from: Data(profilesJSON174.utf8),
    using: JSONDecoder()
  )

  #expect(profiles.map(\.name) == ["Meeting", "Work"])
  let meeting = profiles[0]
  #expect(meeting.id == UUID(uuidString: "8A1F6C2E-3B7D-4E59-9C10-2F4B6D8E0A11"))
  #expect(
    meeting.entries == [
      ProfileEntry(appID: "us.zoom.xos", desiredVolume: 1, isMuted: false, volumeBoost: 1),
      ProfileEntry(appID: "com.spotify.client", desiredVolume: 0.2, isMuted: true, volumeBoost: 1.5),
    ])
  #expect(meeting.carriesLevels)
  #expect(!meeting.carriesEqualizer)
  #expect(!meeting.carriesOutput)
  #expect(meeting.entries.allSatisfy { $0.equalizer == nil && $0.output == nil && !$0.restoresSound })
  #expect(meeting.createdAt == Date(timeIntervalSinceReferenceDate: 784_000_000))
  #expect(meeting.updatedAt == Date(timeIntervalSinceReferenceDate: 784_000_500))

  let work = profiles[1]
  #expect(!work.carriesLevels)
  #expect(work.entries.allSatisfy { !$0.hasLevels })
}

@Test func exportedProfileFileFrom174ImportsUnchanged() throws {
  let profiles = try #require(AppStore.decodeImportedProfiles(from: Data(exportedProfileJSON174.utf8)))

  #expect(profiles.count == 1)
  #expect(
    profiles.first?.entries == [
      ProfileEntry(appID: "com.hnc.Discord", desiredVolume: 0.65, isMuted: false),
      ProfileEntry(appID: "com.valvesoftware.steam", volumeBoost: 2),
    ])
  #expect(profiles.first?.entries.contains { $0.restoresSound } == false)
}

@Test func profileStoreLoads174FileFromDiskAndRewritesItWithoutNewKeys() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-profiles-174-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try Data(profilesJSON174.utf8).write(to: directory.appendingPathComponent("profiles.json"))

  let store = ProfileStore(directory: directory)
  let loaded = store.load(defaults: [])
  #expect(loaded.map(\.name) == ["Meeting", "Work"])

  // Saving an untouched 1.7.4 profile must not grow EQ or output keys, so the
  // file means exactly what it meant before.
  let data = try PersistedSchema.encode(loaded, using: JSONEncoder())
  let text = String(decoding: data, as: UTF8.self)
  #expect(!text.contains("equalizer"))
  #expect(!text.contains("output"))
}

@Test func soundEntriesRoundTripAndSystemDefaultStaysDistinctFromLeaveAlone() throws {
  var equalizer = EqualizerSettings(isEnabled: true)
  equalizer.setGain(4, at: 1)
  let profile = Profile(
    name: "Movie",
    entries: [
      ProfileEntry(
        appID: "com.apple.TV",
        desiredVolume: 0.7,
        equalizer: equalizer,
        output: ProfileOutput(deviceUID: "airpods-uid", deviceName: "AirPods Pro")
      ),
      ProfileEntry(appID: "com.apple.Music", desiredVolume: 0.4, output: .systemDefault),
      ProfileEntry(appID: "com.apple.Safari", desiredVolume: 0.3),
    ]
  )

  let data = try PersistedSchema.encode([profile], using: JSONEncoder())
  let decoded = try ProfilePayloadDecoder.decodePersistedProfiles(from: data, using: JSONDecoder())

  #expect(decoded == [profile])
  #expect(decoded[0].entries[1].output == .systemDefault)
  #expect(decoded[0].entries[1].output?.deviceUID == nil)
  #expect(decoded[0].entries[2].output == nil)
  #expect(decoded[0].carriesEqualizer)
  #expect(decoded[0].carriesOutput)
}

/// The keyed decode 1.7.4 ships for a profile entry. 1.7.4 rejects a file
/// whose schema version is newer than 1, and otherwise ignores keys it does
/// not know, so a 1.8 file must stay on schema 1 and keep the old keys.
private struct ProfileEntry174: Decodable, Equatable {
  let appID: String
  let desiredVolume: Float?
  let isMuted: Bool?
  let volumeBoost: Float?
}

private struct Envelope174: Decodable {
  struct Profile174: Decodable {
    let id: UUID
    let name: String
    let entries: [ProfileEntry174]
  }

  let schemaVersion: Int
  let payload: [Profile174]
}

@Test func profileWrittenBy18StaysReadableBy174() throws {
  let profile = Profile(
    name: "Movie",
    entries: [
      ProfileEntry(
        appID: "com.apple.TV",
        desiredVolume: 0.7,
        isMuted: false,
        volumeBoost: 1,
        equalizer: EqualizerSettings(isEnabled: true),
        output: ProfileOutput(deviceUID: "airpods-uid", deviceName: "AirPods Pro")
      )
    ]
  )

  let data = try PersistedSchema.encode([profile], using: JSONEncoder())
  let old = try JSONDecoder().decode(Envelope174.self, from: data)

  #expect(old.schemaVersion == 1)
  #expect(old.payload.first?.name == "Movie")
  #expect(
    old.payload.first?.entries
      == [ProfileEntry174(appID: "com.apple.TV", desiredVolume: 0.7, isMuted: false, volumeBoost: 1)])
}

@Test func savedContentsPhraseNamesWhatAProfileRestores() {
  let group = Profile(name: "Group", entries: [ProfileEntry(appID: "a")])
  let levels = Profile(name: "Levels", entries: [ProfileEntry(appID: "a", desiredVolume: 0.5)])
  let sound = Profile(
    name: "Sound",
    entries: [
      ProfileEntry(appID: "a", desiredVolume: 0.5, equalizer: EqualizerSettings()),
      ProfileEntry(appID: "b", desiredVolume: 0.5, output: .systemDefault),
    ]
  )
  let equalizerOnly = Profile(
    name: "EQ", entries: [ProfileEntry(appID: "a", desiredVolume: 0.5, equalizer: EqualizerSettings())])

  #expect(group.savedContentsPhrase == nil)
  #expect(levels.savedContentsPhrase == "levels")
  #expect(equalizerOnly.savedContentsPhrase == "levels and EQ")
  #expect(sound.savedContentsPhrase == "levels, EQ, and outputs")
}

@Test func listPhraseShortensLongAppLists() {
  #expect(AppStore.listPhrase(["Music"]) == "Music")
  #expect(AppStore.listPhrase(["Music", "Zoom"]) == "Music and Zoom")
  #expect(AppStore.listPhrase(["Music", "Zoom", "Safari"]) == "Music, Zoom, and Safari")
  #expect(AppStore.listPhrase(["A", "B", "C", "D", "E"]) == "A, B, and 3 more")
}
