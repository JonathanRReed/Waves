import Foundation

/// Platform-neutral fields needed to validate a native linear-PCM stream description.
///
/// The app target converts `AudioStreamBasicDescription` flags into this value so
/// validation remains hardware-independent and directly unit testable.
public struct LinearPCMFormatDescription: Hashable, Sendable {
  public let sampleRate: Double
  public let isLinearPCM: Bool
  public let isFloat: Bool
  public let isSignedInteger: Bool
  public let isPacked: Bool
  public let isAlignedHigh: Bool
  public let isNativeEndian: Bool
  public let isNonInterleaved: Bool
  public let hasUnsupportedFormatFlags: Bool
  public let hasValidReservedField: Bool
  public let bitsPerChannel: Int
  public let bytesPerFrame: Int
  public let channelsPerFrame: Int
  public let framesPerPacket: Int
  public let bytesPerPacket: Int

  public init(
    sampleRate: Double,
    isLinearPCM: Bool,
    isFloat: Bool,
    isSignedInteger: Bool,
    isPacked: Bool,
    isAlignedHigh: Bool,
    isNativeEndian: Bool,
    isNonInterleaved: Bool,
    hasUnsupportedFormatFlags: Bool,
    hasValidReservedField: Bool,
    bitsPerChannel: Int,
    bytesPerFrame: Int,
    channelsPerFrame: Int,
    framesPerPacket: Int,
    bytesPerPacket: Int
  ) {
    self.sampleRate = sampleRate
    self.isLinearPCM = isLinearPCM
    self.isFloat = isFloat
    self.isSignedInteger = isSignedInteger
    self.isPacked = isPacked
    self.isAlignedHigh = isAlignedHigh
    self.isNativeEndian = isNativeEndian
    self.isNonInterleaved = isNonInterleaved
    self.hasUnsupportedFormatFlags = hasUnsupportedFormatFlags
    self.hasValidReservedField = hasValidReservedField
    self.bitsPerChannel = bitsPerChannel
    self.bytesPerFrame = bytesPerFrame
    self.channelsPerFrame = channelsPerFrame
    self.framesPerPacket = framesPerPacket
    self.bytesPerPacket = bytesPerPacket
  }
}

/// One callback buffer's platform-neutral geometry.
public struct AudioBufferGeometry: Hashable, Sendable {
  public let channelCount: Int
  public let byteCount: Int

  public init(channelCount: Int, byteCount: Int) {
    self.channelCount = channelCount
    self.byteCount = byteCount
  }
}

/// A platform-neutral description of a validated audio buffer layout.
///
/// Native Core Audio structures stay in the app target. A controller may only
/// enter the direct DSP path after producing one of these plans.
public struct AudioFormatPlan: Hashable, Sendable {
  public let sampleFormat: TapSampleFormat
  public let sampleRate: Double
  public let channelCount: Int
  public let isInterleaved: Bool
  public let bytesPerSample: Int
  public let bytesPerFrame: Int
  public let framesPerPacket: Int
  public let bytesPerPacket: Int

  public init?(
    sampleFormat: TapSampleFormat,
    sampleRate: Double,
    channelCount: Int,
    isInterleaved: Bool,
    bytesPerSample: Int,
    bytesPerFrame: Int,
    framesPerPacket: Int = 1,
    bytesPerPacket: Int? = nil
  ) {
    guard sampleFormat != .unknown,
          sampleRate.isFinite,
          sampleRate > 0,
          channelCount > 0,
          bytesPerSample > 0,
          bytesPerFrame > 0,
          framesPerPacket > 0 else {
      return nil
    }

    let expectedSampleBytes: Int
    switch sampleFormat {
    case .float32, .int32:
      expectedSampleBytes = 4
    case .int16:
      expectedSampleBytes = 2
    case .unknown:
      return nil
    }
    guard bytesPerSample == expectedSampleBytes else { return nil }

    let expectedFrameBytes: Int
    if isInterleaved {
      let product = bytesPerSample.multipliedReportingOverflow(by: channelCount)
      guard !product.overflow else { return nil }
      expectedFrameBytes = product.partialValue
    } else {
      expectedFrameBytes = bytesPerSample
    }
    guard bytesPerFrame == expectedFrameBytes else { return nil }

    let expectedPacketBytes = bytesPerFrame.multipliedReportingOverflow(by: framesPerPacket)
    guard !expectedPacketBytes.overflow else { return nil }
    let resolvedBytesPerPacket = bytesPerPacket ?? expectedPacketBytes.partialValue
    guard resolvedBytesPerPacket == expectedPacketBytes.partialValue else { return nil }

    self.sampleFormat = sampleFormat
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.isInterleaved = isInterleaved
    self.bytesPerSample = bytesPerSample
    self.bytesPerFrame = bytesPerFrame
    self.framesPerPacket = framesPerPacket
    self.bytesPerPacket = resolvedBytesPerPacket
  }

  public init?(validating description: LinearPCMFormatDescription) {
    guard description.isLinearPCM,
          description.isPacked,
          !description.isAlignedHigh,
          description.isNativeEndian,
          !description.hasUnsupportedFormatFlags,
          description.hasValidReservedField,
          description.bitsPerChannel > 0,
          description.bitsPerChannel.isMultiple(of: 8) else {
      return nil
    }

    let sampleFormat: TapSampleFormat
    switch (
      description.isFloat,
      description.isSignedInteger,
      description.bitsPerChannel
    ) {
    case (true, false, 32):
      sampleFormat = .float32
    case (false, true, 16):
      sampleFormat = .int16
    case (false, true, 32):
      sampleFormat = .int32
    default:
      return nil
    }

    self.init(
      sampleFormat: sampleFormat,
      sampleRate: description.sampleRate,
      channelCount: description.channelsPerFrame,
      isInterleaved: !description.isNonInterleaved,
      bytesPerSample: description.bitsPerChannel / 8,
      bytesPerFrame: description.bytesPerFrame,
      framesPerPacket: description.framesPerPacket,
      bytesPerPacket: description.bytesPerPacket
    )
  }

  /// Validates one complete input or output callback layout.
  public func validatesBufferGeometry(_ buffers: [AudioBufferGeometry]) -> Bool {
    guard !buffers.isEmpty else { return false }

    if isInterleaved {
      guard buffers.count == 1,
            buffers[0].channelCount == channelCount,
            buffers[0].byteCount >= 0,
            buffers[0].byteCount.isMultiple(of: bytesPerFrame) else {
        return false
      }
      return true
    }

    guard buffers.count == channelCount else { return false }
    var expectedByteCount: Int?
    for buffer in buffers {
      guard buffer.channelCount == 1,
            buffer.byteCount >= 0,
            buffer.byteCount.isMultiple(of: bytesPerFrame) else {
        return false
      }
      if let expectedByteCount {
        guard buffer.byteCount == expectedByteCount else { return false }
      } else {
        expectedByteCount = buffer.byteCount
      }
    }
    return true
  }

  /// Requires matching, independently-valid input and output callback geometry.
  public func validatesCallbackGeometry(
    input: [AudioBufferGeometry],
    output: [AudioBufferGeometry]
  ) -> Bool {
    validatesBufferGeometry(input)
      && validatesBufferGeometry(output)
      && input == output
  }
}
