import SwiftUI
import WavesAudioCore

/// Eases a meter's bar and peak-hold positions between the sparse (~3 Hz) level
/// polls so the meter animates smoothly at the render clock. Fast attack / slow
/// release on the bar (VU/PPM feel); the peak dot snaps up, holds, then falls at
/// a fixed dB rate. Frame-rate-independent — coefficients are recomputed from
/// real elapsed time each frame. A reference type so the per-frame closure can
/// mutate it without writing `@State` mid-render.
@MainActor
final class LevelMeterModel {
  private(set) var bar: Double = 0
  private(set) var peak: Double = 0
  private var lastTime: TimeInterval?
  private var holdRemaining: Double = 0

  func update(barTarget: Double, peakTarget: Double, at date: Date) {
    let now = date.timeIntervalSinceReferenceDate
    // Clamp dt so a stall (window hidden, cadence paused, debugger pause) can't
    // snap the meter when the clock resumes.
    let dt = lastTime.map { max(0, min(0.1, now - $0)) } ?? (1.0 / 60.0)
    lastTime = now

    // Bar: asymmetric attack/release low-pass.
    let tau = barTarget > bar ? MeterBallistics.attack : MeterBallistics.release
    let alpha = 1 - exp(-dt / max(tau, 1e-4))
    bar += alpha * (barTarget - bar)

    // Peak dot: jump to a fresh peak and reset the hold; otherwise hold, then
    // fall at the fixed dB rate (converted to position units upstream).
    if peakTarget >= peak {
      peak = peakTarget
      holdRemaining = MeterBallistics.peakHold
    } else if holdRemaining > 0 {
      holdRemaining -= dt
    } else {
      peak = max(0, peak - MeterBallistics.peakFallPerSecond * dt)
    }
  }

  /// True once the eased bar AND the peak-hold dot have both decayed to nothing,
  /// so the render loop can be torn down without snapping a visible tail off — and
  /// so a later remount never inherits a stale peak.
  var isSettled: Bool { bar < 0.002 && peak < 0.002 }

  /// Drops the eased state immediately, for the paths where it cannot be eased
  /// out: with no clock mounted nothing advances the model, so waiting for
  /// `isSettled` would never succeed and would leave the stale peak the settle
  /// exists to prevent.
  func reset() {
    bar = 0
    peak = 0
    holdRemaining = 0
    lastTime = nil
  }
}

/// The quiet cyan "now playing" level bar shown along the bottom of a managed or
/// live mixer row. dB-mapped (so quiet audio actually registers), eased with fast
/// attack / slow release at the render clock (no staircase from the sparse poll),
/// with a brighter peak-hold tick that marks recent transients — the
/// professional-meter recipe. Holds the render loop briefly after silence so it
/// eases out instead of snapping; under Reduce Motion it binds straight to the
/// target with no clock. Purely decorative: hit-testing off, hidden from VoiceOver.
///
/// Everything is drawn in a single `Canvas`. That is a correctness requirement,
/// not a preference: the pre-1.3.1 meter animated by resizing a `Capsule`'s
/// `.frame(width:)` every frame, and these meters live in `List` rows backed by
/// `NSTableView`. A frame change is layout-affecting, so each meter dragged the
/// whole window through an AppKit layout pass on every tick — the deep
/// `_layoutSubtreeWithOldSize:` recursion that dominated the 1.3.0 CPU incident,
/// multiplied by every audible row. Drawing into a `Canvas` changes pixels
/// without touching layout, so cost stays proportional to what is actually
/// on screen.
struct RowLevelMeter: View {
  @Environment(\.wavesTheme) private var theme
  /// Linear amplitudes (0…1) straight from the level poll. The bar tracks `rms`
  /// (steady body); the peak-hold tick tracks `peak` (transients).
  let rms: Float
  let peak: Float

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Paused while no Waves window is on screen; halved while Waves is visible
  /// but not frontmost. See `RenderActivityMonitor`.
  @Environment(\.renderCadence) private var cadence
  @State private var model = LevelMeterModel()
  @State private var isAnimating = false

  private static let height: CGFloat = 2.5
  private static let tickWidth: CGFloat = 2.5
  /// Brighter cyan than the bar gradient so the peak tick reads as a highlight.
  private static let tickColor = Color(red: 0.72, green: 0.98, blue: 1.0)

