import Foundation
import Testing
import WavesAudioCore

@testable import Waves

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
  let quiet = pow(10.0, -20.0 / 20.0)  // 0.1 linear, −20 dBFS
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

@MainActor
@Test func levelMeterModelInitialStepAndAttackAreDeterministic() {
  let model = LevelMeterModel()
  let start = Date(timeIntervalSinceReferenceDate: 10)
  model.update(barTarget: 1, peakTarget: 0.8, at: start)

  let expectedInitial = 1 - exp(-(1.0 / 60.0) / MeterBallistics.attack)
  #expect(abs(model.bar - expectedInitial) < 1e-12)
  #expect(model.peak == 0.8)

  let beforeAttack = model.bar
  model.update(barTarget: 1, peakTarget: 0.8, at: start.addingTimeInterval(0.1))
  let attackGain = model.bar - beforeAttack
  let beforeRelease = model.bar
  model.update(barTarget: 0, peakTarget: 0, at: start.addingTimeInterval(0.2))
  let releaseDrop = beforeRelease - model.bar
  #expect(attackGain > releaseDrop, "attack must respond faster than release over the same timestep")
}

@MainActor
@Test func levelMeterModelPeakHoldAndFixedFallUseSuppliedDates() {
  let model = LevelMeterModel()
  let start = Date(timeIntervalSinceReferenceDate: 20)
  model.update(barTarget: 0, peakTarget: 1, at: start)

  for step in 1...10 {
    model.update(
      barTarget: 0,
      peakTarget: 0,
      at: start.addingTimeInterval(Double(step) * 0.1)
    )
  }
  #expect(model.peak == 1, "the peak must remain fixed throughout its hold interval")

  model.update(barTarget: 0, peakTarget: 0, at: start.addingTimeInterval(1.1))
  let expected = 1 - MeterBallistics.peakFallPerSecond * 0.1
  #expect(abs(model.peak - expected) < 1e-12)
}

@MainActor
@Test func levelMeterModelSettledThresholdResetAndNonpositiveTimeAreDeterministic() {
  let model = LevelMeterModel()
  let start = Date(timeIntervalSinceReferenceDate: 30)
  model.update(barTarget: 0.001, peakTarget: 0.001, at: start)
  #expect(model.isSettled)

  model.reset()
  model.update(barTarget: 1, peakTarget: 1, at: start)
  let bar = model.bar
  let peak = model.peak
  model.update(barTarget: 0, peakTarget: 0, at: start)
  #expect(model.bar == bar)
  #expect(model.peak == peak)
  model.update(barTarget: 0, peakTarget: 0, at: start.addingTimeInterval(-1))
  #expect(model.bar == bar)
  #expect(model.peak == peak)

  model.reset()
  #expect(model.bar == 0)
  #expect(model.peak == 0)
  #expect(model.isSettled)
}
