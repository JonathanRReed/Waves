import Foundation

/// Product constants and pure calculations shared by the adaptive coordinator.
public enum AdaptiveMixing {
  public static let speechThresholdDBFS = -42.0
  public static let minimumVoiceBandEnergyRatio = 0.55
  public static let speechActivationFrameCount = 2
  public static let speechHangDuration: TimeInterval = 0.6

  public static let speechDuckDB = -10.0
  public static let speechDuckAttackDuration: TimeInterval = 0.12
  public static let speechDuckReleaseDuration: TimeInterval = 0.9

  public static let loudnessAverageTimeConstant: TimeInterval = 3
  public static let loudnessTargetDBFS = -24.0
  public static let loudnessSilenceFloorDBFS = -50.0
  public static let minimumLoudnessTrimDB = -6.0
  public static let maximumLoudnessTrimDB = 3.0
  public static let downwardCorrectionDBPerSecond = 1.0
  public static let upwardCorrectionDBPerSecond = 0.5

  public static let minimumCombinedGainDB = -18.0
  public static let maximumCombinedGainDB = 3.0

  /// Converts a linear RMS amplitude to dBFS. Invalid or silent input is silence.
  public static func decibels(forAmplitude amplitude: Double) -> Double {
    guard amplitude.isFinite, amplitude > 0 else { return -.infinity }
    return 20 * log10(amplitude)
  }

  /// Returns voice-band energy as a fraction of full-band mean-square energy.
  public static func voiceBandEnergyRatio(
    fullBandRMS: Double,
    voiceBandEnergy: Double
  ) -> Double {
    guard
      fullBandRMS.isFinite,
      voiceBandEnergy.isFinite,
      fullBandRMS > 0,
      voiceBandEnergy >= 0
    else {
      return 0
    }

    let fullBandEnergy = fullBandRMS * fullBandRMS
    guard fullBandEnergy.isFinite, fullBandEnergy > 0 else { return 0 }
    return voiceBandEnergy / fullBandEnergy
  }

  /// Resolves automatic roles without guessing for neutral app categories.
  public static func resolvedRole(
    _ configuredRole: AdaptiveAppRole,
    category: AppCategory
  ) -> AdaptiveAppRole {
    guard configuredRole == .auto else { return configuredRole }

    switch category {
    case .conferencing:
      return .voice
    case .media:
      return .media
    case .browser, .communication, .system, .unknown:
      return .auto
    }
  }

  public static func isSpeechDuckEligible(
    role: AdaptiveAppRole,
    category: AppCategory
  ) -> Bool {
    resolvedRole(role, category: category) == .media
  }

  public static func isLoudnessBalanceEligible(
    role: AdaptiveAppRole,
    category: AppCategory
  ) -> Bool {
    resolvedRole(role, category: category) != .ignore
  }

  /// Combines the enabled temporary gain layers without changing manual gain.
  public static func combinedGainDB(
    mode: AdaptiveMixMode,
    role: AdaptiveAppRole,
    category: AppCategory,
    speechDuckDB: Double,
    loudnessTrimDB: Double
  ) -> Double {
    guard mode != .off else { return 0 }

    let resolved = resolvedRole(role, category: category)
    guard resolved != .ignore else { return 0 }

    let safeDuck = speechDuckDB.isFinite ? speechDuckDB : 0
    let safeTrim = loudnessTrimDB.isFinite ? loudnessTrimDB : 0
    let gain: Double

    switch mode {
    case .off:
      return 0
    case .speechFocus:
      gain = resolved == .media ? safeDuck : 0
    case .loudnessBalance:
      gain = safeTrim
    case .both:
      gain = safeTrim + (resolved == .media ? safeDuck : 0)
    }

    return min(maximumCombinedGainDB, max(minimumCombinedGainDB, gain))
  }

  static func elapsedDuration(_ elapsed: TimeInterval) -> TimeInterval {
    guard elapsed.isFinite, elapsed > 0 else { return 0 }
    return elapsed
  }

  static func move(
    _ value: Double,
    toward target: Double,
    maximumChange: Double
  ) -> Double {
    let change = max(0, maximumChange)
    if target < value {
      return max(target, value - change)
    }
    if target > value {
      return min(target, value + change)
    }
    return value
  }
}

/// Deterministic speech threshold, activation, and hang state.
public struct SpeechDetectionState: Hashable, Sendable {
  public private(set) var isSpeechActive: Bool
  public private(set) var consecutiveQualifyingFrames: Int
  public private(set) var hangRemaining: TimeInterval

