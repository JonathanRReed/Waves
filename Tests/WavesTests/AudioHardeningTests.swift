import AudioToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func captureAuthorizationDiagnosticsFormattingKeepsEveryStructuredStateDistinct() async {
  #expect(DiagnosticsExportFormatter.captureAuthorizationDescription(.authorized) == "authorized")
  #expect(DiagnosticsExportFormatter.captureAuthorizationDescription(.notGranted) == "notGranted")
  #expect(DiagnosticsExportFormatter.captureAuthorizationDescription(.undetermined) == "undetermined")
  #expect(DiagnosticsExportFormatter.captureAuthorizationDescription(.unsupported) == "unsupported")
  #expect(
    DiagnosticsExportFormatter.captureAuthorizationDescription(.probeFailed(nativeStatus: -50))
      == "probeFailed (native status: -50)"
  )
  #expect(
    DiagnosticsExportFormatter.captureAuthorizationDescription(nil)
      == "undetermined (no live authorization probe result retained in this process)"
  )

  #expect(CaptureAuthorizationResult.fromProbe(
    isPlatformSupported: false,
    nativeStatus: noErr
  ) == .unsupported)
  #expect(CaptureAuthorizationResult.fromProbe(
    isPlatformSupported: true,
    nativeStatus: noErr
  ) == .authorized)

  for nativeStatus: Int32 in [-50, -108, Int32.min] {
    let result = CaptureAuthorizationResult.fromProbe(
      isPlatformSupported: true,
      nativeStatus: nativeStatus
    )
    #expect(result == .probeFailed(nativeStatus: nativeStatus))
    #expect(result != .notGranted)

    let presentation = CaptureAuthorizationPresentation(result)
    #expect(presentation.status == .failed)
    #expect(presentation.detail.contains("could not verify"))
    #expect(presentation.detail.contains("OSStatus: \(nativeStatus)"))
    #expect(presentation.backendErrorDetail == presentation.detail)
  }

  let probeFailedBackend = WorkspaceAudioControlBackend(
    testingSnapshot: hardeningSnapshot(),
    captureAuthorization: .probeFailed(nativeStatus: -50),
    intentRouteApplyOverride: { _, _ in }
  )
  #expect(await probeFailedBackend.captureAuthorizationResult() == .probeFailed(nativeStatus: -50))
  #expect(await probeFailedBackend.audioCapabilityMode() == .limited)

  let app = AudioApp(
    id: "runtime.app",
    logicalID: "logical.app",
    displayName: "Managed App",
    category: .media,
    compatibility: .supported
  )
  var routeSnapshot = hardeningSnapshot()
  routeSnapshot.apps = [app]
  let routeBackend = WorkspaceAudioControlBackend(
    testingSnapshot: routeSnapshot,
    captureAuthorization: .probeFailed(nativeStatus: -50),
    intentRouteApplyOverride: { _, _ in }
  )
  let applyResult = await routeBackend.applyAppIntent(AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.8,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: 1,
    reason: .automation
  ))
  #expect(applyResult.outcome == .applied)
  #expect(!applyResult.backendStatus.hasRequiredPermissions)
  #expect(!applyResult.backendStatus.isRouteRecoveryHealthy)
  #expect(applyResult.backendStatus.lastError?.contains("could not verify") == true)

  let authorizedBackend = WorkspaceAudioControlBackend(
    testingSnapshot: hardeningSnapshot(),
    captureAuthorization: .authorized,
    intentRouteApplyOverride: { _, _ in }
  )
  #expect(await authorizedBackend.audioCapabilityMode() == .full)
}

