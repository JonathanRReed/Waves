import SwiftUI

/// Eases the combined audio level between the sparse (~3–4 Hz) level updates so
/// the glow animates smoothly at the render clock's rate. Uses a
/// frame-rate-independent attack/release low-pass (fast rise, slow fall — the
/// VU-meter feel), recomputing the smoothing coefficient from real elapsed time
/// each frame so it behaves the same at 60 or 120 Hz. Held as a reference type
/// so the per-frame `TimelineView` closure can update it without writing
/// `@State` during view rendering.
@MainActor
final class WaveLevelModel {
  private(set) var level: Double = 0
  private var lastTime: TimeInterval?
  /// Seconds. Smaller attack = snappier rise; larger release = smoother decay.
  /// The release is deliberately slow so that when audio stops the glow eases
  /// all the way down over roughly a second — a graceful settle, not a cut.
  var attack: Double = 0.05
  var release: Double = 0.42

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

/// A single soft, breathing glow that visualizes the combined audio energy of
/// every currently-playing app — deliberately *not* a literal waveform.
///
/// Apple's own audio-reactive chrome — the Siri glow, the recording-active dot
/// in the menu bar, the watchOS "Now Playing" breathing ring, Control Center's
/// soft-edged module fills — favors blur, scale, and opacity over drawn line
/// art. A hand-drawn sine wave reads as a chart; a soft glow reads as light,
/// which is what makes those system surfaces feel alive rather than
/// diagrammatic. This view leans entirely on that language: one elliptical
/// core of light plus a wider, softer halo beneath it, both breathing in
/// width/opacity/blur with the eased audio level, with a very slow ambient
/// breathe at rest so the band is never inert.
///
/// Stays cheap at idle: the active glow's continuous render loop
/// (`TimelineView(.animation)`) only mounts while audio is audible (plus a
/// short fade-out hold); the resting state is a single implicit SwiftUI
/// animation on static geometry, which costs nothing per-frame.
struct MixedWaveformView: View {
  /// Combined level, 0...1 (already mixed + perceptually curved upstream).
  let level: Double

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var model = WaveLevelModel()
  /// Keeps the animated glow mounted through a graceful fade after audio stops,
  /// instead of swapping to the resting glow the instant the level hits zero.
  /// Set true the moment sound returns; cleared a beat after it stops (see
  /// `.task`).
  @State private var isAnimating = false
  /// Drives the idle ambient breathe — a single slow, looping cycle that is
  /// always running but costs nothing (implicit animation, not a render
  /// loop). Flipping this boolean back and forth with `.repeatForever`
  /// is how SwiftUI animates it without any per-frame work on our part.
  @State private var idleBreathe = false

  // Cyan/teal only, per DESIGN.md's Signal Rarity Rule.
  private static let core = Color(red: 0.50, green: 0.96, blue: 1.0)
  private static let mid = Color(red: 0.0, green: 0.85, blue: 0.90)
  private static let deep = Color(red: 0.0, green: 0.55, blue: 0.58)

  private var isAudible: Bool { level > 0.012 }
  /// How long the render loop stays alive after audio stops, giving
  /// `WaveLevelModel`'s slow release time to ease the glow down to nothing
  /// before we hand off to the (zero-CPU) resting state.
  private static let fadeOutHold: Duration = .milliseconds(1500)

