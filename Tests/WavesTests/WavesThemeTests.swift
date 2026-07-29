import SwiftUI
import Testing

@testable import Waves

@Test func wavesAppearanceResolvesSystemAndOverridesIndependently() {
  #expect(WavesAppearance.system.resolve(systemColorScheme: .light) == .light)
  #expect(WavesAppearance.system.resolve(systemColorScheme: .dark) == .dark)
  #expect(WavesAppearance.light.resolve(systemColorScheme: .dark) == .light)
  #expect(WavesAppearance.dark.resolve(systemColorScheme: .light) == .dark)
}

@Test func wavesAppearanceExposesNativePreferredColorSchemes() {
  #expect(WavesAppearance.system.preferredColorScheme == nil)
  #expect(WavesAppearance.light.preferredColorScheme == .light)
  #expect(WavesAppearance.dark.preferredColorScheme == .dark)
}

@Test func palettesResolveDistinctAdaptiveAccentTokens() {
  let wavesLight = WavesTheme(palette: .waves, colorScheme: .light)
  let wavesDark = WavesTheme(palette: .waves, colorScheme: .dark)
  let graphiteLight = WavesTheme(palette: .graphite, colorScheme: .light)
  let graphiteDark = WavesTheme(palette: .graphite, colorScheme: .dark)

  #expect(wavesLight.accent != wavesDark.accent)
  #expect(graphiteLight.accent != graphiteDark.accent)
  #expect(wavesLight.accent != graphiteLight.accent)
  #expect(wavesDark.accent != graphiteDark.accent)
}

@Test func increasedContrastUsesAThemeSpecificStrongerHairline() {
  for palette in WavesPalette.allCases {
    for colorScheme in [ColorScheme.light, .dark] {
      let theme = WavesTheme(palette: palette, colorScheme: colorScheme)
      #expect(theme.hairline(increasedContrast: false) == theme.stroke)
      #expect(theme.hairline(increasedContrast: true) == theme.strongStroke)
      #expect(theme.stroke != theme.strongStroke)
    }
  }
}

// MARK: - Waveform colours (1.4 D3)

/// Relative luminance per WCAG, from a resolved sRGB colour.
@MainActor
private func relativeLuminance(_ color: Color) -> Double {
  let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
  func channel(_ value: CGFloat) -> Double {
    let v = Double(value)
    return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * channel(resolved.redComponent)
    + 0.7152 * channel(resolved.greenComponent)
    + 0.0722 * channel(resolved.blueComponent)
}

@MainActor
private func contrastRatio(_ a: Color, _ b: Color) -> Double {
  let la = relativeLuminance(a)
  let lb = relativeLuminance(b)
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

@MainActor
@Test func everyPaletteGivesTheWaveformColoursThatAreActuallyVisible() {
  // The waveform used to draw with constants tuned for the dark palette. On
  // macOS Light — the DEFAULT appearance, since `WavesAppearance.system` follows
  // the system — the summed wave came out around 1.13:1 against the window and
  // the resting hairline around 1.0:1. That is not "low contrast", it is
  // invisible. Pin a floor so no future palette can reintroduce it.
  for palette in WavesPalette.allCases {
    for scheme in [ColorScheme.light, .dark] {
      let theme = WavesTheme(palette: palette, colorScheme: scheme)
      let surface = theme.opaqueBackground
      let label = "\(palette.rawValue)/\(scheme == .light ? "light" : "dark")"

      let coreRatio = contrastRatio(theme.waveCore, surface)
      #expect(coreRatio >= 3.0, "\(label): summed wave core is \(coreRatio):1 against the window")

      let midRatio = contrastRatio(theme.waveMid, surface)
      #expect(midRatio >= 2.5, "\(label): summed wave body is \(midRatio):1 against the window")

      for (index, voice) in theme.waveVoiceColors.enumerated() {
        let ratio = contrastRatio(voice, surface)
        #expect(ratio >= 2.0, "\(label): voice \(index) is \(ratio):1 against the window")
      }
    }
  }
}

@MainActor
@Test func waveVoicesAreDistinguishableWithinEachPalette() {
  // Voices must differ enough to read as separate threads, while staying inside
  // one hue family per DESIGN.md's Signal Rarity Rule.
  for palette in WavesPalette.allCases {
    for scheme in [ColorScheme.light, .dark] {
      let theme = WavesTheme(palette: palette, colorScheme: scheme)
      let voices = theme.waveVoiceColors
      #expect(voices.count == WaveEngine.Voice.voiceSlotCount)

      let luminances = voices.map { relativeLuminance($0) }
      for index in 1..<luminances.count {
        #expect(
          abs(luminances[index] - luminances[index - 1]) > 0.01,
          "\(palette.rawValue): voices \(index - 1) and \(index) are nearly identical"
        )
      }
    }
  }
}

@MainActor
@Test func aVoiceKeepsItsSlotAcrossPalettesAndAppearances() {
  // The voice is the slot, not the hue: the same app must wave the same way in
  // every palette, so its identity survives an appearance change.
  let spotify = WaveEngine.Voice(seed: 0xcbf2_9ce4_8422_2325)
  let discord = WaveEngine.Voice(seed: 0x0000_0100_0000_01B3)

  #expect(spotify.colorIndex == WaveEngine.Voice(seed: 0xcbf2_9ce4_8422_2325).colorIndex)
  #expect(spotify.colorIndex < WaveEngine.Voice.voiceSlotCount)
  #expect(discord.colorIndex < WaveEngine.Voice.voiceSlotCount)
}
