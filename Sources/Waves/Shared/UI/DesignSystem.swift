import SwiftUI

// MARK: - Design tokens
//
// Waves' visual language (see DESIGN.md): a quiet dark audio-console surface,
// macOS Liquid Glass via system materials, and a single signal-cyan accent that
// only appears where audio is live or a control is primary. These tokens are the
// single source of truth so spacing, radii, and color stay consistent across the
// menu bar, main window, settings, and onboarding.

enum WavesDesign {
  // MARK: Backdrops

  static let windowGradient = LinearGradient(
    colors: [
      Color(red: 0.03, green: 0.06, blue: 0.11),
      Color(red: 0.02, green: 0.03, blue: 0.06),
      Color(red: 0.01, green: 0.015, blue: 0.03),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  // MARK: Signal & status

  static let accent = Color.cyan

  /// A slightly richer cyan→teal sweep for fills and the wave mark, so the
  /// signal reads as a crafted gradient rather than flat neon.
  static let accentGradient = LinearGradient(
    colors: [
      Color(red: 0.45, green: 0.95, blue: 1.0),
      Color(red: 0.0, green: 0.80, blue: 0.92),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

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

  // MARK: Strokes

  static let stroke = Color.white.opacity(0.09)

  // MARK: Radii

  static let cardCornerRadius: CGFloat = 22
  static let compactCardCornerRadius: CGFloat = 14
  static let chipCornerRadius: CGFloat = 8

  // MARK: Layout

  /// Fixed width of the menu-bar popover panel (one source of truth for the panel
  /// and the toast overlay it hosts).
  static let menuBarPanelWidth: CGFloat = 400

  /// Hairline/border color that becomes a clearly visible separator when the
  /// user has macOS "Increase contrast" enabled (the default 9% white is
  /// invisible to exactly the people who need contrast).
  static func hairline(increasedContrast: Bool) -> Color {
    increasedContrast ? Color.white.opacity(0.45) : stroke
  }
}

// MARK: - Wave motif

/// A smooth sine wave path — the literal namesake motif, used as a quiet accent
/// in headers, empty states, and onboarding. `amplitude` is a fraction of the
/// rect's half-height; `waves` is how many full cycles span the width.
struct WaveShape: Shape {
  var amplitude: CGFloat = 0.6
  var waves: CGFloat = 1.6
  var phase: CGFloat = 0

  var animatableData: CGFloat {
    get { phase }
    set { phase = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let midY = rect.midY
    let amp = (rect.height / 2) * amplitude
    let steps = max(2, Int(rect.width / 2))
    for index in 0...steps {
      let t = CGFloat(index) / CGFloat(steps)
      let x = rect.minX + rect.width * t
      let y = midY + sin(t * waves * 2 * .pi + phase) * amp
      if index == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }
    return path
  }
}

/// The Waves brand mark: a rounded tile with three nested cyan waves. Drawn in
/// code so it scales crisply at any size and can gently animate when audio is
/// live (honoring Reduce Motion). Falls back to the bundled logo asset nowhere —
/// this *is* the in-app mark; the bundled PNG is only used for the Dock/app icon.
struct WavesMark: View {
  var size: CGFloat = 20
  var live: Bool = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var phase: CGFloat = 0

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(red: 0.06, green: 0.12, blue: 0.20), Color(red: 0.02, green: 0.04, blue: 0.08)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: max(0.5, size * 0.03))
        )

      ForEach(0..<3, id: \.self) { index in
        WaveShape(
          amplitude: 0.42 - CGFloat(index) * 0.06,
          waves: 1.4,
          phase: phase + CGFloat(index) * (.pi / 2.4)
        )
        .stroke(
          WavesDesign.accent.opacity(1.0 - Double(index) * 0.32),
          style: StrokeStyle(lineWidth: max(1, size * 0.07), lineCap: .round)
        )
        .frame(width: size * 0.64, height: size * 0.5)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
    .onAppear { updateAnimation(live) }
    .onChange(of: live) { _, isLive in updateAnimation(isLive) }
  }

  /// Starts the gentle wave drift while live, and halts it (without animating the
  /// reset) when audio stops or Reduce Motion is on.
  private func updateAnimation(_ isLive: Bool) {
    guard isLive, !reduceMotion else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { phase = 0 }
      return
    }
    withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
      phase = .pi * 2
    }
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

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background(Color.white.opacity(0.04), in: shape)
      .overlay(
        shape.strokeBorder(WavesDesign.hairline(increasedContrast: contrast == .increased), lineWidth: 1)
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
