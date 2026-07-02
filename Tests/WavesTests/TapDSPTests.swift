import Foundation
import Testing

@testable import WavesAudioCore

// MARK: - Float32 scaling + clip protection

@Test func float32BoostClampsToValidRange() {
  // 0.5 * 4x boost = 2.0, which must saturate to 1.0, not emit an out-of-range
  // sample. Negative samples clamp to -1.0.
  var samples: [Float] = [0.5, -0.5, 0.1, -0.9, 1.0]
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .float32, gain: 4.0)
  }
  #expect(samples[0] == 1.0)
  #expect(samples[1] == -1.0)
  #expect(abs(samples[2] - 0.4) < 1e-6)
  #expect(samples[3] == -1.0)
  #expect(samples[4] == 1.0)
}

@Test func gainOfOneIsNoOp() {
  var samples: [Float] = [0.123, -0.456, 0.789]
  let original = samples
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .float32, gain: 1.0)
  }
  #expect(samples == original)
}

@Test func float32AttenuationScalesLinearly() {
  var samples: [Float] = [0.8, -0.4]
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .float32, gain: 0.5)
  }
  #expect(abs(samples[0] - 0.4) < 1e-6)
  #expect(abs(samples[1] - (-0.2)) < 1e-6)
}

@Test func float32ScalingSilencesNonFiniteSamples() {
  // A NaN input sample must not survive the clamp as a -1.0 full-scale pop,
  // and infinities must not pass through; both become silence.
  var samples: [Float] = [Float.nan, Float.infinity, -Float.infinity, 0.5]
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .float32, gain: 2.0)
  }
  #expect(samples[0] == 0)
  #expect(samples[1] == 0)
  #expect(samples[2] == 0)
  #expect(samples[3] == 1.0)
}

@Test func float32ScalingSilencesNonFiniteSamplesAtUnityGain() {
  // Regression: sanitization must not be skipped by the gain == 1.0 fast
  // path — 100% volume with no boost is the *default* configuration, not an
  // edge case, so a NaN/Inf sample here must still be silenced rather than
  // passing straight through to the output device.
  var samples: [Float] = [Float.nan, Float.infinity, -Float.infinity, 0.123]
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .float32, gain: 1.0)
  }
  #expect(samples[0] == 0)
  #expect(samples[1] == 0)
  #expect(samples[2] == 0)
  #expect(samples[3] == 0.123)
}

// MARK: - Integer saturation

@Test func int16ScalingSaturatesInsteadOfOverflowing() {
  var samples: [Int16] = [20000, -20000, 100]
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .int16, gain: 4.0)
  }
  #expect(samples[0] == Int16.max) // 80000 saturates
  #expect(samples[1] == Int16.min)
  #expect(samples[2] == 400)
}

@Test func int32ScalingSaturatesInsteadOfOverflowing() {
  var samples: [Int32] = [1_000_000_000, -1_000_000_000]
  samples.withUnsafeMutableBytes { raw in
    TapDSP.scale(raw.baseAddress!, byteCount: raw.count, format: .int32, gain: 3.0)
  }
  #expect(samples[0] == Int32.max)
  #expect(samples[1] == Int32.min)
}

// MARK: - Levels

@Test func levelsComputesPeakAndRMSForKnownFloatInput() {
  let samples: [Float] = [1.0, -1.0, 1.0, -1.0]
  let (peak, sum, count) = samples.withUnsafeBytes { raw in
    TapDSP.levels(from: raw.baseAddress!, byteCount: raw.count, format: .float32)
  }
  #expect(peak == 1.0)
  #expect(count == 4)
  #expect(abs(TapDSP.rms(sum: sum, sampleCount: count) - 1.0) < 1e-6)
}

@Test func levelsOfSilenceIsZero() {
  let samples = [Float](repeating: 0, count: 8)
  let (peak, sum, count) = samples.withUnsafeBytes { raw in
    TapDSP.levels(from: raw.baseAddress!, byteCount: raw.count, format: .float32)
  }
  #expect(peak == 0)
  #expect(TapDSP.rms(sum: sum, sampleCount: count) == 0)
}

@Test func rmsOfZeroSamplesIsZeroNotNaN() {
  let rms = TapDSP.rms(sum: 0, sampleCount: 0)
  #expect(rms == 0)
  #expect(!rms.isNaN)
}

@Test func levelsWithNonFiniteSamplesStayFinite() {
  // NaN/inf samples poison the peak/sum accumulators; the poisoned levels must
  // come back as 0, never NaN (a NaN level propagates into snapshots and makes
  // every JSONEncoder session save throw).
  let samples: [Float] = [0.5, Float.nan, Float.infinity, -0.5]
  let (peak, sum, count) = samples.withUnsafeBytes { raw in
    TapDSP.levels(from: raw.baseAddress!, byteCount: raw.count, format: .float32)
  }
  #expect(peak == 0)
  #expect(sum == 0)
  #expect(count == 4)
  let rms = TapDSP.rms(sum: sum, sampleCount: count)
  #expect(rms == 0)
  #expect(!rms.isNaN)
}

@Test func rmsOfNonFiniteSumIsZero() {
  #expect(TapDSP.rms(sum: Float.nan, sampleCount: 4) == 0)
  #expect(TapDSP.rms(sum: Float.infinity, sampleCount: 4) == 0)
}

@Test func int16LevelsNormalizeToUnitRange() {
  let samples: [Int16] = [Int16.max, Int16.min]
  let (peak, _, count) = samples.withUnsafeBytes { raw in
    TapDSP.levels(from: raw.baseAddress!, byteCount: raw.count, format: .int16)
  }
  #expect(count == 2)
  #expect(abs(peak - 1.0) < 1e-3)
}
