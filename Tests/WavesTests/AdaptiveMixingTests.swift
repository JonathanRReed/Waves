import Foundation
import Testing

@testable import WavesAudioCore

private func amplitude(dbFS: Double) -> Double {
  pow(10, dbFS / 20)
}

private func voiceEnergy(fullBandRMS: Double, ratio: Double) -> Double {
  fullBandRMS * fullBandRMS * ratio
}

// MARK: - Speech detection

@Test func speechDetectionRequiresThresholdAndTwoFrames() {
  var state = SpeechDetectionState()
  let atThreshold = amplitude(dbFS: AdaptiveMixing.speechThresholdDBFS)

  let firstFrame = state.update(
    fullBandRMS: atThreshold,
    voiceBandEnergy: voiceEnergy(
      fullBandRMS: atThreshold,
      ratio: AdaptiveMixing.minimumVoiceBandEnergyRatio
    ),
    elapsed: 0.1
  )
  #expect(!firstFrame)
  #expect(state.consecutiveQualifyingFrames == 1)

  let secondFrame = state.update(
    fullBandRMS: atThreshold,
    voiceBandEnergy: voiceEnergy(
      fullBandRMS: atThreshold,
      ratio: AdaptiveMixing.minimumVoiceBandEnergyRatio
    ),
    elapsed: 0.1
  )
  #expect(secondFrame)
  #expect(state.consecutiveQualifyingFrames == 2)
}

@Test func speechDetectionRejectsQuietOrNonVoiceHeavyFrames() {
  var state = SpeechDetectionState()
  let quiet = amplitude(dbFS: AdaptiveMixing.speechThresholdDBFS - 0.1)
  let loud = amplitude(dbFS: AdaptiveMixing.speechThresholdDBFS + 6)

  for _ in 0..<3 {
    let detected = state.update(
      fullBandRMS: quiet,
      voiceBandEnergy: voiceEnergy(fullBandRMS: quiet, ratio: 0.9),
      elapsed: 0.1
    )
    #expect(!detected)
  }

  for _ in 0..<3 {
    let detected = state.update(
      fullBandRMS: loud,
      voiceBandEnergy: voiceEnergy(
        fullBandRMS: loud,
        ratio: AdaptiveMixing.minimumVoiceBandEnergyRatio - 0.01
      ),
      elapsed: 0.1
    )
    #expect(!detected)
  }
}

@Test func speechDetectionHoldsForSixHundredMilliseconds() {
  var state = SpeechDetectionState()
  let rms = amplitude(dbFS: -30)
  let energy = voiceEnergy(fullBandRMS: rms, ratio: 0.8)
  _ = state.update(fullBandRMS: rms, voiceBandEnergy: energy, elapsed: 0.1)
  let activated = state.update(fullBandRMS: rms, voiceBandEnergy: energy, elapsed: 0.1)
  #expect(activated)

  let duringHang = state.update(fullBandRMS: 0, voiceBandEnergy: 0, elapsed: 0.599)
  #expect(duringHang)
  let afterHang = state.update(fullBandRMS: 0, voiceBandEnergy: 0, elapsed: 0.001)
  #expect(!afterHang)
  #expect(state.hangRemaining == 0)
}

@Test func speechDetectionTreatsInvalidAnalysisAsSilence() {
  var state = SpeechDetectionState()
  let rms = amplitude(dbFS: -30)
  let energy = voiceEnergy(fullBandRMS: rms, ratio: 0.8)
  _ = state.update(fullBandRMS: rms, voiceBandEnergy: energy, elapsed: 0.1)
  _ = state.update(fullBandRMS: rms, voiceBandEnergy: energy, elapsed: 0.1)

  let firstInvalidFrame = state.update(
    fullBandRMS: .nan,
    voiceBandEnergy: .infinity,
    elapsed: 0.3
  )
  #expect(firstInvalidFrame)
  let secondInvalidFrame = state.update(
    fullBandRMS: .nan,
    voiceBandEnergy: .infinity,
    elapsed: 0.3
  )
  #expect(!secondInvalidFrame)
}

