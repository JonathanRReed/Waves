import Foundation

public struct BiquadCoefficients: Hashable, Sendable {
  public var b0: Double
  public var b1: Double
  public var b2: Double
  public var a1: Double
  public var a2: Double

  public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
    self.b0 = b0
    self.b1 = b1
    self.b2 = b2
    self.a1 = a1
    self.a2 = a2
  }

  public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

  public var isFinite: Bool {
    b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
  }

  fileprivate func moved(toward target: BiquadCoefficients, remainingSteps: Int) -> BiquadCoefficients {
    guard remainingSteps > 0 else { return target }
    let divisor = Double(remainingSteps)
    return BiquadCoefficients(
      b0: b0 + (target.b0 - b0) / divisor,
      b1: b1 + (target.b1 - b1) / divisor,
      b2: b2 + (target.b2 - b2) / divisor,
      a1: a1 + (target.a1 - a1) / divisor,
      a2: a2 + (target.a2 - a2) / divisor
    )
  }
}

public enum EqualizerCoefficientFactory {
  public static func coefficients(
    for band: EqualizerBandDefinition,
    gainDB: Float,
    sampleRate: Double
  ) -> BiquadCoefficients {
    guard sampleRate.isFinite, sampleRate > 0, gainDB.isFinite else { return .identity }
    let nyquist = sampleRate / 2
    let frequency = min(max(10, band.frequency), nyquist * 0.98)
    let q = max(0.1, band.q)
    let amplitude = pow(10, Double(gainDB) / 40)
    let omega = 2 * Double.pi * frequency / sampleRate
    let sine = sin(omega)
    let cosine = cos(omega)
    let alpha = sine / (2 * q)

    let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)
    switch band.filterKind {
    case .peaking:
      raw = (
        1 + alpha * amplitude,
        -2 * cosine,
        1 - alpha * amplitude,
        1 + alpha / amplitude,
        -2 * cosine,
        1 - alpha / amplitude
      )

    case .lowShelf:
      let shelfAlpha = sine / 2 * sqrt(2)
      let rootTerm = 2 * sqrt(amplitude) * shelfAlpha
      raw = (
        amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + rootTerm),
        2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine),
        amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - rootTerm),
        (amplitude + 1) + (amplitude - 1) * cosine + rootTerm,
        -2 * ((amplitude - 1) + (amplitude + 1) * cosine),
        (amplitude + 1) + (amplitude - 1) * cosine - rootTerm
      )

    case .highShelf:
      let shelfAlpha = sine / 2 * sqrt(2)
      let rootTerm = 2 * sqrt(amplitude) * shelfAlpha
      raw = (
        amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + rootTerm),
        -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine),
        amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - rootTerm),
        (amplitude + 1) - (amplitude - 1) * cosine + rootTerm,
        2 * ((amplitude - 1) - (amplitude + 1) * cosine),
        (amplitude + 1) - (amplitude - 1) * cosine - rootTerm
      )
    }

    guard raw.a0.isFinite, abs(raw.a0) > .ulpOfOne else { return .identity }
    let normalized = BiquadCoefficients(
      b0: raw.b0 / raw.a0,
      b1: raw.b1 / raw.a0,
      b2: raw.b2 / raw.a0,
      a1: raw.a1 / raw.a0,
      a2: raw.a2 / raw.a0
    )
    return normalized.isFinite ? normalized : .identity
  }

  public static func responseMagnitude(
    _ coefficients: BiquadCoefficients,
    frequency: Double,
    sampleRate: Double
  ) -> Double {
    guard sampleRate > 0, frequency >= 0 else { return 0 }
    let omega = 2 * Double.pi * frequency / sampleRate
    let z1Real = cos(omega)
    let z1Imaginary = -sin(omega)
    let z2Real = cos(2 * omega)
    let z2Imaginary = -sin(2 * omega)

    let numeratorReal = coefficients.b0 + coefficients.b1 * z1Real + coefficients.b2 * z2Real
    let numeratorImaginary = coefficients.b1 * z1Imaginary + coefficients.b2 * z2Imaginary
    let denominatorReal = 1 + coefficients.a1 * z1Real + coefficients.a2 * z2Real
    let denominatorImaginary = coefficients.a1 * z1Imaginary + coefficients.a2 * z2Imaginary
    let numerator = hypot(numeratorReal, numeratorImaginary)
    let denominator = hypot(denominatorReal, denominatorImaginary)
    guard denominator > .ulpOfOne else { return 0 }
    let value = numerator / denominator
    return value.isFinite ? value : 0
  }
}

private struct BiquadDelayState {
  var x1: Double = 0
  var x2: Double = 0
  var y1: Double = 0
  var y2: Double = 0
}

/// Stateful, allocation-free render processor after initialization.
///
/// Create and update this object on the controller's serial callback queue.
/// `process` performs no allocation or locking. Channel state remains separate
/// for interleaved and non-interleaved tap buffers.
public final class EqualizerDSP {
  private static let maximumSections = EqualizerBandCatalog.advanced.count

  public let sampleRate: Double
  public let channelCount: Int
  private let smoothingFrames: Int
  private var targetCoefficients: [BiquadCoefficients]
  private var channelCoefficients: [BiquadCoefficients]
  private var delayStates: [BiquadDelayState]
  private var remainingFrames: [Int]
  private var processingSectionCount: Int
  private var targetSectionCount: Int

