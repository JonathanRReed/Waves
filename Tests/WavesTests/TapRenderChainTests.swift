import AudioToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

// These drive the tap's real render callback (`renderForTesting`) with
// interleaved stereo float32 buffers; the testing controller is 48 kHz stereo.

private func render(_ controller: PerAppTapController, _ input: [Float]) -> [Float] {
  var input = input
  var output = [Float](repeating: .nan, count: input.count)
  input.withUnsafeMutableBytes { inputBytes in
    output.withUnsafeMutableBytes { outputBytes in
      var inputList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 2,
          mDataByteSize: UInt32(inputBytes.count),
          mData: inputBytes.baseAddress
        )
      )
      var outputList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 2,
          mDataByteSize: UInt32(outputBytes.count),
          mData: outputBytes.baseAddress
        )
      )
      controller.renderForTesting(input: &inputList, output: &outputList)
    }
  }
  return output
}

private func constant(_ value: Float, frames: Int) -> [Float] {
  [Float](repeating: value, count: frames * 2)
}

private func makeController() throws -> PerAppTapController {
  try PerAppTapController.testingController(appID: "test.render-chain")
}

@Test func unityRenderLeavesFiniteSamplesBitForBitUnchangedAfterARampSettles() throws {
  let controller = try makeController()
  controller.apply(volume: 0.5, volumeBoost: 1, muted: false)
  _ = render(controller, constant(0.5, frames: 64))
  controller.apply(volume: 1, volumeBoost: 1, muted: false)
  _ = render(controller, constant(0.5, frames: 64))

  let input: [Float] = [
    0.5, -0.25, 1.5, -2.0, .leastNonzeroMagnitude, -0.0, 1e-30, 0.999_999,
    .nan, .infinity, -.infinity, 0.123_456_7,
  ]
  let output = render(controller, input)

  for (index, sample) in input.enumerated() {
    if sample.isFinite {
      #expect(output[index].bitPattern == sample.bitPattern, "sample \(index)")
    } else {
      #expect(output[index] == 0, "non-finite sample \(index) must become silence")
    }
  }
}

@Test func volumeChangeRampsAcrossTheBufferInsteadOfStepping() throws {
  let controller = try makeController()
  _ = render(controller, constant(0.5, frames: 64))
  controller.apply(volume: 0.5, volumeBoost: 1, muted: false)

  let output = render(controller, constant(0.5, frames: 256))

  // A step would put the first frame at 0.25. The ramp starts next to the old
  // level and lands exactly on the new one.
  #expect(output[0] > 0.49)
  #expect(output[0] == output[1])
  #expect(output[output.count - 1] == 0.25)
  for frame in 1..<256 {
    let step = output[(frame - 1) * 2] - output[frame * 2]
    #expect(step >= 0 && step < 0.001)
  }
  // Settled: the next buffer is flat at the new level.
  #expect(render(controller, constant(0.5, frames: 64)).allSatisfy { $0 == 0.25 })
}

@Test func gainRampsNeverOvershootTheUsersLevels() throws {
  let controller = try makeController()
  controller.apply(volume: 0.3, volumeBoost: 1, muted: false)
  _ = render(controller, constant(1, frames: 64))
  controller.apply(volume: 0.9, volumeBoost: 1, muted: false)
  controller.setAdaptiveGainDB(-6)

  let up = render(controller, constant(1, frames: 333))
  #expect(up.allSatisfy { $0 >= 0.3 - 1e-6 && $0 <= 0.9 + 1e-6 })

  controller.apply(volume: 0.2, volumeBoost: 1, muted: false)
  let down = render(controller, constant(1, frames: 333))
  #expect(down.allSatisfy { $0 >= 0.2 * 0.501 - 1e-6 && $0 <= 0.9 * 0.502 + 1e-6 })
}

