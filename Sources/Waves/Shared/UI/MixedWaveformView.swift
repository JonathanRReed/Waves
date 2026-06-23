import SwiftUI

/// Eases the combined audio level between the sparse (~3–4 Hz) level updates so
/// the visualizer animates smoothly at the render clock's rate. Uses a
/// frame-rate-independent attack/release low-pass (fast rise, slow fall — the
/// VU-meter feel), recomputing the smoothing coefficient from real elapsed time
/// each frame so it behaves the same at 60 or 120 Hz. Held as a reference type
/// so the per-frame `Canvas` closure can update it without writing `@State`
/// during view rendering.
@MainActor
final class WaveLevelModel {
  private(set) var level: Double = 0
  private var lastTime: TimeInterval?
  /// Seconds. Smaller attack = snappier rise; larger release = smoother decay.
  var attack: Double = 0.05
  var release: Double = 0.30

  func update(target: Double, at date: Date) {
    let now = date.timeIntervalSinceReferenceDate
    // Clamp dt so a stall (window hidden, debugger pause) can't snap the level.
    let dt = lastTime.map { max(0, min(0.1, now - $0)) } ?? (1.0 / 60.0)
    lastTime = now
    let tau = target > level ? attack : release
    let alpha = 1 - exp(-dt / max(tau, 1e-4))
    level += alpha * (target - level)
  }
}

/// A flowing, layered "mixed waveform" that visualizes the combined audio energy
/// of every currently-playing app. A continuous `TimelineView(.animation)` render
/// clock drives the horizontal phase while `WaveLevelModel` eases the amplitude,
/// so the ribbon stays smooth and alive even though the underlying levels update
/// only a few times a second. Purely decorative — it freezes to a static level
/// bar under Reduce Motion, and pauses its clock entirely when nothing is audible
/// so idle CPU stays near zero.
struct MixedWaveformView: View {
  /// Combined level, 0...1 (already mixed + perceptually curved upstream).
  let level: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var model = WaveLevelModel()

  private static let palette: [Color] = [
    Color(red: 0.50, green: 0.96, blue: 1.0),
    Color(red: 0.0, green: 0.82, blue: 0.96),
    Color(red: 0.32, green: 0.58, blue: 1.0),
  ]
  private var gradient: Gradient { Gradient(colors: Self.palette) }
  private var isAudible: Bool { level > 0.012 }

  var body: some View {
    Group {
      // Render a static level bar when audio is silent (zero CPU — no render
      // loop) or when Reduce Motion is on; only animate the ribbon while sound
      // is actually flowing.
      if reduceMotion || !isAudible {
        staticBar
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
          Canvas { context, size in
            // Keep a small floor while audible so the ribbon never fully flatlines.
            model.update(target: max(level, 0.06), at: timeline.date)
            let phase = timeline.date.timeIntervalSinceReferenceDate * 1.7
            let lvl = model.level

            // Soft glow underlay.
            context.drawLayer { layer in
              layer.addFilter(.blur(radius: 5))
              drawWave(layer, size: size, level: lvl, phase: phase, frequency: 1.2, scale: 1.0, lineWidth: 4)
            }
            // Filled mirrored body for weight.
            drawBody(context, size: size, level: lvl, phase: phase)
            // Crisp stacked layers at different frequencies for a living, non-repeating ribbon.
            drawWave(context, size: size, level: lvl, phase: phase, frequency: 1.2, scale: 1.0, lineWidth: 2.2)
            drawWave(context, size: size, level: lvl, phase: phase + 1.3, frequency: 2.15, scale: 0.6, lineWidth: 1.6)
            drawWave(context, size: size, level: lvl, phase: phase + 2.7, frequency: 3.4, scale: 0.34, lineWidth: 1.1)
          }
        }
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Combined audio level")
    .accessibilityValue("\(Int((level * 100).rounded())) percent")
  }

  /// One stroked, edge-tapered sine layer. Amplitude is driven by the eased level.
  private func drawWave(
    _ context: GraphicsContext, size: CGSize,
    level: Double, phase: Double, frequency: Double, scale: Double, lineWidth: Double
  ) {
    let midY = size.height / 2
    let maxAmplitude = midY * 0.86 * scale * max(level, 0.04)
    let step = 2.0
    var path = Path()
    var x = 0.0
    var first = true
    while x <= size.width {
      let t = x / max(size.width, 1)
      let taper = pow(sin(t * .pi), 1.3) // 0 at edges, 1 in the centre
      let y = midY + sin(t * .pi * 2 * frequency + phase) * maxAmplitude * taper
      let point = CGPoint(x: x, y: y)
      if first { path.move(to: point); first = false } else { path.addLine(to: point) }
      x += step
    }
    context.stroke(
      path,
      with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
      style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    )
  }

  /// A soft, mirrored fill under the primary wave to give the ribbon body.
  private func drawBody(_ context: GraphicsContext, size: CGSize, level: Double, phase: Double) {
    let midY = size.height / 2
    let maxAmplitude = midY * 0.86 * max(level, 0.04)
    let step = 3.0
    var path = Path()
    var x = 0.0
    var first = true
    while x <= size.width {
      let t = x / max(size.width, 1)
      let taper = pow(sin(t * .pi), 1.3)
      let y = midY + sin(t * .pi * 2 * 1.2 + phase) * maxAmplitude * taper
      let point = CGPoint(x: x, y: y)
      if first { path.move(to: point); first = false } else { path.addLine(to: point) }
      x += step
    }
    x = size.width
    while x >= 0 {
      let t = x / max(size.width, 1)
      let taper = pow(sin(t * .pi), 1.3)
      let y = midY - sin(t * .pi * 2 * 1.2 + phase) * maxAmplitude * taper
      path.addLine(to: CGPoint(x: x, y: y))
      x -= step
    }
    path.closeSubpath()
    context.fill(
      path,
      with: .linearGradient(
        Gradient(colors: [Self.palette[0].opacity(0.20), Self.palette[2].opacity(0.05)]),
        startPoint: .zero,
        endPoint: CGPoint(x: size.width, y: 0)
      )
    )
  }

  /// Reduce Motion / idle alternative: a centered level bar that eases (fade, not
  /// motion). The parent already exposes one labeled "Combined audio level"
  /// element via `.accessibilityElement()`, so no per-branch a11y is needed here.
  private var staticBar: some View {
    Capsule()
      .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
      .frame(height: 2 + 5 * level)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .opacity(0.3 + 0.7 * level)
      .animation(.easeOut(duration: 0.25), value: level)
  }
}

/// Reads the store's combined level and renders the waveform. Isolated into its
/// own small view so only this view re-evaluates when levels change (a few times
/// a second), not the whole header around it.
struct HeaderWaveform: View {
  @Environment(AppStore.self) private var store
  var height: CGFloat = 40

  var body: some View {
    MixedWaveformView(level: Double(store.mixedAudioLevel))
      .frame(height: height)
      .frame(maxWidth: .infinity)
  }
}