// MARK: - Speech duck timing

@Test func speechDuckUsesOneHundredTwentyMillisecondAttack() {
  var state = SpeechDuckingState()

  let halfway = state.update(isSpeechActive: true, isEligible: true, elapsed: 0.06)
  #expect(abs(halfway - (-5)) < 1e-9)

  let target = state.update(isSpeechActive: true, isEligible: true, elapsed: 0.06)
  #expect(abs(target - AdaptiveMixing.speechDuckDB) < 1e-9)
}

@Test func speechDuckUsesNineHundredMillisecondRelease() {
  var state = SpeechDuckingState(currentGainDB: AdaptiveMixing.speechDuckDB)

  let halfway = state.update(isSpeechActive: false, isEligible: true, elapsed: 0.45)
  #expect(abs(halfway - (-5)) < 1e-9)

  let restored = state.update(isSpeechActive: false, isEligible: true, elapsed: 0.45)
  #expect(abs(restored) < 1e-9)
}

// MARK: - Loudness balancing

@Test func loudnessAverageUsesThreeSecondTimeConstant() {
  var state = LoudnessTrimState(averagedRMS: 0)
  _ = state.update(rms: 1, isEligible: true, elapsed: 3)

  let expected = 1 - exp(-1.0)
  #expect(abs((state.averagedRMS ?? -1) - expected) < 1e-9)
}

@Test func loudnessTargetIsMinusTwentyFourDBFS() {
  var state = LoudnessTrimState(averagedRMS: amplitude(dbFS: -24))
  let gain = state.update(rms: amplitude(dbFS: -24), isEligible: true, elapsed: 1)
  #expect(abs(gain) < 1e-9)
}

@Test func loudnessTrimHonorsLimitsAndCorrectionRates() {
  var loud = LoudnessTrimState(averagedRMS: amplitude(dbFS: 0))
  let initialReduction = loud.update(rms: 1, isEligible: true, elapsed: 2)
  #expect(abs(initialReduction - (-2)) < 1e-9)
  let limitedReduction = loud.update(rms: 1, isEligible: true, elapsed: 10)
  #expect(abs(limitedReduction - (-6)) < 1e-9)

  let quietRMS = amplitude(dbFS: -30)
  var quiet = LoudnessTrimState(averagedRMS: quietRMS)
  let initialIncrease = quiet.update(rms: quietRMS, isEligible: true, elapsed: 2)
  #expect(abs(initialIncrease - 1) < 1e-9)
  let limitedIncrease = quiet.update(rms: quietRMS, isEligible: true, elapsed: 10)
  #expect(abs(limitedIncrease - 3) < 1e-9)
}

@Test func loudnessBalanceDoesNotRaiseSilence() {
  var state = LoudnessTrimState(
    averagedRMS: amplitude(dbFS: -30),
    currentGainDB: 2
  )

  let quietGain = state.update(rms: amplitude(dbFS: -51), isEligible: true, elapsed: 1)
  #expect(abs(quietGain - 1) < 1e-9)
  let silentGain = state.update(rms: 0, isEligible: true, elapsed: 1)
  #expect(abs(silentGain) < 1e-9)
  #expect(state.currentGainDB == 0)
}

@Test func loudnessBalanceRestoresIgnoredSourcesAndClearsAverage() {
  var state = LoudnessTrimState(averagedRMS: 1, currentGainDB: -3)
  let restored = state.update(rms: 1, isEligible: false, elapsed: 2)

  #expect(restored == -2)
  #expect(state.averagedRMS == nil)
}

// MARK: - Roles and combined gain

