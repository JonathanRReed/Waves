import AudioToolbox

enum NativeAudioStreamConfigurationPlan {
  static let maximumPropertyByteCount = 65_536
  static let maximumStreamCount: UInt32 = 256

  static func streamCount(in bytes: UnsafeRawBufferPointer) -> UInt32? {
    guard bytes.count >= MemoryLayout<AudioBufferList>.size,
      bytes.count <= maximumPropertyByteCount,
      let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)
    else {
      return nil
    }

    var numberBuffers: UInt32 = 0
    withUnsafeMutableBytes(of: &numberBuffers) { destination in
      destination.copyBytes(from: bytes.prefix(MemoryLayout<UInt32>.size))
    }
    guard numberBuffers <= maximumStreamCount else { return nil }

    let bufferBytes = Int(numberBuffers).multipliedReportingOverflow(
      by: MemoryLayout<AudioBuffer>.stride
    )
    guard !bufferBytes.overflow else { return nil }
    let requiredBytes = buffersOffset.addingReportingOverflow(bufferBytes.partialValue)
    guard !requiredBytes.overflow, requiredBytes.partialValue <= bytes.count else {
      return nil
    }
    return numberBuffers
  }

  static func usageAllocationSize(streamCount: UInt32) -> Int? {
    guard streamCount > 0,
      streamCount <= maximumStreamCount,
      let streamsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)
    else {
      return nil
    }

    let streamBytes = Int(streamCount).multipliedReportingOverflow(
      by: MemoryLayout<UInt32>.stride
    )
    guard !streamBytes.overflow else { return nil }
    let allocationSize = streamsOffset.addingReportingOverflow(streamBytes.partialValue)
    guard !allocationSize.overflow,
      allocationSize.partialValue <= Int(UInt32.max)
    else {
      return nil
    }
    return allocationSize.partialValue
  }
}