@Test func nativeASBDConversionAcceptsOnlySupportedLinearPCMLayouts() throws {
  let interleavedFloat = AudioStreamBasicDescription(
    mSampleRate: 48_000,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 8,
    mFramesPerPacket: 1,
    mBytesPerFrame: 8,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 32,
    mReserved: 0
  )
  let floatPlan = try #require(AudioFormatPlan(nativeStreamDescription: interleavedFloat))
  #expect(floatPlan.sampleFormat == .float32)
  #expect(floatPlan.isInterleaved)
  #expect(floatPlan.channelCount == 2)
  #expect(floatPlan.bytesPerSample == 4)
  #expect(floatPlan.bytesPerFrame == 8)

  let noninterleavedInt16 = AudioStreamBasicDescription(
    mSampleRate: 44_100,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger
      | kAudioFormatFlagIsPacked
      | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 2,
    mFramesPerPacket: 1,
    mBytesPerFrame: 2,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 16,
    mReserved: 0
  )
  let int16Plan = try #require(AudioFormatPlan(nativeStreamDescription: noninterleavedInt16))
  #expect(int16Plan.sampleFormat == .int16)
  #expect(!int16Plan.isInterleaved)
  #expect(int16Plan.channelCount == 2)
  #expect(int16Plan.bytesPerFrame == 2)

  var invalid = interleavedFloat
  invalid.mFormatID = kAudioFormatMPEG4AAC
  #expect(AudioFormatPlan(nativeStreamDescription: invalid) == nil)

  invalid = interleavedFloat
  invalid.mFormatFlags |= kAudioFormatFlagIsBigEndian
  #expect(AudioFormatPlan(nativeStreamDescription: invalid) == nil)

  invalid = interleavedFloat
  invalid.mFormatFlags |= kAudioFormatFlagIsAlignedHigh
  #expect(AudioFormatPlan(nativeStreamDescription: invalid) == nil)

  invalid = interleavedFloat
  invalid.mFormatFlags |= AudioFormatFlags(0x0000_0080)
  #expect(AudioFormatPlan(nativeStreamDescription: invalid) == nil)

  invalid = interleavedFloat
  invalid.mBytesPerFrame = 4
  invalid.mBytesPerPacket = 4
  #expect(AudioFormatPlan(nativeStreamDescription: invalid) == nil)

  invalid = interleavedFloat
  invalid.mReserved = 1
  #expect(AudioFormatPlan(nativeStreamDescription: invalid) == nil)
}

@Test func platformNeutralFormatValidationRejectsInconsistentDescriptions() throws {
  let interleavedFloat = try #require(AudioFormatPlan(validating: linearPCMDescription()))
  #expect(interleavedFloat.sampleFormat == .float32)
  #expect(interleavedFloat.isInterleaved)

  let noninterleavedInt16 = try #require(AudioFormatPlan(validating: linearPCMDescription(
    isFloat: false,
    isSignedInteger: true,
    isNonInterleaved: true,
    bitsPerChannel: 16,
    bytesPerFrame: 2,
    bytesPerPacket: 2
  )))
  #expect(noninterleavedInt16.sampleFormat == .int16)
  #expect(!noninterleavedInt16.isInterleaved)

  let noninterleavedInt32 = try #require(AudioFormatPlan(validating: linearPCMDescription(
    isFloat: false,
    isSignedInteger: true,
    isNonInterleaved: true,
    bitsPerChannel: 32,
    bytesPerFrame: 4,
    bytesPerPacket: 4
  )))
  #expect(noninterleavedInt32.sampleFormat == .int32)

  #expect(AudioFormatPlan(validating: linearPCMDescription(sampleRate: .nan)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(sampleRate: 0)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(isLinearPCM: false)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(isFloat: false)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(isSignedInteger: true)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(isPacked: false)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(isAlignedHigh: true)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(isNativeEndian: false)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(hasUnsupportedFormatFlags: true)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(hasValidReservedField: false)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(bitsPerChannel: 24)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(bytesPerFrame: 4, bytesPerPacket: 4)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(channelsPerFrame: 0)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(framesPerPacket: 0, bytesPerPacket: 0)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(bytesPerPacket: 16)) == nil)
}