  var body: some View {
    Group {
      // Under Reduce Motion, always show the resting glow with motion fully
      // disabled (still breathes via plain opacity cross-fade driven by
      // `level`, never position/scale). Otherwise animate the glow while
      // sound is flowing AND through the fade-out hold, then drop to the
      // resting state (no render loop) so idle CPU stays near zero.
      if reduceMotion {
        restingGlow(animateAmbient: false)
          .transition(.opacity)
      } else if isAnimating {
        activeGlow
          .transition(.opacity)
      } else {
        restingGlow(animateAmbient: true)
          .transition(.opacity)
      }
    }
    // Cross-fade the active ⇄ resting handoff so the switch is never visible;
    // by the time it happens the glow has already eased down to near-flat.
    .animation(.easeInOut(duration: 0.45), value: isAnimating)
    // Drive the mount/unmount of the render loop. Re-runs whenever audibility
    // flips: sound returning cancels a pending fade-out (no blink on a brief
    // gap); sound stopping holds the loop for `fadeOutHold` so the glow can
    // settle, then releases it.
    .task(id: isAudible) {
      if isAudible {
        isAnimating = true
      } else if isAnimating {
        try? await Task.sleep(for: Self.fadeOutHold)
        guard !Task.isCancelled else { return }
        isAnimating = false
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Combined audio level")
    .accessibilityValue("\(Int((level * 100).rounded())) percent")
  }

  // MARK: - Active state

  /// While audio is flowing: a layered glow — a wide, very soft halo and a
  /// tighter, brighter core — both breathing in width, opacity, and blur
  /// radius with the eased level. Motion uses a gentle custom timing curve
  /// (slow-in/slow-out) rather than linear or system-spring bounce, so the
  /// breathe reads as organic and unhurried, the way Siri's glow or a
  /// recording indicator pulses rather than mechanically ticking.
  private var activeGlow: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      Canvas { context, size in
        // While audible, hold a small floor so the glow never fully
        // flatlines; once silent, ease toward true zero so the fade
        // actually reaches the bottom (the slow `release` makes that
        // descent graceful, not a cut).
        let target = isAudible ? max(level, 0.05) : level
        model.update(target: target, at: timeline.date)
        let lvl = model.level

        // A slow secondary phase — not audio-driven — gives the glow a very
        // subtle internal shimmer so it never looks like a static painted
        // shape even while the level itself holds steady. Kept tiny (±4%)
        // so it reads as "alive," not "wobbling."
        let shimmer = 1.0 + 0.04 * sin(timeline.date.timeIntervalSinceReferenceDate * 0.9)

        drawGlow(context, size: size, level: lvl, shimmer: shimmer)
      }
    }
    .accessibilityHidden(true)
  }

  /// Draws the halo + core glow stack for one frame. Three soft layers,
  /// widest/dimmest to narrowest/brightest, each blurred independently so
  /// the falloff looks like real light rather than a single blurred capsule
  /// (which tends to read as a smear). All layers share the same center and
  /// width-from-level relationship so they breathe in lockstep.
  private func drawGlow(_ context: GraphicsContext, size: CGSize, level: Double, shimmer: Double) {
    let midY = size.height / 2
    let maxHalfWidth = size.width / 2 - 2
    // Width breathes from a calm ~30% of the band at silence to nearly
    // full-width at peak — proportion is what keeps this from feeling like a
    // toggle between "off" and "on": there's always a presence, it just
    // grows.
    let halfWidth = maxHalfWidth * (0.30 + 0.70 * min(level, 1.0)) * shimmer
    let centerX = size.width / 2

    func capsule(halfW: Double, halfH: Double) -> Path {
      Path(roundedRect: CGRect(
        x: centerX - halfW, y: midY - halfH, width: halfW * 2, height: halfH * 2
      ), cornerRadius: halfH)
    }

    let coreHeight = max(size.height * 0.10, 1.5) + size.height * 0.34 * level
    let midHeight = coreHeight * 1.9
    let haloHeight = coreHeight * 3.4

    // Outer halo — wide, very soft, low opacity. This is the layer that
    // gives the band ambient "glow" even before you consciously notice a
    // shape; it's the same trick a recording-active dot or a Siri orb uses
    // to feel like it's casting light rather than being a sticker pasted on
    // the surface.
    context.drawLayer { layer in
      layer.addFilter(.blur(radius: 10 + 6 * level))
      layer.opacity = 0.16 + 0.22 * level
      layer.fill(
        capsule(halfW: halfWidth, halfH: haloHeight / 2),
        with: .linearGradient(
          Gradient(colors: [Self.deep, Self.mid, Self.deep]),
          startPoint: CGPoint(x: centerX - halfWidth, y: midY),
          endPoint: CGPoint(x: centerX + halfWidth, y: midY)
        )
      )
    }

    // Mid layer — tighter, brighter, moderate blur. Carries most of the
    // perceived "body" of the glow.
    context.drawLayer { layer in
      layer.addFilter(.blur(radius: 4 + 3 * level))
      layer.opacity = 0.30 + 0.40 * level
      layer.fill(
        capsule(halfW: halfWidth * 0.92, halfH: midHeight / 2),
        with: .linearGradient(
          Gradient(colors: [Self.mid, Self.core, Self.mid]),
          startPoint: CGPoint(x: centerX - halfWidth, y: midY),
          endPoint: CGPoint(x: centerX + halfWidth, y: midY)
        )
      )
    }

    // Core — small, crisp-edged (minimal blur), brightest. This is the
    // "hairline of light" the rest of the glow radiates from, and it's
    // what stays visible even at very low levels so the band never looks
    // like it switched off.
    context.drawLayer { layer in
      layer.addFilter(.blur(radius: 0.6))
      layer.opacity = 0.55 + 0.45 * level
      layer.fill(
        capsule(halfW: halfWidth * 0.6, halfH: coreHeight / 2),
        with: .linearGradient(
          Gradient(colors: [Self.mid, Self.core, Self.mid]),
          startPoint: CGPoint(x: centerX - halfWidth, y: midY),
          endPoint: CGPoint(x: centerX + halfWidth, y: midY)
        )
      )
    }
  }