@Test func adaptiveRolesResolveFromExplicitRoleOrCategory() {
  #expect(AdaptiveMixing.resolvedRole(.voice, category: .media) == .voice)
  #expect(AdaptiveMixing.resolvedRole(.media, category: .conferencing) == .media)
  #expect(AdaptiveMixing.resolvedRole(.ignore, category: .conferencing) == .ignore)
  #expect(AdaptiveMixing.resolvedRole(.auto, category: .conferencing) == .voice)
  #expect(AdaptiveMixing.resolvedRole(.auto, category: .media) == .media)
  #expect(AdaptiveMixing.resolvedRole(.auto, category: .browser) == .auto)
}

@Test func combinedGainAppliesOnlyLayersAllowedByModeAndRole() {
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .speechFocus,
      role: .media,
      category: .media,
      speechDuckDB: -10,
      loudnessTrimDB: 2
    ) == -10
  )
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .speechFocus,
      role: .voice,
      category: .conferencing,
      speechDuckDB: -10,
      loudnessTrimDB: 2
    ) == 0
  )
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .loudnessBalance,
      role: .auto,
      category: .browser,
      speechDuckDB: -10,
      loudnessTrimDB: 2
    ) == 2
  )
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .both,
      role: .media,
      category: .media,
      speechDuckDB: -10,
      loudnessTrimDB: 2
    ) == -8
  )
}

@Test func combinedGainClampsAndOffRestoresImmediately() {
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .both,
      role: .media,
      category: .media,
      speechDuckDB: -20,
      loudnessTrimDB: -6
    ) == -18
  )
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .loudnessBalance,
      role: .voice,
      category: .conferencing,
      speechDuckDB: 0,
      loudnessTrimDB: 8
    ) == 3
  )
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .off,
      role: .media,
      category: .media,
      speechDuckDB: -10,
      loudnessTrimDB: 3
    ) == 0
  )
  #expect(
    AdaptiveMixing.combinedGainDB(
      mode: .both,
      role: .ignore,
      category: .media,
      speechDuckDB: -10,
      loudnessTrimDB: 3
    ) == 0
  )
}

// MARK: - Voice-band analysis

@Test func voiceBandAnalyzerPrefersSpeechFrequencies() {
  let sampleRate = 48_000.0
  let frameCount = 48_000
  let speechTone = (0..<frameCount).map { frame in
    Float(0.25 * sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
  }
  let highTone = (0..<frameCount).map { frame in
    Float(0.25 * sin(2 * Double.pi * 10_000 * Double(frame) / sampleRate))
  }

  let speechAnalyzer = VoiceBandEnergyAnalyzer(sampleRate: sampleRate, channelCount: 1)
  let speechResult = speechTone.withUnsafeBytes { bytes in
    speechAnalyzer.analyze(
      bytes.baseAddress!,
      byteCount: bytes.count,
      format: .float32,
      bufferChannelCount: 1
    )
  }

  let highAnalyzer = VoiceBandEnergyAnalyzer(sampleRate: sampleRate, channelCount: 1)
  let highResult = highTone.withUnsafeBytes { bytes in
    highAnalyzer.analyze(
      bytes.baseAddress!,
      byteCount: bytes.count,
      format: .float32,
      bufferChannelCount: 1
    )
  }

  #expect(speechResult.sampleCount == UInt32(frameCount))
  #expect(highResult.sampleCount == UInt32(frameCount))
  #expect(speechResult.energySum > highResult.energySum * 4)
}

@Test func voiceBandAnalyzerRejectsUnsupportedBuffers() {
  let analyzer = VoiceBandEnergyAnalyzer(sampleRate: 48_000, channelCount: 1)
  let sample: Float = 0.25

  let result = withUnsafeBytes(of: sample) { bytes in
    analyzer.analyze(
      bytes.baseAddress!,
      byteCount: bytes.count,
      format: .unknown,
      bufferChannelCount: 1
    )
  }

  #expect(result.energySum == 0)
  #expect(result.sampleCount == 0)
}
