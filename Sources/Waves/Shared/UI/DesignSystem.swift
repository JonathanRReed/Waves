import SwiftUI

enum WavesDesign {
  static let windowGradient = LinearGradient(
    colors: [
      Color(red: 0.03, green: 0.06, blue: 0.11),
      Color(red: 0.02, green: 0.03, blue: 0.06),
      Color(red: 0.01, green: 0.015, blue: 0.03),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let meshTint = RadialGradient(
    colors: [
      Color.cyan.opacity(0.22),
      Color.blue.opacity(0.1),
      .clear,
    ],
    center: .topTrailing,
    startRadius: 10,
    endRadius: 420
  )

  static let panelGradient = LinearGradient(
    colors: [
      Color.white.opacity(0.12),
      Color.white.opacity(0.03),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let rail = Color.white.opacity(0.08)
  static let stroke = Color.white.opacity(0.09)
  static let accent = Color.cyan
  static let warning = Color.orange
  static let error = Color.red

  static let cardCornerRadius: CGFloat = 22
  static let compactCardCornerRadius: CGFloat = 14

  /// Hairline/border color that becomes a clearly visible separator when the
  /// user has macOS "Increase contrast" enabled (the default 9% white is
  /// invisible to exactly the people who need contrast).
  static func hairline(increasedContrast: Bool) -> Color {
    increasedContrast ? Color.white.opacity(0.45) : stroke
  }
}
