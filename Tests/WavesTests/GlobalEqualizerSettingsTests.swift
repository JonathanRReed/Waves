import Foundation
import Testing

@testable import WavesAudioCore

@Test func globalEqualizerUsesPerAppBoundsBandsAndPresets() {
  var settings = GlobalEqualizerSettings(
    isEnabled: true,
    mode: .simple,
    simpleGainsDB: [-30, .nan, 30, 7],
    advancedGainsDB: [20]
  )

  #expect(settings.simpleGainsDB == [-12, 0, 12])
  #expect(settings.advancedGainsDB == [12, 0, 0, 0, 0, 0, 0, 0])

  settings.applyPreset(.voiceFocus, mode: .advanced)
  #expect(settings.advancedPreset == .voiceFocus)
  #expect(
    settings.advancedGainsDB
      == EqualizerSettings.curve(for: .voiceFocus, mode: .advanced)
  )
}

@Test func stackedEqualizersReserveCombinedHeadroom() {
  var perApp = EqualizerSettings(isEnabled: true)
  perApp.setGain(6, at: 1)
  var managed = GlobalEqualizerSettings(isEnabled: true)
  managed.setGain(4, at: 2)

  // The reservation must cover at least the nominal band boosts (6 + 4 dB) —
  // the cascade sweep may reserve slightly more (shelf/peak overlap + margin),
  // never less.
  let combined = GlobalEqualizerSettings.combinedHeadroomCompensationDB(
    perApp: perApp,
    managedAudio: managed
  )
  #expect(combined <= -10)
  #expect(combined > -13)
  #expect(
    abs(
      GlobalEqualizerSettings.combinedHeadroomGain(
        perApp: perApp,
        managedAudio: managed
      ) - Float(pow(10, Double(combined) / 20))
    ) < 0.000_1
  )

  managed.isEnabled = false
  let perAppOnly = GlobalEqualizerSettings.combinedHeadroomCompensationDB(
    perApp: perApp,
    managedAudio: managed
  )
  #expect(perAppOnly <= -6)
  #expect(perAppOnly > -8)
}

@Test func headroomCoversOverlappingMultibandBoosts() {
  // Eight adjacent +12 dB peaking bands stack to ~+22 dB near 500 Hz — the
  // reservation must cover the real cascade peak, not the single-band max.
  let allUp = Array(repeating: Float(12), count: 8)
  let peak = EqualizerHeadroom.peakBoostDB(mode: .advanced, gainsDB: allUp)
  #expect(peak > 20)
  #expect(peak < 26)

  var settings = EqualizerSettings(isEnabled: true, mode: .advanced)
  for index in 0..<8 { settings.setGain(12, at: index) }
  #expect(settings.headroomCompensationDB <= -peak + 0.001)

  // Flat and cut-only curves need no reservation.
  #expect(EqualizerHeadroom.peakBoostDB(mode: .advanced, gainsDB: Array(repeating: 0, count: 8)) == 0)
  #expect(EqualizerHeadroom.peakBoostDB(mode: .simple, gainsDB: [-6, -3, 0]) == 0)

  // A single isolated boost stays near its nominal value (within overlap + margin).
  let single = EqualizerHeadroom.peakBoostDB(mode: .simple, gainsDB: [0, 6, 0])
  #expect(single >= 6)
  #expect(single < 8.5)

  // A disabled EQ reserves nothing regardless of its stored curve.
  settings.isEnabled = false
  #expect(settings.headroomCompensationDB == 0)
}

@Test func globalEqualizerConvertsToDSPSettingsWithoutAdaptiveState() {
  var global = GlobalEqualizerSettings(isEnabled: true, mode: .advanced)
  global.applyPreset(.warm)

  let dspSettings = global.equalizerSettings
  #expect(dspSettings.isEnabled)
  #expect(dspSettings.mode == .advanced)
  #expect(dspSettings.advancedGainsDB == global.advancedGainsDB)
  #expect(dspSettings.adaptiveRole == .auto)
}

@Test func globalEqualizerDecodingDefaultsAndClampsMalformedValues() throws {
  let empty = try JSONDecoder().decode(
    GlobalEqualizerSettings.self,
    from: Data("{}".utf8)
  )
  #expect(empty == GlobalEqualizerSettings())

  let clamped = try JSONDecoder().decode(
    GlobalEqualizerSettings.self,
    from: Data(#"{"isEnabled":true,"simpleGainsDB":[20,-20,3]}"#.utf8)
  )
  #expect(clamped.isEnabled)
  #expect(clamped.simpleGainsDB == [12, -12, 3])

  var original = GlobalEqualizerSettings(isEnabled: true, mode: .advanced)
  original.applyPreset(.trebleSoften)
  let roundTrip = try JSONDecoder().decode(
    GlobalEqualizerSettings.self,
    from: JSONEncoder().encode(original)
  )
  #expect(roundTrip == original)
}