  private var barTarget: Double { Double(MeterBallistics.normalize(rms)) }
  private var peakTarget: Double { Double(MeterBallistics.normalize(peak)) }
  private var isActive: Bool { barTarget > 0.001 || peakTarget > 0.001 }
  /// The clock runs only when this row has signal (or is settling) *and* the
  /// user can actually see it.
  private var isRunning: Bool { isAnimating && cadence.isAnimating }

  var body: some View {
    meterContent
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      // Cross-fade the clock ⇄ idle handoff so the meter dissolves rather than
      // blinking off when an app goes quiet.
      .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: isRunning)
      // Hold the render loop after silence until the eased bar AND peak-hold dot
      // have both settled, so a loud row's release / peak tails play all the way
      // out instead of blinking off at a fixed time — and so a remount never
      // inherits a stale peak. A safety cap bounds the worst case; a returning
      // signal cancels this and resumes the live loop.
      .task(id: isActive) {
        if isActive {
          isAnimating = true
        } else if isAnimating {
          // With no clock mounted nothing advances the model, so the settle
          // below could never complete — it would spin out its whole safety cap
          // and still leave the stale peak it exists to clear. Drop straight to
          // rest instead; there is no visible tail to ease out anyway.
          guard cadence.isAnimating else {
            model.reset()
            isAnimating = false
            return
          }
          var ticks = 0
          while !model.isSettled && ticks < 60 {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
            ticks += 1
          }
          isAnimating = false
        }
      }
  }

  @ViewBuilder
  private var meterContent: some View {
    if reduceMotion || (isActive && !cadence.isAnimating) {
      // No clock: draw the current target pose once. Under Reduce Motion that is
      // the whole design; while paused it means the meter is already correct the
      // instant the window comes back on screen.
      Canvas { context, size in
        draw(context, size: size, bar: barTarget, peak: peakTarget)
      }
    } else if isRunning {
      TimelineView(.animation(minimumInterval: cadence.minimumInterval)) { timeline in
        Canvas { context, size in
          model.update(barTarget: barTarget, peakTarget: peakTarget, at: timeline.date)
          draw(context, size: size, bar: model.bar, peak: model.peak)
        }
      }
      .transition(.opacity)
    } else {
      Color.clear.transition(.opacity)
    }
  }

  /// Draws the bar and peak tick along the bottom-leading edge of `size`.
  /// Pure drawing — no layout, no view identity, nothing for AttributeGraph to
  /// invalidate.
  private func draw(_ context: GraphicsContext, size: CGSize, bar: Double, peak: Double) {
    let width = size.width
    guard width > 0, size.height >= Self.height else { return }
    let y = size.height - Self.height
    let radius = Self.height / 2

    let barWidth = max(0, width * CGFloat(bar))
    if barWidth > 0 {
      let rect = CGRect(x: 0, y: y, width: barWidth, height: Self.height)
      let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
      // Glow swells with the signal: barely-there when quiet, a brighter bloom
      // when hot, so a glance reads how loud the app is, not just that it plays.
      var layer = context
      layer.addFilter(
        .shadow(
          color: theme.accent.opacity(0.30 + 0.40 * bar),
          radius: 2 + 3 * bar,
          x: 0,
          y: 0
        )
      )
      // Absolute coordinates, spanning the bar itself. A `LinearGradient`'s unit
      // points would resolve against the whole row-sized Canvas instead, so a
      // quiet (short) bar would sample only the first sliver of the sweep and
      // its color would drift with the level.
      layer.fill(
        path,
        with: .linearGradient(
          Gradient(colors: theme.accentGradientColors),
          startPoint: CGPoint(x: rect.minX, y: rect.minY),
          endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
        )
      )
    }

    // Peak-hold tick — only once there's a meaningful transient to mark.
    if peak > 0.02 {
      let x = max(0, min(width - Self.tickWidth, width * CGFloat(peak) - Self.tickWidth / 2))
      let rect = CGRect(x: x, y: y, width: Self.tickWidth, height: Self.height)
      let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
      var layer = context
      layer.addFilter(.shadow(color: theme.accent.opacity(0.6), radius: 2, x: 0, y: 0))
      layer.fill(path, with: .color(Self.tickColor))
    }
  }
}