@Test func audioFormatPlanValidatesInterleavedAndNoninterleavedCallbackGeometry() throws {
  let interleaved = try #require(AudioFormatPlan(
    sampleFormat: .float32,
    sampleRate: 48_000,
    channelCount: 2,
    isInterleaved: true,
    bytesPerSample: 4,
    bytesPerFrame: 8
  ))
  let interleavedGeometry = [AudioBufferGeometry(channelCount: 2, byteCount: 1_024)]
  #expect(interleaved.validatesCallbackGeometry(
    input: interleavedGeometry,
    output: interleavedGeometry
  ))
  #expect(!interleaved.validatesBufferGeometry([
    AudioBufferGeometry(channelCount: 1, byteCount: 512),
    AudioBufferGeometry(channelCount: 1, byteCount: 512),
  ]))
  #expect(!interleaved.validatesBufferGeometry([
    AudioBufferGeometry(channelCount: 1, byteCount: 1_024),
  ]))
  #expect(!interleaved.validatesBufferGeometry([
    AudioBufferGeometry(channelCount: 2, byteCount: 1_026),
  ]))
  #expect(!interleaved.validatesCallbackGeometry(
    input: interleavedGeometry,
    output: [AudioBufferGeometry(channelCount: 2, byteCount: 2_048)]
  ))

  let noninterleaved = try #require(AudioFormatPlan(
    sampleFormat: .int16,
    sampleRate: 48_000,
    channelCount: 2,
    isInterleaved: false,
    bytesPerSample: 2,
    bytesPerFrame: 2
  ))
  let noninterleavedGeometry = [
    AudioBufferGeometry(channelCount: 1, byteCount: 512),
    AudioBufferGeometry(channelCount: 1, byteCount: 512),
  ]
  #expect(noninterleaved.validatesCallbackGeometry(
    input: noninterleavedGeometry,
    output: noninterleavedGeometry
  ))
  #expect(!noninterleaved.validatesBufferGeometry([
    AudioBufferGeometry(channelCount: 2, byteCount: 1_024),
  ]))
  #expect(!noninterleaved.validatesBufferGeometry([
    AudioBufferGeometry(channelCount: 1, byteCount: 512),
    AudioBufferGeometry(channelCount: 1, byteCount: 510),
  ]))
  #expect(!noninterleaved.validatesBufferGeometry([
    AudioBufferGeometry(channelCount: 1, byteCount: 511),
    AudioBufferGeometry(channelCount: 1, byteCount: 511),
  ]))
}

@Test func outputDeviceReadinessNeverInventsOrCarriesForwardCurrentDevice() throws {
  let current = AudioDevice(
    id: "device.current",
    name: "Current Output",
    kind: .builtInOutput,
    isCurrent: true,
    isManagedRouteAvailable: true
  )
  let ready = OutputDeviceReadiness(
    currentDevice: current,
    previousRecentDeviceIDs: ["device.previous", "system-output", ""]
  )
  #expect(ready.currentDevice == current)
  #expect(ready.recentDeviceIDs == ["device.current", "device.previous"])
  #expect(ready.errorDetail == nil)
  #expect(ready.isReady)

  let unavailable = OutputDeviceReadiness(
    currentDevice: nil,
    previousRecentDeviceIDs: ["device.previous", "system-output"],
    failureDetail: "Default output UID query failed (OSStatus: -50)."
  )
  #expect(unavailable.currentDevice == nil)
  #expect(unavailable.recentDeviceIDs == ["device.previous"])
  #expect(unavailable.errorDetail == "Default output UID query failed (OSStatus: -50).")
  #expect(!unavailable.isReady)
}

@Test func missingCurrentDeviceKeepsBackendRouteReadinessUnhealthy() async {
  let app = AudioApp(
    id: "runtime.device-app",
    logicalID: "logical.device-app",
    displayName: "Device App",
    category: .media,
    compatibility: .supported
  )
  var snapshot = hardeningSnapshot()
  snapshot.apps = [app]
  snapshot.currentDevice = nil
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    captureAuthorization: .authorized,
    intentRouteApplyOverride: { _, _ in }
  )

  let result = await backend.applyAppIntent(AppRouteIntent(
    appID: app.logicalID,
    desiredVolume: 0.75,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: 1,
    reason: .automation
  ))

  #expect(result.outcome == .applied)
  #expect(result.backendStatus.hasRequiredPermissions)
  #expect(!result.backendStatus.isRouteRecoveryHealthy)
}

