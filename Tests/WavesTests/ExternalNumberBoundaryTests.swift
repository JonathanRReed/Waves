import Foundation
import Testing
import WavesAudioCore

@testable import Waves

// One contract for numbers that arrive from outside Waves. Every boundary that
// takes a volume or boost from another process or from disk is fed the same
// hostile values, and each must either refuse them or land on its documented
// fallback. Nothing may come out non-finite or outside the range the UI allows.

private let hostileDoubles: [Double] = [
  .nan, .infinity, -.infinity, -0.5, -1e39, 1.5, 4.5, 1e39, .greatestFiniteMagnitude,
]

// MARK: - The helper itself

@Test func levelRangeValidatedRefusesEverythingOutsideItsBounds() {
  for range in [LevelRange.volume, .boost, .equalizerGainDB] {
    for value in hostileDoubles where !(value >= Double(range.bounds.lowerBound) && value <= Double(range.bounds.upperBound)) {
      #expect(range.validated(value) == nil, "\(value) should be refused for \(range.bounds)")
    }
    #expect(range.validated(Double(range.bounds.lowerBound)) == range.bounds.lowerBound)
    #expect(range.validated(Double(range.bounds.upperBound)) == range.bounds.upperBound)
  }
  #expect(LevelRange.volume.validated(0.42) == 0.42)
  #expect(LevelRange.boost.validated(2.5) == 2.5)
  #expect(LevelRange.equalizerGainDB.validated(-12.5) == nil)
}

@Test func levelRangeTextParsingRefusesNonNumbersAndOverlongInput() {
  for text in ["nan", "NaN", "inf", "-inf", "infinity", "", " 0.5", "0.5x", "1e39", "1e400", "-0.0001"] {
    #expect(LevelRange.volume.validated(text: text) == nil, "\(text) should be refused")
  }
  #expect(LevelRange.volume.validated(text: nil) == nil)
  #expect(LevelRange.volume.validated(text: "0." + String(repeating: "5", count: 40)) == nil)
  #expect(LevelRange.volume.validated(text: "0.25") == 0.25)
  #expect(LevelRange.boost.validated(text: "4") == 4)
  #expect(LevelRange.boost.validated(text: "0.5") == nil)
}

@Test func levelRangeSanitizedAlwaysLandsInsideItsBounds() {
  for range in [LevelRange.volume, .boost, .equalizerGainDB] {
    for value in hostileDoubles {
      let result = range.sanitized(value)
      #expect(result.isFinite)
      #expect(range.bounds.contains(result), "\(value) sanitized to \(result) for \(range.bounds)")
    }
    #expect(range.sanitized(Double.nan) == range.fallback)
    #expect(range.sanitized(Optional<Double>.none) == range.fallback)
    #expect(range.clamped(Double.infinity) == nil)
  }
  #expect(LevelRange.volume.sanitized(-0.5) == 0)
  #expect(LevelRange.volume.sanitized(1e39) == 1)
  #expect(LevelRange.boost.sanitized(0.5) == 1)
  #expect(LevelRange.boost.sanitized(9.0) == 4)
}

// MARK: - URL scheme

@MainActor
@Test func urlSetVolumeRefusesEveryHostileNumber() {
  for text in ["nan", "inf", "-inf", "-0.5", "1.5", "1e39", "1e400", "-1e39"] {
    let parser = AutomationCommandParser()
    let url = URL(string: "waves://set-volume?app=com.example.app&volume=\(text)")!
    guard case .rejected = parser.parse(url) else {
      Issue.record("waves://set-volume accepted volume=\(text)")
      continue
    }
  }
  let parser = AutomationCommandParser()
  #expect(
    parser.parse(URL(string: "waves://set-volume?app=com.example.app&volume=0.3")!)
      == .accepted(.setVolume(appID: "com.example.app", volume: 0.3)))
}

// MARK: - Control socket

