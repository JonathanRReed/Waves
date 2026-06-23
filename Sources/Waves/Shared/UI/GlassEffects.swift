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

  var body: some View {
    ZStack {
      if reduceTransparency {
        Color(red: 0.04, green: 0.06, blue: 0.10)
      } else {
        VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
        WavesDesign.windowGradient.opacity(0.86)
        LinearGradient(
          colors: [Color.white.opacity(0.05), .clear],
          startPoint: .top,
          endPoint: .center
        )
      }
    }
    .ignoresSafeArea()
  }
}

// MARK: - Liquid Glass surface (macOS 26+) with a faux-glass fallback

extension View {
  /// A Liquid-Glass surface. On macOS 26 (Tahoe) this is genuine
  /// `.glassEffect(.regular)`; on macOS 14.2–15 it's a layered faux-glass
  /// (real blur + frosted material + specular bevel). Honors Reduce Transparency
  /// (opaque) and Increase Contrast (stronger border). This is the one place
  /// panel/card chrome is defined so every custom surface matches.
  func wavesGlass(cornerRadius: CGFloat = WavesDesign.compactCardCornerRadius, tint: Color? = nil) -> some View {
    modifier(WavesGlassModifier(cornerRadius: cornerRadius, tint: tint))
  }
}

private struct WavesGlassModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if reduceTransparency {
      // Opaque, no blur — accessibility requirement.
      content
        .background(Color(red: 0.08, green: 0.10, blue: 0.14), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.22), lineWidth: 1))
    } else if #available(macOS 26.0, *) {
      content
        .glassEffect(glassValue, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.4 : 0.1), lineWidth: 0.5))
    } else {
      content.modifier(FauxGlass(shape: shape, tint: tint, increasedContrast: contrast == .increased))
    }
  }

  @available(macOS 26.0, *)
  private var glassValue: Glass {
    guard let tint else { return .regular }
    return .regular.tint(tint)
  }
}

/// Dark faux-glass for macOS 14.2–15: a real blur base, a frosted material, a
/// top→bottom specular bevel, and a soft inner highlight — the recipe that reads
/// as glass before the system API existed.
private struct FauxGlass: ViewModifier {
  let shape: RoundedRectangle
  let tint: Color?
  let increasedContrast: Bool

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
          shape.fill(.ultraThinMaterial)
          if let tint {
            shape.fill(tint.opacity(0.16)).blendMode(.overlay)
          }
          LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
        }
        .clipShape(shape)
      }
      .overlay(
        shape.strokeBorder(
          LinearGradient(
            colors: [.white.opacity(increasedContrast ? 0.55 : 0.34), .white.opacity(0.05), .clear],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 1
        )
      )
  }
}