  public init(
    isSpeechActive: Bool = false,
    consecutiveQualifyingFrames: Int = 0,
    hangRemaining: TimeInterval = 0
  ) {
    self.isSpeechActive = isSpeechActive
    self.consecutiveQualifyingFrames = max(0, consecutiveQualifyingFrames)
    self.hangRemaining = max(0, hangRemaining.isFinite ? hangRemaining : 0)
  }

  /// Evaluates one analysis frame. `voiceBandEnergy` is mean-square energy.
  @discardableResult
  public mutating func update(
    fullBandRMS: Double,
    voiceBandEnergy: Double,
    elapsed: TimeInterval
  ) -> Bool {
    let thresholdRMS = pow(10, AdaptiveMixing.speechThresholdDBFS / 20)
    let voiceRatio = AdaptiveMixing.voiceBandEnergyRatio(
      fullBandRMS: fullBandRMS,
      voiceBandEnergy: voiceBandEnergy
    )
    let qualifies = fullBandRMS.isFinite
      && fullBandRMS >= thresholdRMS
      && voiceRatio >= AdaptiveMixing.minimumVoiceBandEnergyRatio

    if qualifies {
      consecutiveQualifyingFrames = min(
        AdaptiveMixing.speechActivationFrameCount,
        consecutiveQualifyingFrames + 1
      )

      if consecutiveQualifyingFrames >= AdaptiveMixing.speechActivationFrameCount {
        isSpeechActive = true
        hangRemaining = AdaptiveMixing.speechHangDuration
      }
      return isSpeechActive
    }

    consecutiveQualifyingFrames = 0
    guard isSpeechActive else {
      hangRemaining = 0
      return false
    }

    let duration = AdaptiveMixing.elapsedDuration(elapsed)
    hangRemaining = max(0, hangRemaining - duration)
    if hangRemaining <= 1e-9 {
      hangRemaining = 0
      isSpeechActive = false
    }
    return isSpeechActive
  }
}

/// Smooth attack and release state for the fixed speech duck.
public struct SpeechDuckingState: Hashable, Sendable {
  public private(set) var currentGainDB: Double

  public init(currentGainDB: Double = 0) {
    let safeGain = currentGainDB.isFinite ? currentGainDB : 0
    self.currentGainDB = min(0, max(AdaptiveMixing.speechDuckDB, safeGain))
  }

  @discardableResult
  public mutating func update(
    isSpeechActive: Bool,
    isEligible: Bool,
    elapsed: TimeInterval
  ) -> Double {
    let target = isSpeechActive && isEligible ? AdaptiveMixing.speechDuckDB : 0
    let duration = AdaptiveMixing.elapsedDuration(elapsed)

    if target < currentGainDB {
      let rate = abs(AdaptiveMixing.speechDuckDB)
        / AdaptiveMixing.speechDuckAttackDuration
      currentGainDB = AdaptiveMixing.move(
        currentGainDB,
        toward: target,
        maximumChange: rate * duration
      )
    } else {
      let rate = abs(AdaptiveMixing.speechDuckDB)
        / AdaptiveMixing.speechDuckReleaseDuration
      currentGainDB = AdaptiveMixing.move(
        currentGainDB,
        toward: target,
        maximumChange: rate * duration
      )
    }

    return currentGainDB
  }
}

/// Exponential RMS averaging and rate-limited loudness correction state.
public struct LoudnessTrimState: Hashable, Sendable {
  public private(set) var averagedRMS: Double?
  public private(set) var currentGainDB: Double

  public init(
    averagedRMS: Double? = nil,
    currentGainDB: Double = 0
  ) {
    if let averagedRMS, averagedRMS.isFinite, averagedRMS >= 0 {
      self.averagedRMS = averagedRMS
    } else {
      self.averagedRMS = nil
    }

    let safeGain = currentGainDB.isFinite ? currentGainDB : 0
    self.currentGainDB = min(
      AdaptiveMixing.maximumLoudnessTrimDB,
      max(AdaptiveMixing.minimumLoudnessTrimDB, safeGain)
    )
  }

