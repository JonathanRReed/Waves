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

  #expect(
    GlobalEqualizerSettings.combinedHeadroomCompensationDB(
      perApp: perApp,
      managedAudio: managed
    ) == -10
  )
  #expect(
    abs(
      GlobalEqualizerSettings.combinedHeadroomGain(
        perApp: perApp,
        managedAudio: managed
      ) - Float(pow(10, -10.0 / 20))
    ) < 0.000_001
  )

  managed.isEnabled = false
  #expect(
    GlobalEqualizerSettings.combinedHeadroomCompensationDB(
      perApp: perApp,
      managedAudio: managed
    ) == -6
  )
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