  public init(
    sampleRate: Double,
    channelCount: Int,
    settings: EqualizerSettings = EqualizerSettings(),
    smoothingDuration: Double = 0.02
  ) {
    self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
    self.channelCount = max(1, channelCount)
    self.smoothingFrames = max(1, Int(self.sampleRate * max(0, smoothingDuration)))
    self.targetCoefficients = Array(repeating: .identity, count: Self.maximumSections)
    self.channelCoefficients = Array(
      repeating: .identity,
      count: Self.maximumSections * self.channelCount
    )
    self.delayStates = Array(
      repeating: BiquadDelayState(),
      count: Self.maximumSections * self.channelCount
    )
    self.remainingFrames = Array(repeating: 0, count: self.channelCount)
    self.processingSectionCount = 0
    self.targetSectionCount = 0
    configure(settings, smooth: false)
  }

  public var isBypassed: Bool {
    processingSectionCount == 0 && remainingFrames.allSatisfy { $0 == 0 }
  }

  public func update(settings: EqualizerSettings) {
    configure(settings, smooth: true)
  }

  public func resetState() {
    for index in delayStates.indices {
      delayStates[index] = BiquadDelayState()
    }
  }

  public func process(
    _ data: UnsafeMutableRawPointer,
    byteCount: Int,
    format: TapSampleFormat,
    bufferChannelCount: Int,
    channelOffset: Int = 0
  ) {
    let localChannelCount = max(1, bufferChannelCount)
    guard byteCount > 0,
          channelOffset >= 0,
          channelOffset + localChannelCount <= channelCount,
          !isBypassed else { return }

    switch format {
    case .float32:
      let pointer = data.assumingMemoryBound(to: Float.self)
      processSamples(
        count: byteCount / MemoryLayout<Float>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) },
        write: { pointer[$0] = Float(max(-1, min(1, $1))) }
      )
    case .int16:
      let pointer = data.assumingMemoryBound(to: Int16.self)
      let scale = Double(Int16.max)
      processSamples(
        count: byteCount / MemoryLayout<Int16>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) / scale },
        write: { pointer[$0] = Int16((max(-1, min(1, $1)) * scale).rounded()) }
      )
    case .int32:
      let pointer = data.assumingMemoryBound(to: Int32.self)
      let scale = Double(Int32.max)
      processSamples(
        count: byteCount / MemoryLayout<Int32>.size,
        bufferChannelCount: localChannelCount,
        channelOffset: channelOffset,
        read: { Double(pointer[$0]) / scale },
        write: { pointer[$0] = Int32((max(-1, min(1, $1)) * scale).rounded()) }
      )
    case .unknown:
      return
    }
  }

  private func configure(_ settings: EqualizerSettings, smooth: Bool) {
    let bands = settings.isEnabled ? EqualizerBandCatalog.bands(for: settings.mode) : []
    let gains = settings.isEnabled ? settings.gains(for: settings.mode) : []
    targetSectionCount = bands.count

    for section in 0..<Self.maximumSections {
      if section < bands.count, section < gains.count {
        targetCoefficients[section] = EqualizerCoefficientFactory.coefficients(
          for: bands[section],
          gainDB: gains[section],
          sampleRate: sampleRate
        )
      } else {
        targetCoefficients[section] = .identity
      }
    }

    if smooth {
      processingSectionCount = max(processingSectionCount, targetSectionCount)
      for channel in remainingFrames.indices {
        remainingFrames[channel] = smoothingFrames
      }
    } else {
      processingSectionCount = targetSectionCount
      for channel in 0..<channelCount {
        for section in 0..<Self.maximumSections {
          channelCoefficients[stateIndex(section: section, channel: channel)] = targetCoefficients[section]
        }
      }
    }
  }

  private func processSamples(
    count: Int,
    bufferChannelCount: Int,
    channelOffset: Int,
    read: (Int) -> Double,
    write: (Int, Double) -> Void
  ) {
    guard count >= bufferChannelCount else { return }
    let frameCount = count / bufferChannelCount
    for frame in 0..<frameCount {
      for localChannel in 0..<bufferChannelCount {
        let sampleIndex = frame * bufferChannelCount + localChannel
        let channel = channelOffset + localChannel
        advanceCoefficients(for: channel)
        var sample = read(sampleIndex)
        if !sample.isFinite { sample = 0 }

        for section in 0..<processingSectionCount {
          let index = stateIndex(section: section, channel: channel)
          let coefficients = channelCoefficients[index]
          var delay = delayStates[index]
          let output = coefficients.b0 * sample
            + coefficients.b1 * delay.x1
            + coefficients.b2 * delay.x2
            - coefficients.a1 * delay.y1
            - coefficients.a2 * delay.y2

          delay.x2 = delay.x1
          delay.x1 = sample
          delay.y2 = delay.y1
          delay.y1 = output.isFinite ? output : 0
          delayStates[index] = delay
          sample = delay.y1
        }

        write(sampleIndex, sample)
      }
    }

    if remainingFrames.allSatisfy({ $0 == 0 }) {
      processingSectionCount = targetSectionCount
    }
  }

  private func advanceCoefficients(for channel: Int) {
    let remaining = remainingFrames[channel]
    guard remaining > 0 else { return }
    for section in 0..<processingSectionCount {
      let index = stateIndex(section: section, channel: channel)
      channelCoefficients[index] = channelCoefficients[index].moved(
        toward: targetCoefficients[section],
        remainingSteps: remaining
      )
    }
    remainingFrames[channel] = remaining - 1
  }

  private func stateIndex(section: Int, channel: Int) -> Int {
    section * channelCount + channel
  }
}
