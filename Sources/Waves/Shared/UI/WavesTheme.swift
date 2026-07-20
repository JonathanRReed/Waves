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

  private struct Colors {
    let background: [Color]
    let opaqueBackground: Color
    let topSheen: Color
    let accent: Color
    let accentGradient: [Color]
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
