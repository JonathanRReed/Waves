import SwiftUI

/// Controls whether Waves follows macOS or requests a specific color scheme.
enum WavesAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: Self { self }

  var displayName: String {
    switch self {
    case .system:
      "System"
    case .light:
      "Light"
    case .dark:
      "Dark"
    }
  }

  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system:
      nil
    case .light:
      .light
    case .dark:
      .dark
    }
  }

  func resolve(systemColorScheme: ColorScheme) -> ColorScheme {
    preferredColorScheme ?? systemColorScheme
  }
}

/// The curated color identities available independently of app appearance.
enum WavesPalette: String, Codable, CaseIterable, Identifiable, Sendable {
  case waves
  case graphite

  var id: Self { self }

  var displayName: String {
    switch self {
    case .waves:
      "Waves"
    case .graphite:
      "Graphite"
    }
  }
}

/// Semantic app-wide colors resolved from a palette and effective color scheme.
///
/// Views read this value from `EnvironmentValues.wavesTheme`. Tokens describe
/// purpose rather than a literal hue so palette changes do not leak into layout
/// or interaction code.
struct WavesTheme {
  let palette: WavesPalette
  let colorScheme: ColorScheme

  let windowGradient: LinearGradient
  let opaqueBackground: Color
  let topSheen: Color
  let accent: Color
  let accentGradient: LinearGradient
  /// The raw stops behind `accentGradient`, for `Canvas` drawing.
  ///
  /// A `LinearGradient`'s unit points resolve against the context's bounds, not
  /// the path being filled, so painting a small shape inside a large `Canvas`
  /// with it samples only a sliver of the sweep. Callers that need the gradient
  /// to span the shape build an absolute-coordinate shading from these.
  let accentGradientColors: [Color]
  /// Per-app voice colours for the mixed waveform, and the two stops of its
  /// summed wave.
  ///
  /// The waveform draws N translucent per-app threads plus their bright
  /// point-wise sum. Those colours used to be compile-time constants tuned for
  /// the dark palette, which made the app's signature surface effectively
  /// invisible on macOS Light (a white hairline at 10% over a near-white
  /// window is about 1.0:1 contrast) and clashed outright with Graphite. They
  /// live here now so they follow the palette like every other surface, while
  /// keeping DESIGN.md's Signal Rarity Rule: voices differ in *temperature*
  /// within one hue family, never in hue.
  let waveVoiceColors: [Color]
  /// Bright centre of the summed wave.
  let waveCore: Color
  /// Body of the summed wave, and the resting hairline's fill.
  let waveMid: Color
  let contentFill: Color
  let subtleFill: Color
  let selectionFill: Color
  let stroke: Color
  let strongStroke: Color

  let warning = Color.orange
  let error = Color.red
  let success = Color.green

