import Foundation
import WavesAudioCore
import WavesRealtimeSupport

struct TapRenderState: Sendable {
  var volume: Float
  var volumeBoost: Float
  var isMuted: UInt32
  var isActive: UInt32
  var peakLevel: Float
  var rmsLevel: Float
  var analysisRMS: Float
  var voiceBandEnergy: Float
  var renderTick: UInt64
}

/// Callback-shared render state. The backing C11 atomics are allocated during
/// controller setup and are the callback's only shared state. The callback
/// never locks, tries a lock, allocates, logs, or hops into actor work.
final class TapRenderStateBox: @unchecked Sendable {
  private let state: OpaquePointer

  init(initialState: TapRenderState) {
    guard
      let state = WavesAtomicTapRenderStateCreate(
        initialState.volume,
        initialState.volumeBoost,
        initialState.isMuted,
        initialState.isActive,
        initialState.peakLevel,
        initialState.rmsLevel,
        initialState.analysisRMS,
        initialState.voiceBandEnergy,
        initialState.renderTick
      )
    else {
      fatalError("Could not allocate callback render state.")
    }
    self.state = state
  }

  deinit {
    WavesAtomicTapRenderStateDestroy(state)
  }

  func read() -> TapRenderState {
    var volume: Float = 0
    var volumeBoost: Float = 0
    var isMuted: UInt32 = 0
    var isActive: UInt32 = 0
    var peakLevel: Float = 0
    var rmsLevel: Float = 0
    var analysisRMS: Float = 0
    var voiceBandEnergy: Float = 0
    var renderTick: UInt64 = 0
    WavesAtomicTapRenderStateLoad(
      state,
      &volume,
      &volumeBoost,
      &isMuted,
      &isActive,
      &peakLevel,
      &rmsLevel,
      &analysisRMS,
      &voiceBandEnergy,
      &renderTick
    )
    return TapRenderState(
      volume: volume,
      volumeBoost: volumeBoost,
      isMuted: isMuted,
      isActive: isActive,
      peakLevel: peakLevel,
      rmsLevel: rmsLevel,
      analysisRMS: analysisRMS,
      voiceBandEnergy: voiceBandEnergy,
      renderTick: renderTick
    )
  }

  func writeVolumeAndMute(volume: Float, volumeBoost: Float, muted: Bool) {
    WavesAtomicTapRenderStateStoreControls(state, volume, volumeBoost, muted ? 1 : 0)
  }

  func writeLevels(
    peakLevel: Float,
    rmsLevel: Float,
    analysisRMS: Float,
    voiceBandEnergy: Float
  ) {
    WavesAtomicTapRenderStateStoreLevels(
      state,
      peakLevel,
      rmsLevel,
      analysisRMS,
      voiceBandEnergy
    )
  }

  func readLevels() -> (peak: Float, rms: Float) {
    let current = read()
    return (current.peakLevel, current.rmsLevel)
  }

  func readAdaptiveAnalysis() -> AdaptiveAnalysisLevels {
    let current = read()
    return AdaptiveAnalysisLevels(rms: current.analysisRMS, voiceBandEnergy: current.voiceBandEnergy)
  }

  func markRenderTick() {
    WavesAtomicTapRenderStateMarkRenderTick(state)
  }

  func readRenderTick() -> UInt64 {
    WavesAtomicTapRenderStateReadRenderTick(state)
  }

  func flagGeometryMismatch() {
    WavesAtomicTapRenderStateFlagGeometryMismatch(state)
  }

  func consumeGeometryMismatch() -> Bool {
    WavesAtomicTapRenderStateConsumeGeometryMismatch(state)
  }

  func setInactive() {
    WavesAtomicTapRenderStateSetInactive(state)
  }
}
