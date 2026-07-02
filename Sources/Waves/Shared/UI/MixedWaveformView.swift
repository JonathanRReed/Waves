import SwiftUI

// MARK: - Data

/// One live app's contribution to the mixed-wave visualizer: a stable identity
/// (so the wave's "voice" — its frequencies, drift, and hue — stays the same
/// for the same app across frames and sessions) and its perceptual level.
struct WaveComponent: Equatable, Identifiable {
  let id: String
  /// 0...1, already perceptually curved upstream (see `AppStore.waveComponents`).
  let level: Double
}

// MARK: - Engine

/// Owns all per-frame wave state — eased levels and accumulated phases — as a
/// reference type so the `TimelineView` closure can advance it without writing
/// `@State` during rendering, and so the motion is *continuous*: phases only
/// ever accumulate, which means frame-rate changes, level jumps, and voices
/// joining or leaving can never cause a visual snap.
///
/// Each app gets a deterministic "voice" derived from its logical ID: three
/// sine partials at irrational-feeling frequency ratios, individual drift
/// speeds and directions, and a hue from the cyan/teal family. The same app
/// always waves the same way — Spotify's wave is recognizably Spotify's.
@MainActor
final class WaveEngine {
  struct Voice {
    /// Eased level (fast attack / slow release), 0...1.
    var eased: Double = 0
    var target: Double = 0
    /// Accumulated phase per partial (radians). Never reset while alive.
    var phases: [Double]
    let freqs: [Double]
    /// Signed drift in rad/s per partial; sign varies per voice so some waves
    /// travel left and some right — small asymmetries are what keep the band
    /// from looking mechanically mirrored.
    let speeds: [Double]
    let weights: [Double]
    let color: Color

    init(seed: UInt64) {
      var rng = SplitMix64(seed: seed)
      freqs = [
        1.05 + 0.80 * rng.nextDouble(),
        2.30 + 1.30 * rng.nextDouble(),
        4.20 + 2.20 * rng.nextDouble(),
      ]
      speeds = [
        (0.50 + 0.40 * rng.nextDouble()) * (rng.nextBool() ? 1 : -1),
        (0.70 + 0.60 * rng.nextDouble()) * (rng.nextBool() ? 1 : -1),
        (1.00 + 0.80 * rng.nextDouble()) * (rng.nextBool() ? 1 : -1),
      ]
      weights = [0.60, 0.28, 0.12]
      phases = [
        rng.nextDouble() * 2 * .pi,
        rng.nextDouble() * 2 * .pi,
        rng.nextDouble() * 2 * .pi,
      ]
      color = Self.palette[Int(seed % UInt64(Self.palette.count))]
    }

    /// Cyan/teal family only, per DESIGN.md's Signal Rarity Rule — the voices
    /// differ in temperature within the signal hue, never in hue family.
    static let palette: [Color] = [
      Color(red: 0.62, green: 0.97, blue: 1.00),
      Color(red: 0.20, green: 0.87, blue: 0.95),
      Color(red: 0.05, green: 0.72, blue: 0.78),
      Color(red: 0.00, green: 0.58, blue: 0.66),
    ]
  }

  private(set) var voices: [String: Voice] = [:]
  /// Eased combined energy, 0...1 — drives the sum wave's glow intensity and
  /// the crossfade against the resting hairline.
  private(set) var energy: Double = 0
  /// Accumulated phases for the resting wave's two partials.
  private(set) var restPhases: [Double] = [0, .pi / 3]
  private(set) var time: TimeInterval = 0
  private var lastTime: TimeInterval?

  /// Seconds. Fast attack so a sound's onset registers immediately; slow
  /// release so silence is a graceful settle, not a cut.
  private let attack = 0.06
  private let release = 0.50

