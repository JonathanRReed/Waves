import AppKit
import SwiftUI
import WavesAudioCore

// MARK: - Design tokens
//
// Shared structural tokens and compatibility colors. Theme-aware views should
// read `wavesTheme` from the environment; the static color aliases below retain
// the original Waves-dark values while remaining call sites migrate.

enum WavesDesign {
  // MARK: Backdrops

  private static let compatibilityTheme = WavesTheme(palette: .waves, colorScheme: .dark)

  static let windowGradient = compatibilityTheme.windowGradient

  // MARK: Signal & status

  static let accent = compatibilityTheme.accent

  /// A slightly richer cyan→teal sweep for fills and the wave mark, so the
  /// signal reads as a crafted gradient rather than flat neon.
  static let accentGradient = compatibilityTheme.accentGradient

  static let warning = Color.orange
  static let error = Color.red
  /// The "done / healthy" hue (route recovered, onboarding complete, success
  /// toast). Tokenized alongside warning/error so the success green is themeable
  /// in one place rather than hard-coded at each call site.
  static let success = Color.green

  /// Concrete (non-hierarchical) stand-in for `.tertiary`. Use this — never
  /// `AnyShapeStyle(.tertiary)` — wherever a tertiary tone sits in a ternary
  /// alongside a concrete accent color. `AnyShapeStyle` erases a hierarchical
  /// style's resolution context (it needs to know the current foreground to
  /// compute its opacity), and the erased fallback resolves against
  /// `NSColor.controlAccentColor` — the user's *system* accent-color
  /// preference, not Waves' cyan signal color. That is how a non-blue system
  /// accent (e.g. Red) silently bleeds into icons that read `.secondary` /
  /// `.tertiary` in source. `Color.secondary` is already a concrete `Color`
  /// and is safe to use directly; `.tertiary` has no built-in `Color`
  /// equivalent, hence this token. Same rule applies to any future hierarchical
  /// style (`.quaternary`, etc.) used this way.
  static let tertiaryColor = Color(nsColor: .tertiaryLabelColor)

  /// The standard "is this the active/selected one?" color choice used all
  /// over the app (sidebar icons, boost/pin indicators, status text): accent
  /// when active, a quiet neutral otherwise. Prefer this over hand-writing
  /// `isActive ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary)` — that
  /// spelling is the exact pattern that caused the system-accent-color bleed
  /// documented on `tertiaryColor` above. Calling this function instead of
  /// writing the ternary by hand means the safe form is also the easy form.
  static func accentOrSecondary(_ isActive: Bool) -> Color {
    isActive ? accent : Color.secondary
  }

  /// As `accentOrSecondary`, but for the rarer case where the inactive state
  /// should read as tertiary (more recessive) rather than secondary.
  static func accentOrTertiary(_ isActive: Bool) -> Color {
    isActive ? accent : tertiaryColor
  }

  // MARK: Strokes

  static let stroke = compatibilityTheme.stroke

  // MARK: Radii

  static let cardCornerRadius: CGFloat = 22
  static let compactCardCornerRadius: CGFloat = 14
  static let chipCornerRadius: CGFloat = 8

  // MARK: Layout

  /// Fixed width of the menu-bar popover panel (one source of truth for the panel
  /// and the toast overlay it hosts).
  static let menuBarPanelWidth: CGFloat = 440

  /// Hairline/border color that becomes a clearly visible separator when the
  /// user has macOS "Increase contrast" enabled (the default 9% white is
  /// invisible to exactly the people who need contrast).
  static func hairline(increasedContrast: Bool) -> Color {
    increasedContrast ? Color.white.opacity(0.45) : stroke
  }
}

// MARK: - Brand mark

enum WavesBrandAssetLocator {
  static let resourceBundleName = "Waves_Waves.bundle"
  static let logoFilename = "waves-logo.png"

  static func logoURL(in bundle: Bundle = .main) -> URL? {
    logoURL(
      bundleURL: bundle.bundleURL,
      resourceURL: bundle.resourceURL,
      executableURL: bundle.executableURL
    )
  }

