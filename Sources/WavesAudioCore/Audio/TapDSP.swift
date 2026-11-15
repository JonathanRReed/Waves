import Foundation

/// Sample format of a Core Audio tap buffer.
public enum TapSampleFormat: Hashable, Sendable {
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
  /// Scales `byteCount` bytes of samples in place by a constant `gain`,
  /// clamping to each format's valid range. A gain of exactly 1.0 leaves every
  /// finite sample bit-for-bit unchanged; non-finite float samples always
  /// become silence.
  public static func scale(
    _ data: UnsafeMutableRawPointer,
    byteCount: Int,
    format: TapSampleFormat,
    gain: Float
  ) {
    applyGain(
      data,
      byteCount: byteCount,
      format: format,
      channelsPerFrame: 1,
      from: gain,
      to: gain,
      clampsFloat: gain != 1.0
    )
  }

  /// Multiplies interleaved samples in place by a gain that moves linearly
  /// from `startGain` to `endGain` across the buffer's frames, so a gain change
  /// never lands as a step. The per-frame gain never leaves the range between
  /// the two endpoints.
  ///
  /// Float samples are clamped to ±1 only when `clampsFloat` is set, so earlier
  /// stages of the chain can pass headroom on to the final one. Integer
  /// samples always saturate, because the type cannot hold more. With both
  /// gains exactly 1.0 and no clamp, finite float samples stay bit-for-bit
  /// unchanged. Non-finite float samples become silence unconditionally: the
  /// caller has already copied the app's input into the output buffer, and a
  /// NaN would otherwise reach the device.
  public static func applyGain(
    _ data: UnsafeMutableRawPointer,
    byteCount: Int,
    format: TapSampleFormat,
    channelsPerFrame: Int,
    from startGain: Float,
    to endGain: Float,
    clampsFloat: Bool
  ) {
    let channels = max(1, channelsPerFrame)
    let isUnity = startGain == 1.0 && endGain == 1.0

    switch format {
    case .float32:
      let pointer = data.assumingMemoryBound(to: Float.self)
      let count = byteCount / MemoryLayout<Float>.size
      let frameCount = count / channels
      for index in 0..<count {
        let sample = pointer[index]
        guard sample.isFinite else {
          pointer[index] = 0
          continue
        }
        guard !isUnity || clampsFloat else { continue }
        let gain = rampGain(from: startGain, to: endGain, frame: index / channels, of: frameCount)
        let scaled = sample * gain
        pointer[index] = clampsFloat ? min(1.0, max(-1.0, scaled)) : scaled
      }
    case .int16:
      // Integer samples can't encode NaN/Inf, so unity gain really is a no-op.
      guard !isUnity else { return }
      let pointer = data.assumingMemoryBound(to: Int16.self)
      let count = byteCount / MemoryLayout<Int16>.size
      let frameCount = count / channels
      for index in 0..<count {
        let gain = rampGain(from: startGain, to: endGain, frame: index / channels, of: frameCount)
        pointer[index] = scaleSigned16(pointer[index], gain: gain)
      }
    case .int32:
      guard !isUnity else { return }
      let pointer = data.assumingMemoryBound(to: Int32.self)
      let count = byteCount / MemoryLayout<Int32>.size
      let frameCount = count / channels
      for index in 0..<count {
        let gain = rampGain(from: startGain, to: endGain, frame: index / channels, of: frameCount)
        pointer[index] = scaleSigned32(pointer[index], gain: gain)
      }
    case .unknown:
      break
    }
  }

  /// The gain for `frame` of a linear ramp that lands on `end` at the last
  /// frame, kept between the endpoints so rounding can never overshoot.
  @inline(__always)
  private static func rampGain(from start: Float, to end: Float, frame: Int, of frameCount: Int) -> Float {
    guard start != end, frame + 1 < frameCount else { return end }
    let gain = start + (end - start) * Float(frame + 1) / Float(frameCount)
    return min(max(start, end), max(min(start, end), gain))
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
    if !peak.isFinite || !sum.isFinite {
      peak = 0
      sum = 0
    }

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