  func advance(to date: Date, components: [WaveComponent], mixedLevel: Double, frozen: Bool) {
    let now = date.timeIntervalSinceReferenceDate
    // Clamp dt so a stall (window hidden, debugger pause) can't snap the state.
    let dt = frozen ? 0 : (lastTime.map { max(0, min(0.1, now - $0)) } ?? (1.0 / 60.0))
    lastTime = now
    time = now

    // Retarget: every reported component keeps/gets a voice; anything no
    // longer reported eases toward zero and is reaped once inaudible, so a
    // stopping app's wave sinks into the baseline instead of blinking out.
    var targets: [String: Double] = [:]
    for component in components {
      targets[component.id] = component.level
      if voices[component.id] == nil {
        voices[component.id] = Voice(seed: Self.seed(for: component.id))
      }
    }

    for (id, voice) in voices {
      var voice = voice
      voice.target = targets[id] ?? 0
      let tau = voice.target > voice.eased ? attack : release
      let alpha = frozen ? 1.0 : 1 - exp(-dt / tau)
      voice.eased += alpha * (voice.target - voice.eased)
      if voice.target <= 0, voice.eased < 0.004 {
        voices[id] = nil
        continue
      }
      // Louder voices ripple faster — level modulates drift, so the band
      // audibly-visibly quickens with the mix instead of ticking at one rate.
      let rate = 0.35 + 1.40 * voice.eased
      for index in voice.phases.indices {
        voice.phases[index] += voice.speeds[index] * rate * dt
      }
      voices[id] = voice
    }

    let tau = mixedLevel > energy ? attack : release
    let alpha = frozen ? 1.0 : 1 - exp(-dt / tau)
    energy += alpha * (mixedLevel - energy)

    // The resting wave drifts very slowly, always — it's the "carrier" the
    // signals rise out of and settle back into.
    restPhases[0] += 0.30 * dt
    restPhases[1] += 0.45 * dt
  }

  /// True once everything has decayed to stillness — the render loop can drop
  /// to its idle cadence.
  var isSettled: Bool {
    energy < 0.004 && voices.values.allSatisfy { $0.eased < 0.004 && $0.target <= 0 }
  }

  private static func seed(for id: String) -> UInt64 {
    // FNV-1a: stable across launches (unlike `Hasher`), so an app's voice is
    // the same every session.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
  }
}

/// Tiny deterministic generator for deriving voice parameters from a seed.
private struct SplitMix64 {
  var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func nextDouble() -> Double {
    Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
  }

  mutating func nextBool() -> Bool {
    next() & 1 == 1
  }
}

// MARK: - View

/// The signature piece of the app: live superposition. Every playing app is a
/// thin translucent wave — its own frequencies, its own drift, its amplitude
/// riding that app's actual output level — and the bright wave through the
/// middle is their literal point-wise **sum**. When two apps play, you can
/// watch their crests reinforce and their opposing phases cancel; that
/// interference is computed, not staged. The name of the app, drawn.
///
/// Rendering is one continuous `Canvas` path for every state — loud, quiet,
/// fading, resting — with all motion state accumulated in `WaveEngine`. There
/// is no structural swap between an "active" and an "idle" view, which is what
/// used to make the handoff visible; the resting hairline and the live sum
/// simply crossfade as functions of the same eased energy.
///
/// Costs: while audible (plus a short settle window) it renders at the display
/// rate; once settled it drops to a 10 Hz drift for the ambient motion, which
/// is imperceptible on a hairline moving this slowly and keeps idle CPU noise-
/// floor low. Under Reduce Motion the timeline is static: the wave holds a
/// still pose and only amplitude changes (stepped, unanimated) as levels move.
struct MixedWaveformView: View {
  /// Per-app live contributions (real signal, no linger — see the live-state
  /// invariant note on `AppStore.waveComponents`).
  let components: [WaveComponent]
  /// Combined perceptual level 0...1, for glow intensity and accessibility.
  let level: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var engine = WaveEngine()
  /// Keeps the full-rate render loop mounted through a graceful settle after
  /// audio stops; cleared a beat later (see `.task`) so idle drops to 10 Hz.
  @State private var isActive = false

  private var isAudible: Bool { level > 0.012 || !components.isEmpty }
  private static let settleHold: Duration = .milliseconds(1800)

