import AudioToolbox
import WavesAudioCore

extension AudioFormatPlan {
  init?(nativeStreamDescription description: AudioStreamBasicDescription) {
    let supportedFlags: AudioFormatFlags =
      kAudioFormatFlagIsFloat
      | kAudioFormatFlagIsBigEndian
      | kAudioFormatFlagIsSignedInteger
      | kAudioFormatFlagIsPacked
      | kAudioFormatFlagIsAlignedHigh
      | kAudioFormatFlagIsNonInterleaved
      | kAudioFormatFlagIsNonMixable

    #if _endian(big)
      let nativeIsBigEndian = true
    #else
      let nativeIsBigEndian = false
    #endif

    let flags = description.mFormatFlags
    self.init(validating: LinearPCMFormatDescription(
      sampleRate: description.mSampleRate,
      isLinearPCM: description.mFormatID == kAudioFormatLinearPCM,
      isFloat: (flags & kAudioFormatFlagIsFloat) != 0,
      isSignedInteger: (flags & kAudioFormatFlagIsSignedInteger) != 0,
      isPacked: (flags & kAudioFormatFlagIsPacked) != 0,
      isAlignedHigh: (flags & kAudioFormatFlagIsAlignedHigh) != 0,
      isNativeEndian: ((flags & kAudioFormatFlagIsBigEndian) != 0) == nativeIsBigEndian,
      isNonInterleaved: (flags & kAudioFormatFlagIsNonInterleaved) != 0,
      hasUnsupportedFormatFlags: (flags & ~supportedFlags) != 0,
      hasValidReservedField: description.mReserved == 0,
      bitsPerChannel: Int(description.mBitsPerChannel),
      bytesPerFrame: Int(description.mBytesPerFrame),
      channelsPerFrame: Int(description.mChannelsPerFrame),
      framesPerPacket: Int(description.mFramesPerPacket),
      bytesPerPacket: Int(description.mBytesPerPacket)
    ))
  }
}