@Test func socketDecodingRefusesNumbersFloatCannotHold() {
  // JSON cannot carry NaN or infinity, and a number too large for Float fails
  // decoding, which the connection reports as malformed-request.
  for literal in ["1e39", "-1e39", "1e400"] {
    let line = Data(#"{"id":1,"cmd":"set-volume","app":"a","volume":\#(literal)}"#.utf8)
    #expect(ControlCodec.decode(line) == nil, "volume \(literal) should not decode")
  }
  for literal in ["NaN", "Infinity", "\"NaN\""] {
    let line = Data(#"{"id":1,"cmd":"set-volume","app":"a","volume":\#(literal)}"#.utf8)
    #expect(ControlCodec.decode(line) == nil, "volume \(literal) should not decode")
  }
}

@MainActor
@Test func socketSetVolumeClampsFiniteValuesAndRefusesNonFiniteOnes() async {
  let store = await makeControlStoreFixture()
  store.preferences.enableExternalControl = true
  let handler = ControlCommandHandler(store: store)
  let session = ControlCommandHandler.Session(didHandshake: true)
  let appID = "com.example.render"

  for value: Float in [.nan, .infinity, -.infinity] {
    let set = await handler.handle(
      ControlRequest(id: 1, cmd: .setVolume, app: appID, volume: value), session: session)
    #expect(set.response == .failure(id: 1, .missingParameter))
    let adjust = await handler.handle(
      ControlRequest(id: 2, cmd: .adjustVolume, app: appID, delta: value), session: session)
    #expect(adjust.response == .failure(id: 2, .missingParameter))
  }

  // Protocol 1 documents clamping for a finite volume; it can never exceed 1.
  for (value, expected): (Float, Float) in [(-0.5, 0), (1.5, 1), (.greatestFiniteMagnitude, 1), (-.greatestFiniteMagnitude, 0)] {
    let set = await handler.handle(
      ControlRequest(id: 3, cmd: .setVolume, app: appID, volume: value), session: session)
    #expect(set.response.ok)
    #expect(set.response.volume == expected)
  }
  for (delta, expected): (Float, Float) in [(.greatestFiniteMagnitude, 1), (-.greatestFiniteMagnitude, 0)] {
    let adjust = await handler.handle(
      ControlRequest(id: 4, cmd: .adjustVolume, app: appID, delta: delta), session: session)
    #expect(adjust.response.ok)
    #expect(adjust.response.volume == expected)
  }
}

// MARK: - Persisted preferences

@Test func persistedVolumeSettingsFallBackOrClampForEveryHostileNumber() throws {
  for value in [Float.nan, .infinity, -.infinity] {
    let settings = AppVolumeSettings(desiredVolume: value, volumeBoost: value)
    #expect(settings.desiredVolume == LevelRange.volume.fallback)
    #expect(settings.volumeBoost == LevelRange.boost.fallback)
    let intent = PersistedAppAudioIntent(appID: "a", desiredVolume: value, volumeBoost: value)
    #expect(intent.desiredVolume == LevelRange.volume.fallback)
    #expect(intent.volumeBoost == LevelRange.boost.fallback)
  }

  let cases: [(literal: String, volume: Float, boost: Float)] = [
    ("-0.5", 0, 1), ("1.5", 1, 1.5), ("4.5", 1, 4), ("1e39", 1, 4), ("-1e39", 0, 1), ("1e300", 1, 4),
  ]
  for (literal, volume, boost) in cases {
    let settingsJSON = Data(#"{"desiredVolume":\#(literal),"isMuted":false,"volumeBoost":\#(literal)}"#.utf8)
    let settings = try JSONDecoder().decode(AppVolumeSettings.self, from: settingsJSON)
    #expect(settings.desiredVolume == volume, "desiredVolume \(literal)")
    #expect(settings.volumeBoost == boost, "volumeBoost \(literal)")

    let intentJSON = Data(#"{"appID":"a","desiredVolume":\#(literal),"volumeBoost":\#(literal)}"#.utf8)
    let intent = try JSONDecoder().decode(PersistedAppAudioIntent.self, from: intentJSON)
    #expect(intent.desiredVolume == volume, "intent desiredVolume \(literal)")
    #expect(intent.volumeBoost == boost, "intent volumeBoost \(literal)")
  }
}

@Test func oneHostileNumberDoesNotDiscardTheWholePreferencesFile() throws {
  // Before the shared check, a value too large for Float failed decoding of the
  // entire preferences file, which then reset every setting to defaults.
  let json = Data(
    #"""
    {"enableExternalControl":true,
     "appAudioIntents":{"a":{"appID":"a","desiredVolume":1e39,"isMuted":true,"volumeBoost":1e39}}}
    """#.utf8)
  let preferences = try JSONDecoder().decode(UserPreferences.self, from: json)
  #expect(preferences.enableExternalControl)
  let intent = try #require(preferences.appAudioIntents["a"])
  #expect(intent.desiredVolume == 1)
  #expect(intent.volumeBoost == 4)
  #expect(intent.isMuted)
}
