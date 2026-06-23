import Foundation

/// Pure, dependency-free scaling + ballistics math for the per-app level meters.
///
/// Kept next to `TapDSP` so the dB mapping, attack/release smoothing, and
/// peak-hold fall are one tunable, unit-testable source of truth rather than
/// magic numbers scattered across the views. Nothing here touches Core Audio or
/// the main actor — it's plain math the meter views call each render frame.
public enum MeterBallistics {
  /// Amplitude floor in dBFS: at or below this the meter reads empty. -54 dBFS
  /// sits in the pro -50…-60 range — quiet program material still moves the bar,
  /// but the noise floor doesn't.
  public static let floorDB: Double = -54

  /// Gamma applied after the dB normalization. <1 lifts the lower range so quiet
  /// audio is visible while the top few dB compress like a VU.
  public static let topGamma: Double = 0.85

  /// Bar smoother time constants (seconds): fast rise, slow fall — the universal
  /// VU/PPM "feel" that also hides the sparse (~3 Hz) level poll.
  public static let attack: Double = 0.08
  public static let release: Double = 0.70

  /// Peak-hold dot: seconds it holds at a fresh peak before falling, and how fast
  /// it then falls (dB/second). ~20 dB over 1.5 s matches a typical PPM.
  public static let peakHold: Double = 0.90
  public static let peakFallDBPerSec: Double = 13.3

  /// Maps a linear amplitude (0…1) to a normalized meter position (0…1) on a dB
  /// scale with a fixed floor, then applies `topGamma`. Inputs are clamped, so
  /// 0 and negative amplitudes map to 0 and ≥1.0 maps to 1.
  public static func normalize(_ amplitude: Double, floorDB dbFloor: Double = floorDB) -> Double {
    let db = 20 * log10(max(amplitude, 1e-5))
    let span = max(1e-6, -dbFloor) // floor is negative; span = 0 dBFS − floor
    let position = (db - dbFloor) / span
    return pow(min(1, max(0, position)), topGamma)
  }

  /// `Float` convenience for the meter views (levels arrive as `Float`).
  public static func normalize(_ amplitude: Float, floorDB dbFloor: Double = floorDB) -> Float {
    Float(normalize(Double(amplitude), floorDB: dbFloor))
  }

  /// Per-frame fall of the peak-hold dot expressed in *position* units/second
  /// (the dB fall rate divided by the floor span), so callers can decrement the
  /// already-normalized peak position directly.
  public static var peakFallPerSecond: Double {
    peakFallDBPerSec / max(1e-6, -floorDB)
  }
}