  static func logoURL(
    bundleURL: URL,
    resourceURL: URL?,
    executableURL: URL?,
    fileManager: FileManager = .default
  ) -> URL? {
    var containers: [URL] = []
    if let resourceURL {
      containers.append(resourceURL)
    }
    containers.append(bundleURL)
    if bundleURL.pathExtension != "app" {
      containers.append(bundleURL.deletingLastPathComponent())
      if let executableURL {
        containers.append(executableURL.deletingLastPathComponent())
      }
    }

    for container in containers {
      let candidate =
        container
        .appendingPathComponent(resourceBundleName, isDirectory: true)
        .appendingPathComponent(logoFilename, isDirectory: false)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        return candidate
      }
    }
    return nil
  }
}

/// The supplied Waves identity is the single source for both the app icon and
/// in-app branding. Live audio adds a restrained cyan glow without altering the
/// artwork, so the mark remains consistent at every size.
struct WavesMark: View {
  private static let image: NSImage? = {
    guard let url = WavesBrandAssetLocator.logoURL() else {
      return nil
    }
    return NSImage(contentsOf: url)
  }()

  var size: CGFloat = 20
  var live: Bool = false

  @Environment(\.wavesTheme) private var theme

  var body: some View {
    markImage
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .shadow(
        color: theme.accent.opacity(live ? 0.28 : 0),
        radius: live ? size * 0.16 : 0
      )
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }

  private var markImage: Image {
    if let image = Self.image {
      return Image(nsImage: image)
    }
    return Image(systemName: "waveform.path")
  }
}

// MARK: - Reusable surfaces

extension View {
  /// A *content* card — grouped settings, list panels, reading surfaces. Per
  /// Apple's Liquid Glass guidance, glass belongs to the floating/navigation
  /// layer, not to content, and a glass card sitting on the already-blurred
  /// window background reads as muddy glass-on-glass. So content cards use a
  /// quiet tonal fill + hairline (which also drops the layered blur cost on the
  /// 14.2 fallback). Glass lives only on the floating layer now — the system
  /// popover/sheet/toolbar chrome, the WavesBackground backdrop, and primary
  /// actions via `wavesGlassProminentButton`.
  func wavesCard(cornerRadius: CGFloat = WavesDesign.compactCardCornerRadius) -> some View {
    modifier(WavesContentCardModifier(cornerRadius: cornerRadius))
  }
}

private struct WavesContentCardModifier: ViewModifier {
  let cornerRadius: CGFloat
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.wavesTheme) private var theme

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background(theme.contentFill, in: shape)
      .overlay(
        shape.strokeBorder(theme.hairline(increasedContrast: contrast == .increased), lineWidth: 1)
      )
  }
}

/// A compact, scannable section header used above grouped lists in the menu bar
/// and editors.
struct WavesSectionHeader: View {
  let title: String
  var systemImage: String?
  var trailing: AnyView?

  init(_ title: String, systemImage: String? = nil, trailing: AnyView? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.trailing = trailing
  }

  var body: some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if let trailing {
        trailing
      }
    }
  }
}

/// Single source of truth for a diagnostics check's color/symbol/status word —
/// previously reimplemented separately in Settings > Advanced's
/// `DiagnosticsCheckRow` and the main window's `DiagnosticsPanel`, which read
/// the same `store.diagnostics.checks` data but could have drifted in styling
/// since neither referenced the other.
extension DiagnosticsStatus {
  var color: Color {
    switch self {
    case .passed: WavesDesign.success
    case .warning: WavesDesign.warning
    case .failed: WavesDesign.error
    case .informational: .secondary
    }
  }

  var symbolName: String {
    switch self {
    case .passed: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .failed: "xmark.octagon"
    case .informational: "info.circle"
    }
  }

  var statusWord: String {
    switch self {
    case .passed: "Passed"
    case .warning: "Warning"
    case .failed: "Failed"
    case .informational: "Info"
    }
  }
}
