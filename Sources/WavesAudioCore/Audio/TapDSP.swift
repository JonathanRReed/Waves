import Foundation

/// Sample format of a Core Audio tap buffer.
public enum TapSampleFormat: Sendable {
  case float32
  case int16
  case int32
  case unknown
}

/// Pure, allocation-free sample math for the realtime tap render path.
///
/// This is intentionally free of any Core Audio handles so it can be unit
/// tested directly (the controller that owns the IO proc forwards raw buffers
/// here). All functions are safe to call on the realtime audio thread: no
/// allocation, locking, or Objective-C dispatch.
public enum TapDSP {
  /// Scales `byteCount` bytes of interleaved samples in place by `gain`,
  /// clamping to each format's valid range so boost cannot emit out-of-range
  /// samples that clip harshly downstream. A gain of exactly 1.0 is a no-op.
  public static func scale(
    _ data: UnsafeMutableRawPointer,
    byteCount: Int,
    format: TapSampleFormat,
    gain: Float
  ) {
    guard gain != 1.0 else { return }

    switch format {
    case .float32:
      let pointer = data.assumingMemoryBound(to: Float.self)
      let count = byteCount / MemoryLayout<Float>.size
      for index in 0..<count {
        let sample = pointer[index]
        // A NaN sample survives the clamp as -1.0 — a full-scale pop. Replace
        // non-finite input with silence instead.
        guard sample.isFinite else {
          pointer[index] = 0
          continue
        }
        pointer[index] = min(1.0, max(-1.0, sample * gain))
      }
    case .int16:
      let pointer = data.assumingMemoryBound(to: Int16.self)
      let count = byteCount / MemoryLayout<Int16>.size
      for index in 0..<count {
        pointer[index] = scaleSigned16(pointer[index], gain: gain)
      }
    case .int32:
      let pointer = data.assumingMemoryBound(to: Int32.self)
      let count = byteCount / MemoryLayout<Int32>.size
      for index in 0..<count {
        pointer[index] = scaleSigned32(pointer[index], gain: gain)
      }
    case .unknown:
      break
    }
  }

  /// Computes peak magnitude, sum-of-squares, and sample count over a buffer,
  /// normalized to [0, 1]. Callers accumulate `sum`/`sampleCount` across buffers
  /// then take `sqrt(sum / sampleCount)` for RMS.
  public static func levels(
    from data: UnsafeRawPointer,
    byteCount: Int,
    format: TapSampleFormat
  ) -> (peak: Float, sum: Float, sampleCount: UInt32) {
    var peak: Float = 0
    var sum: Float = 0
    var sampleCount: UInt32 = 0

    switch format {
    case .float32:
      let pointer = data.assumingMemoryBound(to: Float.self)
      let count = byteCount / MemoryLayout<Float>.size
      for index in 0..<count {
        let sample = abs(pointer[index])
        peak = max(peak, sample)
        sum += sample * sample
        sampleCount += 1
      }
    case .int16:
      let pointer = data.assumingMemoryBound(to: Int16.self)
      let count = byteCount / MemoryLayout<Int16>.size
      for index in 0..<count {
        let sample = abs(Float(pointer[index])) / Float(Int16.max)
        peak = max(peak, sample)
        sum += sample * sample
        sampleCount += 1
      }
    case .int32:
      let pointer = data.assumingMemoryBound(to: Int32.self)
      let count = byteCount / MemoryLayout<Int32>.size
      for index in 0..<count {
        let sample = abs(Float(pointer[index])) / Float(Int32.max)
        peak = max(peak, sample)
        sum += sample * sample
        sampleCount += 1
      }
    case .unknown:
      break
    }

    // Non-finite input samples (NaN/inf from a misbehaving app) poison the
    // accumulators; NaN levels would propagate into snapshots and make every
    // JSONEncoder session save throw. Report silence for such buffers.
    if !peak.isFinite { peak = 0 }
    if !sum.isFinite { sum = 0 }

    return (peak, sum, sampleCount)
  }

  /// Root-mean-square from accumulated sum-of-squares and sample count.
  public static func rms(sum: Float, sampleCount: UInt32) -> Float {
    guard sampleCount > 0 else { return 0 }
    let value = (sum / Float(sampleCount)).squareRoot()
    return value.isFinite ? value : 0
  }

  static func scaleSigned16(_ sample: Int16, gain: Float) -> Int16 {
    let scaled = Float(sample) * gain
    if scaled >= Float(Int16.max) { return Int16.max }
    if scaled <= Float(Int16.min) { return Int16.min }
    return Int16(scaled.rounded())
  }

  static func scaleSigned32(_ sample: Int32, gain: Float) -> Int32 {
    let scaled = Float(sample) * gain
    if scaled >= Float(Int32.max) { return Int32.max }
    if scaled <= Float(Int32.min) { return Int32.min }
    return Int32(scaled.rounded())
  }
}
