import Foundation
import Testing

@testable import WavesAudioCore

private func processManagedEqualizers(
  _ samples: inout [Float],
  perApp: EqualizerSettings,
  managedAudio: GlobalEqualizerSettings
) {
  let perAppDSP = EqualizerDSP(
    sampleRate: 48_000,
    channelCount: 1,
    settings: perApp
  )
  let managedDSP = EqualizerDSP(
    sampleRate: 48_000,
    channelCount: 1,
    settings: managedAudio.equalizerSettings
  )
  samples.withUnsafeMutableBytes { bytes in
    let pointer = bytes.baseAddress!
    TapDSP.scale(
      pointer,
      byteCount: bytes.count,
      format: .float32,
      gain: GlobalEqualizerSettings.combinedHeadroomGain(
        perApp: perApp,
        managedAudio: managedAudio
      )
    )
    perAppDSP.process(
      pointer,
      byteCount: bytes.count,
      format: .float32,
      bufferChannelCount: 1
    )
    managedDSP.process(
      pointer,
      byteCount: bytes.count,
      format: .float32,
      bufferChannelCount: 1
    )
  }
}

@Test func bypassedManagedAndPerAppEqualizersAreBitForBitNeutral() {
  var samples: [Float] = [-0.75, -0.1, 0, 0.25, 0.8]
  let original = samples

  processManagedEqualizers(
    &samples,
    perApp: EqualizerSettings(),
    managedAudio: GlobalEqualizerSettings()
  )

  #expect(samples == original)
}

@Test func stackedEqualizerHeadroomPreventsFullScaleCallbackClipping() {
  var perApp = EqualizerSettings(isEnabled: true, mode: .advanced)
  perApp.setGain(12, at: 5)
  var managed = GlobalEqualizerSettings(isEnabled: true, mode: .advanced)
  managed.setGain(12, at: 5)

  var samples = (0..<24_000).map { frame in
    Float(0.9 * sin(2 * Double.pi * 2_000 * Double(frame) / 48_000))
  }
  processManagedEqualizers(
    &samples,
    perApp: perApp,
    managedAudio: managed
  )

  #expect(samples.allSatisfy { $0.isFinite })
  #expect(samples.allSatisfy { abs($0) < 0.999 })
}
