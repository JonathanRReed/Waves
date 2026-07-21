import Foundation
import Testing

@testable import WavesAudioCore

@Test func equalizerCoefficientsAreFiniteForEveryBandAndGainLimit() {
  for band in EqualizerBandCatalog.simple + EqualizerBandCatalog.advanced {
    for gain in [EqualizerSettings.minimumGainDB, 0, EqualizerSettings.maximumGainDB] {
      let coefficients = EqualizerCoefficientFactory.coefficients(
        for: band,
        gainDB: gain,
        sampleRate: 48_000
      )
      #expect(coefficients.isFinite)
    }
  }
}

@Test func peakingFilterMovesCenterFrequencyInRequestedDirection() {
  let band = EqualizerBandCatalog.advanced[4]
  let boost = EqualizerCoefficientFactory.coefficients(for: band, gainDB: 6, sampleRate: 48_000)
  let cut = EqualizerCoefficientFactory.coefficients(for: band, gainDB: -6, sampleRate: 48_000)

  #expect(EqualizerCoefficientFactory.responseMagnitude(boost, frequency: band.frequency, sampleRate: 48_000) > 1.8)
  #expect(EqualizerCoefficientFactory.responseMagnitude(cut, frequency: band.frequency, sampleRate: 48_000) < 0.6)
}

@Test func peakingFilterProcessesCenterFrequencyAtRequestedGain() {
  let sampleRate = 48_000.0
  let frequency = 1_000.0
  var settings = EqualizerSettings(isEnabled: true, mode: .advanced)
  settings.setGain(6, at: 4)
  let processor = EqualizerDSP(
    sampleRate: sampleRate,
    channelCount: 1,
    settings: settings
  )
  let input = (0..<48_000).map { frame in
    Float(0.01 * sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
  }
  var output = input

  output.withUnsafeMutableBytes { bytes in
    processor.process(
      bytes.baseAddress!,
      byteCount: bytes.count,
      format: .float32,
      bufferChannelCount: 1
    )
  }

  let settledInput = input.dropFirst(4_096)
  let settledOutput = output.dropFirst(4_096)
  let inputRMS = sqrt(
    settledInput.reduce(0.0) { $0 + Double($1 * $1) }
      / Double(settledInput.count)
  )
  let outputRMS = sqrt(
    settledOutput.reduce(0.0) { $0 + Double($1 * $1) }
      / Double(settledOutput.count)
  )
  let measuredGainDB = 20 * log10(outputRMS / inputRMS)

  #expect(abs(measuredGainDB - 6) < 0.05)
}

@Test func shelfFiltersFavorTheirNamedFrequencyRegion() {
  let low = EqualizerCoefficientFactory.coefficients(
    for: EqualizerBandCatalog.simple[0],
    gainDB: 6,
    sampleRate: 48_000
  )
  let high = EqualizerCoefficientFactory.coefficients(
    for: EqualizerBandCatalog.simple[2],
    gainDB: 6,
    sampleRate: 48_000
  )

  #expect(
    EqualizerCoefficientFactory.responseMagnitude(low, frequency: 50, sampleRate: 48_000)
      > EqualizerCoefficientFactory.responseMagnitude(low, frequency: 5_000, sampleRate: 48_000)
  )
  #expect(
    EqualizerCoefficientFactory.responseMagnitude(high, frequency: 10_000, sampleRate: 48_000)
      > EqualizerCoefficientFactory.responseMagnitude(high, frequency: 500, sampleRate: 48_000)
  )
}

@Test func disabledEqualizerLeavesFloatSamplesBitForBitUnchanged() {
  var samples: [Float] = [-0.75, -0.1, 0, 0.25, 0.8]
  let original = samples
  let processor = EqualizerDSP(sampleRate: 48_000, channelCount: 1)

  samples.withUnsafeMutableBytes { bytes in
    processor.process(bytes.baseAddress!, byteCount: bytes.count, format: .float32, bufferChannelCount: 1)
  }

  #expect(samples == original)
}

@Test func equalizerMaintainsFilterStateAcrossBuffers() {
  var settings = EqualizerSettings(isEnabled: true, mode: .simple)
  settings.applyPreset(.voiceFocus)
  let samples = (0..<512).map { index in
    Float(sin(2 * Double.pi * 1_500 * Double(index) / 48_000) * 0.2)
  }
  var oneBuffer = samples
  var splitA = Array(samples[..<256])
  var splitB = Array(samples[256...])
  let continuous = EqualizerDSP(sampleRate: 48_000, channelCount: 1, settings: settings)
  let split = EqualizerDSP(sampleRate: 48_000, channelCount: 1, settings: settings)

  oneBuffer.withUnsafeMutableBytes { bytes in
    continuous.process(bytes.baseAddress!, byteCount: bytes.count, format: .float32, bufferChannelCount: 1)
  }
  splitA.withUnsafeMutableBytes { bytes in
    split.process(bytes.baseAddress!, byteCount: bytes.count, format: .float32, bufferChannelCount: 1)
  }
  splitB.withUnsafeMutableBytes { bytes in
    split.process(bytes.baseAddress!, byteCount: bytes.count, format: .float32, bufferChannelCount: 1)
  }

  let joined = splitA + splitB
  for index in oneBuffer.indices {
    #expect(abs(oneBuffer[index] - joined[index]) < 0.000_001)
  }
}

@Test func coefficientSmoothingKeepsOutputFinite() {
  let processor = EqualizerDSP(sampleRate: 48_000, channelCount: 2)
  var settings = EqualizerSettings(isEnabled: true, mode: .advanced)
  settings.applyPreset(.voiceFocus)
  processor.update(settings: settings)
  var samples = Array(repeating: Float(0.9), count: 4_096)

  samples.withUnsafeMutableBytes { bytes in
    processor.process(bytes.baseAddress!, byteCount: bytes.count, format: .float32, bufferChannelCount: 2)
  }

  let allFinite = samples.allSatisfy(\.isFinite)
  let allInRange = samples.allSatisfy { (-1...1).contains($0) }
  #expect(allFinite)
  #expect(allInRange)
}

@Test func equalizerSupportsIntegerTapFormats() {
  var int16Samples: [Int16] = [Int16.min, -10_000, 0, 10_000, Int16.max]
  var int32Samples: [Int32] = [Int32.min, -1_000_000, 0, 1_000_000, Int32.max]
  var settings = EqualizerSettings(isEnabled: true)
  settings.applyPreset(.warm)
  let int16Processor = EqualizerDSP(sampleRate: 48_000, channelCount: 1, settings: settings)
  let int32Processor = EqualizerDSP(sampleRate: 48_000, channelCount: 1, settings: settings)

  int16Samples.withUnsafeMutableBytes { bytes in
    int16Processor.process(bytes.baseAddress!, byteCount: bytes.count, format: .int16, bufferChannelCount: 1)
  }
  int32Samples.withUnsafeMutableBytes { bytes in
    int32Processor.process(bytes.baseAddress!, byteCount: bytes.count, format: .int32, bufferChannelCount: 1)
  }

  #expect(int16Samples.contains { $0 != 0 })
  #expect(int32Samples.contains { $0 != 0 })
}
