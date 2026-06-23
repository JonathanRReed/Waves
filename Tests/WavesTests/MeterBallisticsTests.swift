import Foundation
import Testing
import WavesAudioCore

// MARK: - dB normalization

@Test func meterNormalizeFullScaleMapsToOne() {
  // 0 dBFS (amplitude 1.0) is the top of the meter.
  #expect(abs(MeterBallistics.normalize(1.0) - 1.0) < 1e-6)
}

@Test func meterNormalizeSilenceMapsToZero() {
  #expect(MeterBallistics.normalize(0.0) == 0)
  // Anything at/below the floor amplitude reads empty.
  let floorAmplitude = pow(10.0, MeterBallistics.floorDB / 20.0)
  #expect(MeterBallistics.normalize(floorAmplitude) < 0.001)
  // Below the floor clamps to 0, never negative.
  #expect(MeterBallistics.normalize(floorAmplitude / 10) == 0)
}

@Test func meterNormalizeIsMonotonic() {
  // Louder always reads higher across the audible range.
  let samples: [Double] = [0.005, 0.02, 0.05, 0.1, 0.25, 0.5, 0.9]
  let mapped = samples.map { MeterBallistics.normalize($0) }
  for i in 1..<mapped.count {
    #expect(mapped[i] > mapped[i - 1])
  }
}

@Test func meterNormalizeLiftsQuietAudioAboveLinear() {
  // The whole point of the dB map: a quiet -20 dBFS signal that a linear meter
  // would barely show (0.1 width) should register as a clearly-visible reading.
  let quiet = pow(10.0, -20.0 / 20.0) // 0.1 linear, −20 dBFS
  let mapped = MeterBallistics.normalize(quiet)
  #expect(mapped > 0.5)
  #expect(mapped < 1.0)
}

@Test func meterNormalizeClampsAboveFullScale() {
  // A boosted sample over 1.0 must not exceed full width.
  #expect(MeterBallistics.normalize(2.5) == 1.0)
}

@Test func meterNormalizeFloatMatchesDouble() {
  let f = MeterBallistics.normalize(Float(0.25))
  let d = MeterBallistics.normalize(0.25)
  #expect(abs(Double(f) - d) < 1e-4)
}

// MARK: - Peak-hold fall rate

@Test func peakFallRateMatchesDBPerSecondOverFloor() {
  // Position units/sec = dB/sec ÷ floor span; falling for `span/rate` seconds
  // traverses the whole meter.
  let expected = MeterBallistics.peakFallDBPerSec / -MeterBallistics.floorDB
  #expect(abs(MeterBallistics.peakFallPerSecond - expected) < 1e-9)
  // Sanity: at 13.3 dB/s a full-scale dot drops ~20 dB (≈0.37 of travel) in 1.5 s.
  let droppedIn1_5s = MeterBallistics.peakFallPerSecond * 1.5
  #expect(droppedIn1_5s > 0.3 && droppedIn1_5s < 0.45)
}
