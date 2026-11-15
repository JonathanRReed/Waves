import SwiftUI

/// The shape a hover highlight fills behind a control.
enum WavesHoverShape {
  /// Icon buttons and borderless menus.
  case roundedRectangle
  /// Chips that are already capsules.
  case capsule
}

/// The fill behind a hovered or pressed borderless control.
///
/// A tonal tint of the label color rather than the accent, so it reads in both
/// appearances and both palettes without spending the signal color on chrome.
/// Increase Contrast makes it stronger; it is opaque enough to survive Reduce
/// Transparency because it sits on the content surface, not on glass.
enum WavesHoverFill {
  static func opacity(isHovering: Bool, isPressed: Bool, increasedContrast: Bool) -> Double {
    if isPressed { return increasedContrast ? 0.24 : 0.14 }
    if isHovering { return increasedContrast ? 0.16 : 0.07 }
    return 0
  }
}

/// A borderless button with a quiet hover and pressed state.
struct WavesHoverButtonStyle: ButtonStyle {
  var shape: WavesHoverShape = .roundedRectangle

  func makeBody(configuration: Configuration) -> some View {
    WavesHoverHighlight(shape: shape, isPressed: configuration.isPressed, managesEnabledState: true) {
      // Icon buttons keep the tint `.borderless` gave them; chips draw their own.
      if shape == .roundedRectangle {
        configuration.label.foregroundStyle(.tint)
      } else {
        configuration.label
      }
    }
  }
}

extension ButtonStyle where Self == WavesHoverButtonStyle {
  /// Icon buttons in rows, headers, and footers.
  static var wavesIcon: WavesHoverButtonStyle { WavesHoverButtonStyle() }
  /// Selectable chips, such as the equalizer's stream picker.
  static var wavesChip: WavesHoverButtonStyle { WavesHoverButtonStyle(shape: .capsule) }
}

extension View {
  /// The hover half of `WavesHoverButtonStyle`, for borderless menus, which
  /// cannot take a button style.
  func wavesHoverHighlight(_ shape: WavesHoverShape = .roundedRectangle) -> some View {
    WavesHoverHighlight(shape: shape, isPressed: false, managesEnabledState: false) { self }
  }
}

private struct WavesHoverHighlight<Label: View>: View {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let shape: WavesHoverShape
  let isPressed: Bool
  /// A button style must dim its own disabled label; a menu already does.
  let managesEnabledState: Bool
  @ViewBuilder let label: Label
  @State private var isHovering = false

  var body: some View {
    let opacity =
      isEnabled
      ? WavesHoverFill.opacity(
        isHovering: isHovering,
        isPressed: isPressed,
        increasedContrast: contrast == .increased
      )
      : 0
    label
      .opacity(managesEnabledState && !isEnabled ? 0.45 : 1)
      .background {
        switch shape {
        case .roundedRectangle:
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(opacity))
        case .capsule:
          Capsule().fill(Color.primary.opacity(opacity))
        }
      }
      .onHover { isHovering = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
  }
}