  @discardableResult
  public mutating func update(
    rms: Double,
    isEligible: Bool,
    elapsed: TimeInterval
  ) -> Double {
    let duration = AdaptiveMixing.elapsedDuration(elapsed)
    let safeRMS = rms.isFinite ? max(0, rms) : 0

    if isEligible {
      if let averagedRMS {
        let alpha = 1 - exp(-duration / AdaptiveMixing.loudnessAverageTimeConstant)
        self.averagedRMS = averagedRMS + alpha * (safeRMS - averagedRMS)
      } else {
        averagedRMS = safeRMS
      }
    } else {
      averagedRMS = nil
    }

    let instantaneousDBFS = AdaptiveMixing.decibels(forAmplitude: safeRMS)
    let target: Double
    if !isEligible || instantaneousDBFS < AdaptiveMixing.loudnessSilenceFloorDBFS {
      target = 0
    } else {
      let averageDBFS = AdaptiveMixing.decibels(forAmplitude: averagedRMS ?? 0)
      let requested = AdaptiveMixing.loudnessTargetDBFS - averageDBFS
      target = min(
        AdaptiveMixing.maximumLoudnessTrimDB,
        max(AdaptiveMixing.minimumLoudnessTrimDB, requested)
      )
    }

    let rate = target < currentGainDB
      ? AdaptiveMixing.downwardCorrectionDBPerSecond
      : AdaptiveMixing.upwardCorrectionDBPerSecond
    currentGainDB = AdaptiveMixing.move(
      currentGainDB,
      toward: target,
      maximumChange: rate * duration
    )
    return currentGainDB
  }
}

/// Allocation-free two-pole voice-band energy analysis for tap buffers.
///
/// A first-order 200 Hz high-pass followed by a first-order 4 kHz low-pass
/// provides the stable energy ratio needed by the product heuristic without
/// retaining or exporting audio samples. Keep this object confined to the
/// owning audio controller's serial callback queue.
public final class VoiceBandEnergyAnalyzer {
  private struct ChannelState {
    var previousInput = 0.0
    var highPassOutput = 0.0
    var lowPassOutput = 0.0
  }

  public let sampleRate: Double
  public let channelCount: Int
  private let highPassAlpha: Double
  private let lowPassAlpha: Double
  private var states: [ChannelState]

  public init(sampleRate: Double, channelCount: Int) {
    self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
    self.channelCount = max(1, channelCount)
    let timeStep = 1 / self.sampleRate
    let highPassRC = 1 / (2 * Double.pi * 200)
    let lowPassRC = 1 / (2 * Double.pi * 4_000)
    self.highPassAlpha = highPassRC / (highPassRC + timeStep)
    self.lowPassAlpha = timeStep / (lowPassRC + timeStep)
    self.states = Array(repeating: ChannelState(), count: self.channelCount)
  }

  public func reset() {
    for index in states.indices {
      states[index] = ChannelState()
    }
  }

  public func analyze(
    _ data: UnsafeRawPointer,
    byteCount: Int,
    format: TapSampleFormat,
    bufferChannelCount: Int,
    channelOffset: Int = 0
  ) -> (energySum: Float, sampleCount: UInt32) {
    let localChannelCount = max(1, bufferChannelCount)
    guard byteCount > 0,
          channelOffset >= 0,
          channelOffset + localChannelCount <= channelCount else {
      return (0, 0)
    }

    switch format {
    case .float32:
      let pointer = data.assumingMemoryBound(to: Float.self)
      return analyzeSamples(
        count: byteCount / MemoryLayout<Float>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) }
      )
    case .int16:
      let pointer = data.assumingMemoryBound(to: Int16.self)
      let scale = Double(Int16.max)
      return analyzeSamples(
        count: byteCount / MemoryLayout<Int16>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) / scale }
      )
    case .int32:
      let pointer = data.assumingMemoryBound(to: Int32.self)
      let scale = Double(Int32.max)
      return analyzeSamples(
        count: byteCount / MemoryLayout<Int32>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) / scale }
      )
    case .unknown:
      return (0, 0)
    }
  }

  private func analyzeSamples(
    count: Int,
    bufferChannelCount: Int,
    channelOffset: Int,
    read: (Int) -> Double
  ) -> (energySum: Float, sampleCount: UInt32) {
    guard count >= bufferChannelCount else { return (0, 0) }
    let frameCount = count / bufferChannelCount
    var sum = 0.0
    var samples: UInt32 = 0

    for frame in 0..<frameCount {
      for localChannel in 0..<bufferChannelCount {
        let sampleIndex = frame * bufferChannelCount + localChannel
        let channel = channelOffset + localChannel
        let input = read(sampleIndex)
        let safeInput = input.isFinite ? input : 0
        var state = states[channel]
        let highPassed = highPassAlpha
          * (state.highPassOutput + safeInput - state.previousInput)
        let bandPassed = state.lowPassOutput + lowPassAlpha
          * (highPassed - state.lowPassOutput)
        state.previousInput = safeInput
        state.highPassOutput = highPassed
        state.lowPassOutput = bandPassed
        states[channel] = state
        sum += bandPassed * bandPassed
        samples &+= 1
      }
    }

    guard sum.isFinite else { return (0, samples) }
    return (Float(sum), samples)
  }
}