  // MARK: - Resting state

  /// No audio (the common state for a glanced-at menu bar utility) or Reduce
  /// Motion: a thin hairline-width glow capsule, dim but never invisible,
  /// that very slowly breathes in opacity and width over a multi-second
  /// cycle. This is intentionally underplayed — the point of "minimal
  /// breathing glow" is that rest should look designed, not like a disabled
  /// control. No position or scale change, just a gentle opacity/width
  /// crossfade via SwiftUI's own animation system, so it costs nothing per
  /// frame.
  private func restingGlow(animateAmbient: Bool) -> some View {
    GeometryReader { geo in
      let levelWidth = geo.size.width * (0.16 + 0.10 * level)
      let breatheWidth = animateAmbient && idleBreathe ? levelWidth * 1.12 : levelWidth
      let baseOpacity = 0.18 + 0.55 * level
      let breatheOpacity = animateAmbient && idleBreathe ? baseOpacity * 1.25 : baseOpacity
      let h = max(geo.size.height * 0.16, 2.0)

      ZStack {
        // Faint halo, always present, barely perceptible.
        Capsule()
          .fill(
            LinearGradient(
              colors: [Self.deep, Self.mid, Self.deep],
              startPoint: .leading, endPoint: .trailing
            )
          )
          .frame(width: breatheWidth * 1.6, height: h * 2.6)
          .blur(radius: 7)
          .opacity(breatheOpacity * 0.5)

        // Thin core hairline — what reads as "there's a faint signal here"
        // even with nothing playing.
        Capsule()
          .fill(
            LinearGradient(
              colors: [Self.mid, Self.core, Self.mid],
              startPoint: .leading, endPoint: .trailing
            )
          )
          .frame(width: breatheWidth, height: h)
          .blur(radius: 0.4)
          .opacity(breatheOpacity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    // The active-level component eases quickly (so silence settles fast);
    // the ambient breathe underneath uses its own slow looping animation
    // started in `.task` below.
    .animation(.easeInOut(duration: 0.45), value: level)
    .task {
      guard animateAmbient else { return }
      // A single slow, symmetric breathe — ~4.5s out, ~4.5s back — kept
      // subtle (see the multipliers above) so it reads as "calmly alive,"
      // never as a loading spinner or an attention-seeking pulse.
      withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
        idleBreathe = true
      }
    }
    .onDisappear { idleBreathe = false }
  }
}

/// Reads the store's combined level and renders the glow. Isolated into its
/// own small view so only this view re-evaluates when levels change (a few
/// times a second), not the whole header around it.
struct HeaderWaveform: View {
  @Environment(AppStore.self) private var store
  var height: CGFloat = 40

  var body: some View {
    MixedWaveformView(level: Double(store.mixedAudioLevel))
      .frame(height: height)
      .frame(maxWidth: .infinity)
  }
}