@Test func preEQHeadroomPreventsPrematureBoostingEQSaturation() {
  let sampleRate = 48_000.0
  var settings = EqualizerSettings(
    isEnabled: true,
    mode: .simple,
    simpleGainsDB: [12, 0, 0]
  )
  settings.setGain(12, at: 0)
  let headroomGain = Float(pow(10, Double(settings.headroomCompensationDB) / 20))
  let source = (0..<8_192).map { index in
    Float(sin(2 * Double.pi * 60 * Double(index) / sampleRate) * 0.95)
  }
  var protected = source
  var unprotected = source
  let protectedEQ = EqualizerDSP(
    sampleRate: sampleRate,
    channelCount: 1,
    settings: settings
  )
  let unprotectedEQ = EqualizerDSP(
    sampleRate: sampleRate,
    channelCount: 1,
    settings: settings
  )

  protected.withUnsafeMutableBytes { bytes in
    TapDSP.processEqualized(
      bytes.baseAddress!,
      byteCount: bytes.count,
      format: .float32,
      equalizer: protectedEQ,
      equalizerHeadroomGain: headroomGain,
      manualGain: 1,
      bufferChannelCount: 1
    )
  }
  unprotected.withUnsafeMutableBytes { bytes in
    TapDSP.processEqualized(
      bytes.baseAddress!,
      byteCount: bytes.count,
      format: .float32,
      equalizer: unprotectedEQ,
      equalizerHeadroomGain: 1,
      manualGain: 1,
      bufferChannelCount: 1
    )
  }

  let settledProtected = protected.dropFirst(2_048)
  let settledUnprotected = unprotected.dropFirst(2_048)
  let protectedPeak = settledProtected.map { abs($0) }.max() ?? 0
  let unprotectedSaturatedSamples = settledUnprotected.count { abs($0) >= 0.999_9 }

  #expect(unprotectedSaturatedSamples > 100)
  #expect(settledProtected.allSatisfy { abs($0) < 0.999_9 })
  #expect(protectedPeak > 0.7)
  #expect(protectedPeak < 0.98)
}

private func linearPCMDescription(
  sampleRate: Double = 48_000,
  isLinearPCM: Bool = true,
  isFloat: Bool = true,
  isSignedInteger: Bool = false,
  isPacked: Bool = true,
  isAlignedHigh: Bool = false,
  isNativeEndian: Bool = true,
  isNonInterleaved: Bool = false,
  hasUnsupportedFormatFlags: Bool = false,
  hasValidReservedField: Bool = true,
  bitsPerChannel: Int = 32,
  bytesPerFrame: Int = 8,
  channelsPerFrame: Int = 2,
  framesPerPacket: Int = 1,
  bytesPerPacket: Int = 8
) -> LinearPCMFormatDescription {
  LinearPCMFormatDescription(
    sampleRate: sampleRate,
    isLinearPCM: isLinearPCM,
    isFloat: isFloat,
    isSignedInteger: isSignedInteger,
    isPacked: isPacked,
    isAlignedHigh: isAlignedHigh,
    isNativeEndian: isNativeEndian,
    isNonInterleaved: isNonInterleaved,
    hasUnsupportedFormatFlags: hasUnsupportedFormatFlags,
    hasValidReservedField: hasValidReservedField,
    bitsPerChannel: bitsPerChannel,
    bytesPerFrame: bytesPerFrame,
    channelsPerFrame: channelsPerFrame,
    framesPerPacket: framesPerPacket,
    bytesPerPacket: bytesPerPacket
  )
}

private func hardeningSnapshot() -> AudioSessionSnapshot {
  let device = AudioDevice(
    id: "device.current",
    name: "Current Output",
    kind: .builtInOutput,
    isCurrent: true,
    isManagedRouteAvailable: true
  )
  return AudioSessionSnapshot(
    apps: [],
    currentDevice: device,
    recentDeviceIDs: [device.id],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}
