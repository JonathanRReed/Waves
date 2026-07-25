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