  var body: some View {
    Group {
      if reduceMotion {
        // Static pose: re-renders only when the (sparse) level data changes,
        // with phases frozen — amplitude without motion.
        Canvas { context, size in
          engine.advance(to: Date(timeIntervalSinceReferenceDate: 0), components: components, mixedLevel: level, frozen: true)
          draw(context, size: size)
        }
      } else if isActive {
        TimelineView(.animation) { timeline in
          Canvas { context, size in
            engine.advance(to: timeline.date, components: components, mixedLevel: level, frozen: false)
            draw(context, size: size)
          }
        }
      } else {
        // Same drawing, ambient cadence. Swapping timelines is seamless
        // because the picture is a pure function of the engine's accumulated
        // state — the first idle frame is pixel-continuous with the last
        // active one.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0)) { timeline in
          Canvas { context, size in
            engine.advance(to: timeline.date, components: components, mixedLevel: level, frozen: false)
            draw(context, size: size)
          }
        }
      }
    }
    // Fade every layer — baseline, threads, sum, glow — out over the last few
    // percent of each side, so the band dissolves into its surface instead of
    // ending in a hard-cut line against the container edge.
    .mask(
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black, location: 0.07),
          .init(color: .black, location: 0.93),
          .init(color: .clear, location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
    )
    // Mount the full-rate loop the instant sound appears; after it stops,
    // hold long enough for the slow release to carry every wave back down to
    // the baseline, then relax to the idle cadence.
    .task(id: isAudible) {
      if isAudible {
        isActive = true
      } else if isActive {
        try? await Task.sleep(for: Self.settleHold)
        guard !Task.isCancelled else { return }
        isActive = false
      }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityDescription)
    .accessibilityValue("\(Int((level * 100).rounded())) percent")
  }

  private var accessibilityDescription: String {
    components.isEmpty
      ? "Combined audio level"
      : "Combined audio level, mixing \(components.count) \(components.count == 1 ? "app" : "apps")"
  }

  // MARK: Drawing

  private func draw(_ context: GraphicsContext, size: CGSize) {
    let width = size.width
    guard width > 4, size.height > 4 else { return }
    let midY = size.height / 2
    let maxAmp = size.height / 2 - 2

    let sampleCount = max(48, min(180, Int(width / 2.5)))
    // Sorted by key so draw order is stable frame to frame — dictionary order
    // isn't, and z-order flapping where translucent strokes cross reads as
    // shimmer.
    let voices = engine.voices.sorted { $0.key < $1.key }.map(\.value).filter { $0.eased > 0.004 }
    let energy = engine.energy
    // Live layers fade in as energy rises; the resting hairline fades out on
    // the same curve, so the two are never both fully present.
    let liveMix = smoothstep(0.008, 0.06, energy)
    let restMix = 1 - liveMix
    let increased = contrast == .increased

    // Per-voice displacement at horizontal position u (0...1), in points.
    // Components render smaller than the band (0.55×) so the sum — which can
    // constructively exceed any one of them — visibly towers over its parts.
    func displacement(_ voice: WaveEngine.Voice, _ u: Double) -> Double {
      let amp = maxAmp * 0.72 * (0.24 + 0.76 * voice.eased)
      var wave = 0.0
      for index in 0..<3 {
        wave += voice.weights[index] * sin(2 * .pi * voice.freqs[index] * u + voice.phases[index])
      }
      return amp * wave * envelope(u)
    }

    // Sample every curve once; build the component paths and the sum path in
    // the same pass so the bright wave is provably the sum of the thin ones.
    var componentPoints: [[CGPoint]] = Array(repeating: [], count: voices.count)
    var sumPoints: [CGPoint] = []
    sumPoints.reserveCapacity(sampleCount + 1)
    var restPoints: [CGPoint] = []
    restPoints.reserveCapacity(sampleCount + 1)

    // The resting wave breathes very slowly (±14% over ~9s) so the band never
    // reads as inert, but never demands attention either.
    let breathe = 1 + 0.14 * sin(engine.time * 0.35)
    let restAmp = maxAmp * 0.09 * breathe

    for sample in 0...sampleCount {
      let u = Double(sample) / Double(sampleCount)
      let x = width * u
      var sum = 0.0
      for (index, voice) in voices.enumerated() {
        let y = displacement(voice, u)
        sum += y
        componentPoints[index].append(CGPoint(x: x, y: midY - y))
      }
      // Soft limiter: constructive peaks bloom toward the band edge but can
      // never clip through it — tanh gives the compression a musical knee.
      // The pre-limiter gain lets a single moderate source already swing a
      // healthy arc; multiple loud sources compress gracefully near the edge.
      let limited = maxAmp * tanh(1.35 * sum / max(maxAmp, 1))
      sumPoints.append(CGPoint(x: x, y: midY - limited))

      if restMix > 0.01 {
        let rest = restAmp * envelope(u) * (
          0.70 * sin(2 * .pi * 1.4 * u + engine.restPhases[0])
            + 0.30 * sin(2 * .pi * 2.9 * u + engine.restPhases[1])
        )
        restPoints.append(CGPoint(x: x, y: midY - rest))
      }
    }

    // 1. Baseline — the quiet wire everything rides on, edge to edge.
    var baseline = Path()
    baseline.move(to: CGPoint(x: 0, y: midY))
    baseline.addLine(to: CGPoint(x: width, y: midY))
    context.stroke(
      baseline,
      with: .color(.white.opacity(increased ? 0.28 : 0.10)),
      lineWidth: 1
    )

    let coreGradient = GraphicsContext.Shading.linearGradient(
      Gradient(colors: [Self.mid, Self.core, Self.mid]),
      startPoint: CGPoint(x: 0, y: midY),
      endPoint: CGPoint(x: width, y: midY)
    )

    // 2. Resting hairline + its faint halo (fades out as signal rises).
    if restMix > 0.01, restPoints.count > 1 {
      let restPath = smoothPath(through: restPoints)
      context.drawLayer { layer in
        layer.addFilter(.blur(radius: 4))
        layer.opacity = 0.20 * restMix
        layer.stroke(restPath, with: coreGradient, lineWidth: 3)
      }
      context.drawLayer { layer in
        layer.opacity = (increased ? 0.85 : 0.55) * restMix
        layer.stroke(restPath, with: coreGradient, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
      }
    }

    guard liveMix > 0.01, sumPoints.count > 1 else { return }
    let sumPath = smoothPath(through: sumPoints)

    // 3. Soft energy fill between the sum and the baseline — gives the wave a
    // body of light instead of leaving it a wire drawing. Kept faint; the
    // strokes carry the art.
    var fillPath = sumPath
    fillPath.addLine(to: CGPoint(x: width, y: midY))
    fillPath.addLine(to: CGPoint(x: 0, y: midY))
    fillPath.closeSubpath()
    context.drawLayer { layer in
      layer.opacity = (0.05 + 0.09 * energy) * liveMix
      layer.fill(fillPath, with: .color(Self.mid))
    }

    // 4. The component voices — luminous threads, each in its own cyan
    // temperature. These are the addends; they sit *under* the sum's glow so
    // the bright wave reads as gathering them up. Each thread gets its own
    // soft underlay so it reads as a strand of light, not a pencil line —
    // legible enough that the eye can follow one voice into the sum.
    for (index, voice) in voices.enumerated() where componentPoints[index].count > 1 {
      let path = smoothPath(through: componentPoints[index])
      context.drawLayer { layer in
        layer.addFilter(.blur(radius: 2.5))
        layer.opacity = (0.16 + 0.22 * voice.eased) * liveMix
        layer.stroke(path, with: .color(voice.color), lineWidth: 2.4)
      }
      context.drawLayer { layer in
        layer.opacity = (0.32 + 0.38 * voice.eased) * liveMix
        layer.stroke(path, with: .color(voice.color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
      }
    }

    // 5. The sum — halo, body, then a crisp bright core. Three layers of the
    // same path at different blurs is what makes it read as light rather than
    // a plotted line.
    context.drawLayer { layer in
      layer.addFilter(.blur(radius: 8 + 5 * energy))
      layer.opacity = (0.12 + 0.30 * energy) * liveMix
      layer.stroke(sumPath, with: coreGradient, lineWidth: 6)
    }
    context.drawLayer { layer in
      layer.addFilter(.blur(radius: 2.5))
      layer.opacity = (0.28 + 0.42 * energy) * liveMix
      layer.stroke(sumPath, with: coreGradient, lineWidth: 3)
    }
    context.drawLayer { layer in
      layer.addFilter(.blur(radius: 0.4))
      layer.opacity = (0.80 + 0.20 * energy) * liveMix
      layer.stroke(sumPath, with: coreGradient, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }
  }

  /// Spatial envelope: energy blooms in the center of the band and the waves
  /// settle onto the baseline at the edges — the signal rises out of the wire
  /// and returns to it, instead of being chopped off mid-oscillation (the
  /// single biggest tell of a "chart" rather than a living signal).
  private func envelope(_ u: Double) -> Double {
    pow(sin(.pi * u), 0.75)
  }

  private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
  }

  /// Catmull-Rom-ish smoothing: quad curves through midpoints, so the sampled
  /// polyline renders as one continuous ribbon with no visible vertices.
  private func smoothPath(through points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 2 else {
      points.dropFirst().forEach { path.addLine(to: $0) }
      return path
    }
    for index in 1..<points.count - 1 {
      let current = points[index]
      let next = points[index + 1]
      let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
      path.addQuadCurve(to: mid, control: current)
    }
    path.addLine(to: points[points.count - 1])
    return path
  }

  private static let core = Color(red: 0.55, green: 0.97, blue: 1.0)
  private static let mid = Color(red: 0.0, green: 0.85, blue: 0.90)
}

// MARK: - Store adapter

/// Reads the store's live per-app contributions and combined level, isolated
/// into its own small view so only this subtree re-evaluates when levels move
/// (a few times a second), not the whole header around it.
struct HeaderWaveform: View {
  @Environment(AppStore.self) private var store
  var height: CGFloat = 48

  var body: some View {
    MixedWaveformView(components: store.waveComponents, level: Double(store.mixedAudioLevel))
      .frame(height: height)
      .frame(maxWidth: .infinity)
  }
}
