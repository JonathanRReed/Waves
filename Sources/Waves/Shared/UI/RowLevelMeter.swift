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
    // Clamp dt so a stall (window hidden, debugger pause) can't snap the meter.
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
}

/// The quiet cyan "now playing" level bar shown along the bottom of a managed or
/// live mixer row. dB-mapped (so quiet audio actually registers), eased with fast
/// attack / slow release at the render clock (no staircase from the sparse poll),
/// with a brighter peak-hold tick that marks recent transients — the
/// professional-meter recipe. Holds the render loop briefly after silence so it
/// eases out instead of snapping; under Reduce Motion it binds straight to the
/// target with no clock. Purely decorative: hit-testing off, hidden from VoiceOver.
struct RowLevelMeter: View {
  @Environment(\.wavesTheme) private var theme
  /// Linear amplitudes (0…1) straight from the level poll. The bar tracks `rms`
  /// (steady body); the peak-hold tick tracks `peak` (transients).
  let rms: Float
  let peak: Float

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var model = LevelMeterModel()
  @State private var isAnimating = false

  private static let height: CGFloat = 2.5
  private static let tickWidth: CGFloat = 2.5
  /// Brighter cyan than the bar gradient so the peak tick reads as a highlight.
  private static let tickColor = Color(red: 0.72, green: 0.98, blue: 1.0)

  private var barTarget: Double { Double(MeterBallistics.normalize(rms)) }
  private var peakTarget: Double { Double(MeterBallistics.normalize(peak)) }
  private var isActive: Bool { barTarget > 0.001 || peakTarget > 0.001 }

  var body: some View {
    GeometryReader { proxy in
      meterContent(width: proxy.size.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    // Cross-fade the clock ⇄ idle handoff so the meter dissolves rather than
    // blinking off when an app goes quiet.
    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: isAnimating)
    // Hold the render loop after silence until the eased bar AND peak-hold dot
    // have both settled, so a loud row's release / peak tails play all the way
    // out instead of blinking off at a fixed time — and so a remount never
    // inherits a stale peak. A safety cap bounds the worst case; a returning
    // signal cancels this and resumes the live loop.
    .task(id: isActive) {
      if isActive {
        isAnimating = true
      } else if isAnimating {
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
  private func meterContent(width: CGFloat) -> some View {
    if reduceMotion {
      shapes(width: width, bar: barTarget, peak: peakTarget)
    } else if isAnimating {
      TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
        easedShapes(width: width, at: timeline.date)
      }
      .transition(.opacity)
    } else {
      Color.clear.transition(.opacity)
    }
  }

  /// Advances the model one frame, then draws — kept as a plain func (not a
  /// `ViewBuilder` closure) so the side-effecting update can run before the draw.
  private func easedShapes(width: CGFloat, at date: Date) -> some View {
    model.update(barTarget: barTarget, peakTarget: peakTarget, at: date)
    return shapes(width: width, bar: model.bar, peak: model.peak)
  }

  @ViewBuilder
  private func shapes(width: CGFloat, bar: Double, peak: Double) -> some View {
    ZStack(alignment: .bottomLeading) {
      Capsule()
        .fill(theme.accentGradient)
        .frame(width: max(0, width * CGFloat(bar)), height: Self.height)
        // Glow swells with the signal: barely-there when quiet, a brighter bloom
        // when hot, so a glance reads how loud the app is, not just that it plays.
        .shadow(color: theme.accent.opacity(0.30 + 0.40 * bar), radius: 2 + 3 * bar, y: 0)

      // Peak-hold tick — only once there's a meaningful transient to mark.
      if peak > 0.02 {
        Capsule()
          .fill(Self.tickColor)
          .frame(width: Self.tickWidth, height: Self.height)
          .shadow(color: theme.accent.opacity(0.6), radius: 2, y: 0)
          .offset(x: max(0, min(width - Self.tickWidth, width * CGFloat(peak) - Self.tickWidth / 2)))
      }
    }
    .frame(width: width, height: Self.height, alignment: .bottomLeading)
  }
}