  init(palette: WavesPalette, colorScheme: ColorScheme) {
    self.palette = palette
    self.colorScheme = colorScheme

    let colors = Self.colors(palette: palette, colorScheme: colorScheme)
    windowGradient = LinearGradient(
      colors: colors.background,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    opaqueBackground = colors.opaqueBackground
    topSheen = colors.topSheen
    accent = colors.accent
    accentGradient = LinearGradient(
      colors: colors.accentGradient,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    accentGradientColors = colors.accentGradient
    waveVoiceColors = colors.waveVoiceColors
    waveCore = colors.waveCore
    waveMid = colors.waveMid
    contentFill = colors.contentFill
    subtleFill = colors.subtleFill
    selectionFill = colors.selectionFill
    stroke = colors.stroke
    strongStroke = colors.strongStroke
  }

  func accentOrSecondary(_ isActive: Bool) -> Color {
    isActive ? accent : Color.secondary
  }

  func accentOrTertiary(_ isActive: Bool) -> Color {
    isActive ? accent : Color(nsColor: .tertiaryLabelColor)
  }

  func hairline(increasedContrast: Bool) -> Color {
    increasedContrast ? strongStroke : stroke
  }

  func fieldFill(reduceTransparency: Bool, increasedContrast: Bool) -> Color {
    if reduceTransparency || increasedContrast {
      return Color(nsColor: .textBackgroundColor)
    }
    return contentFill
  }

  private struct Colors {
    let background: [Color]
    let opaqueBackground: Color
    let topSheen: Color
    let accent: Color
    let accentGradient: [Color]
    let waveVoiceColors: [Color]
    let waveCore: Color
    let waveMid: Color
    let contentFill: Color
    let subtleFill: Color
    let selectionFill: Color
    let stroke: Color
    let strongStroke: Color
  }

  private static func colors(palette: WavesPalette, colorScheme: ColorScheme) -> Colors {
    return switch (palette, colorScheme) {
    case (.waves, .dark):
      Colors(
        background: [
          Color(red: 0.03, green: 0.06, blue: 0.11),
          Color(red: 0.02, green: 0.03, blue: 0.06),
          Color(red: 0.01, green: 0.015, blue: 0.03),
        ],
        opaqueBackground: Color(red: 0.04, green: 0.06, blue: 0.10),
        topSheen: Color.white.opacity(0.05),
        accent: Color.cyan,
        accentGradient: [
          Color(red: 0.45, green: 0.95, blue: 1.0),
          Color(red: 0.0, green: 0.80, blue: 0.92),
        ],
        waveVoiceColors: [
          Color(red: 158.0 / 255.0, green: 247.0 / 255.0, blue: 1.0),
          Color(red: 51.0 / 255.0, green: 222.0 / 255.0, blue: 242.0 / 255.0),
          Color(red: 13.0 / 255.0, green: 184.0 / 255.0, blue: 199.0 / 255.0),
          Color(red: 0.0, green: 148.0 / 255.0, blue: 168.0 / 255.0),
        ],
        waveCore: Color(red: 140.0 / 255.0, green: 247.0 / 255.0, blue: 1.0),
        waveMid: Color(red: 0.0, green: 217.0 / 255.0, blue: 230.0 / 255.0),
        contentFill: Color.white.opacity(0.04),
        subtleFill: Color.white.opacity(0.025),
        selectionFill: Color.cyan.opacity(0.12),
        stroke: Color.white.opacity(0.09),
        strongStroke: Color.white.opacity(0.45)
      )
    case (.waves, .light):
      Colors(
        background: [
          Color(red: 0.91, green: 0.95, blue: 0.98),
          Color(red: 0.97, green: 0.98, blue: 0.99),
          Color(red: 0.87, green: 0.92, blue: 0.95),
        ],
        opaqueBackground: Color(red: 0.93, green: 0.96, blue: 0.98),
        topSheen: Color.white.opacity(0.38),
        accent: Color(red: 0.0, green: 0.48, blue: 0.59),
        accentGradient: [
          Color(red: 0.0, green: 0.64, blue: 0.74),
          Color(red: 0.0, green: 0.45, blue: 0.57),
        ],
        waveVoiceColors: [
          Color(red: 0.0, green: 0.56, blue: 0.66),
          Color(red: 0.0, green: 0.47, blue: 0.57),
          Color(red: 0.0, green: 0.38, blue: 0.48),
          Color(red: 0.0, green: 0.30, blue: 0.39),
        ],
        waveCore: Color(red: 0.0, green: 0.34, blue: 0.44),
        waveMid: Color(red: 0.0, green: 0.50, blue: 0.60),
        contentFill: Color.white.opacity(0.50),
        subtleFill: Color(red: 0.08, green: 0.20, blue: 0.29).opacity(0.035),
        selectionFill: Color(red: 0.0, green: 0.48, blue: 0.59).opacity(0.10),
        stroke: Color(red: 0.08, green: 0.18, blue: 0.25).opacity(0.14),
        strongStroke: Color(red: 0.04, green: 0.12, blue: 0.18).opacity(0.55)
      )
    case (.graphite, .dark):
      Colors(
        background: [
          Color(red: 0.13, green: 0.15, blue: 0.16),
          Color(red: 0.08, green: 0.09, blue: 0.10),
          Color(red: 0.045, green: 0.052, blue: 0.058),
        ],
        opaqueBackground: Color(red: 0.09, green: 0.10, blue: 0.11),
        topSheen: Color.white.opacity(0.045),
        accent: Color(red: 0.20, green: 0.72, blue: 0.65),
        accentGradient: [
          Color(red: 0.38, green: 0.82, blue: 0.75),
          Color(red: 0.10, green: 0.62, blue: 0.57),
        ],
        waveVoiceColors: [
          Color(red: 0.55, green: 0.90, blue: 0.84),
          Color(red: 0.34, green: 0.79, blue: 0.72),
          Color(red: 0.16, green: 0.66, blue: 0.60),
          Color(red: 0.05, green: 0.53, blue: 0.48),
        ],
        waveCore: Color(red: 0.62, green: 0.92, blue: 0.86),
        waveMid: Color(red: 0.14, green: 0.68, blue: 0.62),
        contentFill: Color.white.opacity(0.045),
        subtleFill: Color.white.opacity(0.025),
        selectionFill: Color(red: 0.20, green: 0.72, blue: 0.65).opacity(0.11),
        stroke: Color.white.opacity(0.10),
        strongStroke: Color.white.opacity(0.46)
      )
    case (.graphite, .light):
      Colors(
        background: [
          Color(red: 0.93, green: 0.94, blue: 0.94),
          Color(red: 0.98, green: 0.98, blue: 0.98),
          Color(red: 0.88, green: 0.89, blue: 0.90),
        ],
        opaqueBackground: Color(red: 0.94, green: 0.95, blue: 0.95),
        topSheen: Color.white.opacity(0.34),
        accent: Color(red: 0.0, green: 0.46, blue: 0.41),
        accentGradient: [
          Color(red: 0.04, green: 0.60, blue: 0.54),
          Color(red: 0.0, green: 0.42, blue: 0.38),
        ],
        waveVoiceColors: [
          Color(red: 0.02, green: 0.53, blue: 0.47),
          Color(red: 0.0, green: 0.45, blue: 0.40),
          Color(red: 0.0, green: 0.37, blue: 0.33),
          Color(red: 0.0, green: 0.29, blue: 0.26),
        ],
        waveCore: Color(red: 0.0, green: 0.32, blue: 0.29),
        waveMid: Color(red: 0.0, green: 0.47, blue: 0.42),
        contentFill: Color.white.opacity(0.52),
        subtleFill: Color.black.opacity(0.035),
        selectionFill: Color(red: 0.0, green: 0.46, blue: 0.41).opacity(0.10),
        stroke: Color.black.opacity(0.13),
        strongStroke: Color.black.opacity(0.52)
      )
    default:
      // SwiftUI currently has only light and dark schemes. Keep a deterministic
      // fallback in case a future SDK adds another case.
      colors(palette: palette, colorScheme: .dark)
    }
  }
}

private struct WavesThemeEnvironmentKey: EnvironmentKey {
  static let defaultValue = WavesTheme(palette: .waves, colorScheme: .dark)
}

extension EnvironmentValues {
  var wavesTheme: WavesTheme {
    get { self[WavesThemeEnvironmentKey.self] }
    set { self[WavesThemeEnvironmentKey.self] = newValue }
  }
}

extension View {
  /// Applies the independent palette and appearance selections at a scene root.
  func wavesTheme(palette: WavesPalette, appearance: WavesAppearance) -> some View {
    modifier(WavesThemeModifier(palette: palette, appearance: appearance))
  }
}

private struct WavesThemeModifier: ViewModifier {
  let palette: WavesPalette
  let appearance: WavesAppearance

  @Environment(\.colorScheme) private var systemColorScheme

  func body(content: Content) -> some View {
    let theme = WavesTheme(
      palette: palette,
      colorScheme: appearance.resolve(systemColorScheme: systemColorScheme)
    )
    content
      .preferredColorScheme(appearance.preferredColorScheme)
      .environment(\.wavesTheme, theme)
      .tint(theme.accent)
  }
}
