import AppKit
import SwiftUI

// MARK: - Real system blur (all supported OS versions)

/// A bridge to `NSVisualEffectView` so SwiftUI surfaces can sample and blur the
/// wallpaper/content *behind* the window — the genuine "liquid" depth that no
/// amount of flat translucency fakes. `state = .active` keeps the blur on even
/// when the window isn't key (so a menu-bar popover doesn't grey out).
struct VisualEffectView: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .hudWindow
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
  var isEmphasized = false

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
    view.isEmphasized = isEmphasized
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.material = material
    view.blendingMode = blendingMode
    view.isEmphasized = isEmphasized
  }
}

/// The standard backdrop for Waves' own windows and sheets: a real
/// wallpaper-sampling blur tinted into the dark audio-console palette, with a
/// faint top sheen for depth. Collapses to an opaque dark fill when the user has
/// turned on Reduce Transparency (an accessibility requirement — backgrounds
/// must not be semi-transparent in that mode).
struct WavesBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.wavesTheme) private var theme

  var body: some View {
    ZStack {
      if reduceTransparency {
        theme.opaqueBackground
      } else {
        VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
        theme.windowGradient.opacity(0.86)
        LinearGradient(
          colors: [theme.topSheen, .clear],
          startPoint: .top,
          endPoint: .center
        )
      }
    }
    .ignoresSafeArea()
  }
}

// MARK: - Modern glass affordances (macOS 26+) with backward-compatible fallbacks
//
// Liquid Glass lives on the navigation/floating layer only: the system-provided
// menu-bar popover, sheets, and toolbar; the window/sheet backdrop (WavesBackground,
// above); and primary actions via the glass button style below. Content cards use
// a tonal fill (see `wavesCard` in DesignSystem). There is intentionally no custom
// glass *surface* modifier — a glass card over the blurred backdrop reads as muddy
// glass-on-glass, which Apple's guidance warns against.

extension View {
  /// Soft scroll-edge dissolve so list content melts under the floating header /
  /// toolbar instead of meeting a hard clip — the modern Tahoe treatment. macOS
  /// 26+ only; a no-op (current hard edge) below, so 14.2–15 is unaffected.
  @ViewBuilder
  func wavesSoftScrollEdge() -> some View {
    if #available(macOS 26.0, *) {
      self.scrollEdgeEffectStyle(.soft, for: .top)
    } else {
      self
    }
  }

  /// Shows the link/pointing-hand cursor over a borderless, link-like control so
  /// it reads as clickable (macOS 15+); harmless arrow-cursor fallback below.
  @ViewBuilder
  func wavesLinkPointer() -> some View {
    if #available(macOS 15.0, *) {
      self.pointerStyle(.link)
    } else {
      self
    }
  }

  /// The single primary action on a surface: prominent (cyan-tinted) glass on
  /// macOS 26, `.borderedProminent` below. One per surface keeps the accent rare.
  func wavesGlassProminentButton() -> some View { modifier(WavesGlassButtonStyle()) }
}

/// Swaps in the genuine macOS 26 prominent glass button style where available,
/// falling back to `.borderedProminent` on macOS 14.2–15 so the primary action
/// looks native on every supported OS. The system style owns its own edge and
/// legibility adaptations (Reduce Transparency / Increase Contrast).
private struct WavesGlassButtonStyle: ViewModifier {
  @Environment(\.wavesTheme) private var theme

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.buttonStyle(.glassProminent).tint(theme.accent)
    } else {
      content.buttonStyle(.borderedProminent).tint(theme.accent)
    }
  }
}