@Test func muteFadesOutOverAboutFiveMillisecondsThenGoesExactlySilent() throws {
  let controller = try makeController()
  _ = render(controller, constant(0.5, frames: 64))
  controller.apply(volume: 1, volumeBoost: 1, muted: true)

  // 5 ms at 48 kHz is 240 frames: four 64-frame buffers.
  var fade: [Float] = []
  for _ in 0..<4 {
    fade += render(controller, constant(0.5, frames: 64)).enumerated()
      .filter { $0.offset.isMultiple(of: 2) }.map(\.element)
  }
  #expect(fade[0] > 0.49)
  #expect(fade[63] > 0.3)
  #expect(fade[200] > 0)
  #expect(fade.last == 0)
  for frame in 1..<fade.count {
    let step = fade[frame - 1] - fade[frame]
    #expect(step >= 0 && step < 0.005)
  }
  let silent = render(controller, constant(0.5, frames: 64))
  #expect(silent.allSatisfy { $0.bitPattern == Float(0).bitPattern })
  #expect(controller.getCurrentLevels() == (peak: 0, rms: 0))

  controller.apply(volume: 1, volumeBoost: 1, muted: false)
  let unmute = render(controller, constant(0.5, frames: 64))
  #expect(unmute[0] < 0.01)
  #expect(unmute[unmute.count - 1] < 0.5)
}

@Test func volumeBoostAndAdaptiveGainCombineBeforeTheSafetyClamp() throws {
  let controller = try makeController()
  controller.apply(volume: 0.8, volumeBoost: 4, muted: false)
  controller.setAdaptiveGainDB(-12)
  _ = render(controller, constant(0.5, frames: 64))

  let output = render(controller, constant(0.5, frames: 64))

  // 0.5 x 0.8 x 4 x 0.251 = 0.402. Clipping at 1.0 before the adaptive gain
  // used to produce 0.251.
  let expected = Float(0.5 * 0.8 * 4 * pow(10, -12.0 / 20))
  #expect(output.allSatisfy { abs($0 - expected) < 1e-5 })
}

@Test func finalStageStillClampsBoostedOutputToFullScale() throws {
  let controller = try makeController()
  controller.apply(volume: 1, volumeBoost: 4, muted: false)
  _ = render(controller, constant(0.5, frames: 64))

  let output = render(controller, [0.5, -0.5, 0.1, -0.9])

  #expect(output == [1, -1, 0.4, -1])
}

@Test func nonFiniteAdaptiveGainKeepsTheUsersLevel() throws {
  let controller = try makeController()
  controller.apply(volume: 0.5, volumeBoost: 1, muted: false)
  controller.setAdaptiveGainDB(.nan)
  _ = render(controller, constant(0.5, frames: 64))

  #expect(render(controller, constant(0.5, frames: 64)).allSatisfy { $0 == 0.25 })
}

@Test func adaptiveAnalysisIsMeasuredBeforeTheFaderAndTheMeterAfterIt() throws {
  let controller = try makeController()
  controller.apply(volume: 0.25, volumeBoost: 1, muted: false)
  _ = render(controller, constant(0.5, frames: 64))
  _ = render(controller, constant(0.5, frames: 64))

  let analysis = controller.getAdaptiveAnalysis()
  let meter = controller.getCurrentLevels()

  #expect(abs(analysis.rms - 0.5) < 1e-5)
  #expect(abs(meter.rms - 0.125) < 1e-5)
  #expect(abs(meter.peak - 0.125) < 1e-5)
}

@Test func silencedAppsReportNoAdaptiveAnalysisWhileFading() throws {
  let controller = try makeController()
  _ = render(controller, constant(0.5, frames: 64))
  controller.apply(volume: 0, volumeBoost: 1, muted: false)
  let fading = render(controller, constant(0.5, frames: 64))

  #expect(fading[0] > 0)
  #expect(controller.getAdaptiveAnalysis().rms == 0)

  // Raising the volume while muting must not let sound through the fade.
  controller.apply(volume: 1, volumeBoost: 1, muted: true)
  #expect(render(controller, constant(0.5, frames: 64)).allSatisfy { $0 == 0 })
  #expect(controller.getAdaptiveAnalysis().rms == 0)
}
