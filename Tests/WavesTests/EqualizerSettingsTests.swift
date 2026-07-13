import Foundation
import Testing

@testable import WavesAudioCore

@Test func equalizerSettingsDefaultsToDisabledFlatSimpleMode() {
  let settings = EqualizerSettings()

  #expect(settings.isEnabled == false)
  #expect(settings.mode == .simple)
  #expect(settings.selectedPreset == .flat)
  #expect(settings.adaptiveRole == .auto)
  #expect(settings.simpleGainsDB == [0, 0, 0])
  #expect(settings.advancedGainsDB == Array(repeating: 0, count: 8))
}

@Test func equalizerSettingsNormalizesCountsAndClampsGains() {
  let settings = EqualizerSettings(
    simpleGainsDB: [-30, .nan, 30, 7],
    advancedGainsDB: [20]
  )

  #expect(settings.simpleGainsDB == [-12, 0, 12])
  #expect(settings.advancedGainsDB == [12, 0, 0, 0, 0, 0, 0, 0])
}

@Test func equalizerPresetAppliesOnlyToRequestedMode() {
  var settings = EqualizerSettings()
  settings.applyPreset(.voiceFocus, mode: .simple)

  #expect(settings.simplePreset == .voiceFocus)
  #expect(settings.simpleGainsDB == EqualizerSettings.curve(for: .voiceFocus, mode: .simple))
  #expect(settings.advancedPreset == .flat)
  #expect(settings.advancedGainsDB == EqualizerSettings.curve(for: .flat, mode: .advanced))
}

@Test func manualBandEditMarksOnlyThatModeCustom() {
  var settings = EqualizerSettings()
  settings.applyPreset(.warm, mode: .simple)
  settings.applyPreset(.trebleSoften, mode: .advanced)
  settings.setGain(4, at: 1, mode: .simple)

  #expect(settings.simplePreset == .custom)
  #expect(settings.simpleGainsDB[1] == 4)
  #expect(settings.advancedPreset == .trebleSoften)
}

@Test func switchingEqualizerModesPreservesBothCurves() {
  var settings = EqualizerSettings(mode: .simple)
  settings.applyPreset(.bassReduce, mode: .simple)
  settings.applyPreset(.warm, mode: .advanced)

  let simple = settings.simpleGainsDB
  let advanced = settings.advancedGainsDB
  settings.mode = .advanced
  settings.mode = .simple

  #expect(settings.simpleGainsDB == simple)
  #expect(settings.advancedGainsDB == advanced)
}

@Test func equalizerHeadroomOffsetsLargestPositiveBand() {
  var settings = EqualizerSettings(isEnabled: true)
  settings.setGain(2, at: 0)
  settings.setGain(6, at: 1)
  settings.setGain(-4, at: 2)

  #expect(settings.headroomCompensationDB == -6)
}

@Test func equalizerSettingsDecodesLegacyEmptyObject() throws {
  let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: Data("{}".utf8))
  #expect(decoded == EqualizerSettings())
}

@Test func equalizerSettingsRoundTripsThroughCodable() throws {
  var settings = EqualizerSettings(isEnabled: true, mode: .advanced, adaptiveRole: .voice)
  settings.applyPreset(.voiceFocus, mode: .simple)
  settings.applyPreset(.warm, mode: .advanced)

  let data = try JSONEncoder().encode(settings)
  let decoded = try JSONDecoder().decode(EqualizerSettings.self, from: data)

  #expect(decoded == settings)
}
