import AudioToolbox
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func mutingTapTeardownRestoresOriginalAudioBeforeStoppingTheRenderer() {
  var events: [String] = []

  let result = MutingTapTeardownPreparation.perform(
    makeOriginalAudioAudible: {
      events.append("unmute-tap")
      return noErr
    },
    stopIOProc: {
      events.append("stop-io")
      return noErr
    },
    restoreTapMuting: {
      events.append("restore-tap-mute")
      return noErr
    },
    deactivateRenderer: {
      events.append("deactivate-renderer")
    }
  )

  #expect(events == ["unmute-tap", "stop-io", "deactivate-renderer"])
  #expect(result.canDestroyNativeResources)
  #expect(result.originalAudioIsFailOpen)
}

@Test func failedMutingTapStopKeepsTheRendererLiveEvenAfterAnUnmuteRequest() {
  var bothFailedEvents: [String] = []
  let bothFailed = MutingTapTeardownPreparation.perform(
    makeOriginalAudioAudible: {
      bothFailedEvents.append("unmute-tap")
      return -1
    },
    stopIOProc: {
      bothFailedEvents.append("stop-io")
      return -2
    },
    restoreTapMuting: {
      bothFailedEvents.append("restore-tap-mute")
      return noErr
    },
    deactivateRenderer: {
      bothFailedEvents.append("deactivate-renderer")
    }
  )

  #expect(bothFailedEvents == ["unmute-tap"])
  #expect(!bothFailed.canDestroyNativeResources)
  #expect(!bothFailed.originalAudioIsFailOpen)

  var unmutedEvents: [String] = []
  let unmutedBeforeStopFailure = MutingTapTeardownPreparation.perform(
    makeOriginalAudioAudible: {
      unmutedEvents.append("unmute-tap")
      return noErr
    },
    stopIOProc: {
      unmutedEvents.append("stop-io")
      return -2
    },
    restoreTapMuting: {
      unmutedEvents.append("restore-tap-mute")
      return noErr
    },
    deactivateRenderer: {
      unmutedEvents.append("deactivate-renderer")
    }
  )

  #expect(unmutedEvents == ["unmute-tap", "stop-io", "restore-tap-mute"])
  #expect(!unmutedBeforeStopFailure.canDestroyNativeResources)
  #expect(unmutedBeforeStopFailure.audiblePath == .wavesRenderer)
}

@Test func processTapAggregateStartsImmediatelyWithoutWaitingForSourceAudio() {
  #expect(!ProcessTapAggregatePolicy.autoStartEnabled)
}

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

  #expect(
    CaptureAuthorizationResult.fromProbe(
      isPlatformSupported: false,
      nativeStatus: noErr
    ) == .unsupported)
  #expect(
    CaptureAuthorizationResult.fromProbe(
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
  let applyResult = await routeBackend.applyAppIntent(
    AppRouteIntent(
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

@Test func workspaceDiagnosticsReuseOnlyTheExplicitlyFreshAuthorizationProbe() async {
  let counter = CaptureProbeCounter()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: hardeningSnapshot(),
    captureAuthorizationProbe: {
      counter.increment()
      return .authorized
    }
  )

  #expect(await backend.refreshCaptureAuthorization() == .authorized)
  _ = await backend.diagnosticsReport(reprobeCaptureAuthorization: false)
  #expect(counter.value == 1)

  _ = await backend.diagnosticsReport()
  #expect(counter.value == 2)
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

  let noninterleavedInt16 = try #require(
    AudioFormatPlan(
      validating: linearPCMDescription(
        isFloat: false,
        isSignedInteger: true,
        isNonInterleaved: true,
        bitsPerChannel: 16,
        bytesPerFrame: 2,
        bytesPerPacket: 2
      )))
  #expect(noninterleavedInt16.sampleFormat == .int16)
  #expect(!noninterleavedInt16.isInterleaved)

  let noninterleavedInt32 = try #require(
    AudioFormatPlan(
      validating: linearPCMDescription(
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
  #expect(AudioFormatPlan(validating: linearPCMDescription(sampleRate: 7_999)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(sampleRate: 384_001)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(sampleRate: .greatestFiniteMagnitude)) == nil)
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
  #expect(
    AudioFormatPlan(
      validating: linearPCMDescription(
        bytesPerFrame: 4 * (AudioFormatPlan.maximumChannelCount + 1),
        channelsPerFrame: AudioFormatPlan.maximumChannelCount + 1,
        bytesPerPacket: 4 * (AudioFormatPlan.maximumChannelCount + 1)
      )) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(framesPerPacket: 0, bytesPerPacket: 0)) == nil)
  #expect(AudioFormatPlan(validating: linearPCMDescription(bytesPerPacket: 16)) == nil)
}

@Test func nativeStreamConfigurationAcceptsACompleteBoundedBufferList() throws {
  let bufferOffset = try #require(MemoryLayout<AudioBufferList>.offset(of: \.mBuffers))
  let byteCount = bufferOffset + 2 * MemoryLayout<AudioBuffer>.stride
  let bytes = nativeStreamConfigurationBytes(byteCount: byteCount, numberBuffers: 2)

  let streamCount = bytes.withUnsafeBytes(NativeAudioStreamConfigurationPlan.streamCount)
  #expect(streamCount == 2)
}

@Test func nativeStreamConfigurationRejectsTruncatedAndForgedBufferLists() throws {
  let truncated = Data(repeating: 0, count: MemoryLayout<UInt32>.size - 1)
  #expect(truncated.withUnsafeBytes(NativeAudioStreamConfigurationPlan.streamCount) == nil)

  let fixedHeader = MemoryLayout<AudioBufferList>.size
  let incompleteHeader = nativeStreamConfigurationBytes(
    byteCount: fixedHeader - 1,
    numberBuffers: 0
  )
  #expect(incompleteHeader.withUnsafeBytes(NativeAudioStreamConfigurationPlan.streamCount) == nil)

  let forged = nativeStreamConfigurationBytes(byteCount: fixedHeader, numberBuffers: 10)
  #expect(forged.withUnsafeBytes(NativeAudioStreamConfigurationPlan.streamCount) == nil)

  let buffersOffset = try #require(MemoryLayout<AudioBufferList>.offset(of: \.mBuffers))
  let excessiveCount = nativeStreamConfigurationBytes(
    byteCount: buffersOffset + 257 * MemoryLayout<AudioBuffer>.stride,
    numberBuffers: 257
  )
  #expect(excessiveCount.withUnsafeBytes(NativeAudioStreamConfigurationPlan.streamCount) == nil)
}

@Test func nativeStreamConfigurationRejectsOversizedProperties() {
  let oversized = nativeStreamConfigurationBytes(byteCount: 65_537, numberBuffers: 1)
  #expect(oversized.withUnsafeBytes(NativeAudioStreamConfigurationPlan.streamCount) == nil)
}

@Test func nativeStreamUsageAllocationUsesCheckedBoundedArithmetic() throws {
  let streamsOffset = try #require(
    MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)
  )
  #expect(
    NativeAudioStreamConfigurationPlan.usageAllocationSize(streamCount: 2)
      == streamsOffset + 2 * MemoryLayout<UInt32>.stride)
  #expect(NativeAudioStreamConfigurationPlan.usageAllocationSize(streamCount: 257) == nil)
  #expect(NativeAudioStreamConfigurationPlan.usageAllocationSize(streamCount: UInt32.max) == nil)
}

@Test func routeCreationRejectsAStaleResolvedProcessLifetime() async {
  let expectedIdentity = audioSecurityRuntimeIdentity(startTimeSeconds: 100)
  let replacementIdentity = audioSecurityRuntimeIdentity(startTimeSeconds: 200)
  let factoryCalls = CaptureProbeCounter()
  let backend = identityRevalidationBackend(
    appIdentity: expectedIdentity,
    runtimeIdentityProvider: { _ in replacementIdentity },
    processObjectTranslator: { _ in 7 },
    factoryCalls: factoryCalls
  )

  let result = await backend.applyAppIntent(audioSecurityRouteIntent())

  #expect(result.outcome == .failed)
  #expect(factoryCalls.value == 0)
  _ = await backend.shutdownWithResult()
}

@Test func routeCreationRejectsChangedCoreAudioProcessOwnership() async {
  let identity = audioSecurityRuntimeIdentity(startTimeSeconds: 100)
  let factoryCalls = CaptureProbeCounter()
  let backend = identityRevalidationBackend(
    appIdentity: identity,
    runtimeIdentityProvider: { _ in identity },
    processObjectTranslator: { _ in 99 },
    factoryCalls: factoryCalls
  )

  let result = await backend.applyAppIntent(audioSecurityRouteIntent())

  #expect(result.outcome == .failed)
  #expect(factoryCalls.value == 0)
  _ = await backend.shutdownWithResult()
}

@Test func audioFormatPlanRejectsExcessiveDirectChannelCounts() {
  #expect(
    AudioFormatPlan(
      sampleFormat: .float32,
      sampleRate: 48_000,
      channelCount: AudioFormatPlan.maximumChannelCount + 1,
      isInterleaved: false,
      bytesPerSample: 4,
      bytesPerFrame: 4
    ) == nil)
}

@Test func audioFormatPlanValidatesInterleavedAndNoninterleavedCallbackGeometry() throws {
  let interleaved = try #require(
    AudioFormatPlan(
      sampleFormat: .float32,
      sampleRate: 48_000,
      channelCount: 2,
      isInterleaved: true,
      bytesPerSample: 4,
      bytesPerFrame: 8
    ))
  let interleavedGeometry = [AudioBufferGeometry(channelCount: 2, byteCount: 1_024)]
  #expect(
    interleaved.validatesCallbackGeometry(
      input: interleavedGeometry,
      output: interleavedGeometry
    ))
  #expect(
    !interleaved.validatesBufferGeometry([
      AudioBufferGeometry(channelCount: 1, byteCount: 512),
      AudioBufferGeometry(channelCount: 1, byteCount: 512),
    ]))
  #expect(
    !interleaved.validatesBufferGeometry([
      AudioBufferGeometry(channelCount: 1, byteCount: 1_024)
    ]))
  #expect(
    !interleaved.validatesBufferGeometry([
      AudioBufferGeometry(channelCount: 2, byteCount: 1_026)
    ]))
  #expect(
    !interleaved.validatesCallbackGeometry(
      input: interleavedGeometry,
      output: [AudioBufferGeometry(channelCount: 2, byteCount: 2_048)]
    ))

  let noninterleaved = try #require(
    AudioFormatPlan(
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
  #expect(
    noninterleaved.validatesCallbackGeometry(
      input: noninterleavedGeometry,
      output: noninterleavedGeometry
    ))
  #expect(
    !noninterleaved.validatesBufferGeometry([
      AudioBufferGeometry(channelCount: 2, byteCount: 1_024)
    ]))
  #expect(
    !noninterleaved.validatesBufferGeometry([
      AudioBufferGeometry(channelCount: 1, byteCount: 512),
      AudioBufferGeometry(channelCount: 1, byteCount: 510),
    ]))
  #expect(
    !noninterleaved.validatesBufferGeometry([
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

  let result = await backend.applyAppIntent(
    AppRouteIntent(
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

@Test func backendTerminationReleaseMatchesTheExactRuntimeIdentity() async throws {
  let terminatedIdentity = audioSecurityRuntimeIdentity(startTimeSeconds: 100)
  let replacementIdentity = audioSecurityRuntimeIdentity(startTimeSeconds: 200)
  let terminated = AudioApp(
    id: "runtime.terminated",
    logicalID: "com.example.player.terminated",
    pid: 42,
    bundleID: "com.example.shared",
    displayName: "Terminated",
    category: .media,
    isActive: true,
    routingState: .managed,
    compatibility: .supported,
    runtimeIdentity: terminatedIdentity
  )
  let replacement = AudioApp(
    id: "runtime.replacement",
    logicalID: "com.example.player.replacement",
    pid: 42,
    bundleID: "com.example.shared",
    displayName: "Replacement",
    category: .media,
    isActive: true,
    routingState: .managed,
    compatibility: .supported,
    runtimeIdentity: replacementIdentity
  )
  var snapshot = hardeningSnapshot()
  snapshot.apps = [terminated, replacement]
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    captureAuthorization: .authorized
  )

  await backend.releaseControllers(
    forRuntimeIdentity: terminatedIdentity,
    clearMuteState: false
  )

  let released = await backend.currentSnapshot()
  let terminatedAfterRelease = try #require(
    released.apps.first { $0.id == terminated.id }
  )
  let replacementAfterRelease = try #require(
    released.apps.first { $0.id == replacement.id }
  )
  #expect(terminatedAfterRelease.routingState == .monitorOnly)
  #expect(!terminatedAfterRelease.isActive)
  #expect(replacementAfterRelease.routingState == .managed)
  #expect(replacementAfterRelease.isActive)
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

private func nativeStreamConfigurationBytes(byteCount: Int, numberBuffers: UInt32) -> Data {
  var data = Data(repeating: 0, count: byteCount)
  withUnsafeBytes(of: numberBuffers) { countBytes in
    data.replaceSubrange(0..<min(data.count, countBytes.count), with: countBytes.prefix(data.count))
  }
  return data
}

private func audioSecurityRuntimeIdentity(startTimeSeconds: UInt64) -> AppRuntimeIdentity {
  AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(
      pid: 42,
      startTimeSeconds: startTimeSeconds,
      startTimeMicroseconds: 0
    ),
    executablePath: "/Applications/Player.app/Contents/MacOS/Player",
    outerBundlePath: "/Applications/Player.app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.player",
      teamIdentifier: "TEAM123",
      designatedRequirement: "identifier \"com.example.player\"",
      codeDirectoryHash: Data([1, 2, 3])
    )
  )
}

private func audioSecurityRouteIntent() -> AppRouteIntent {
  AppRouteIntent(
    appID: "com.example.player",
    desiredVolume: 0.5,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: 1,
    reason: .automation
  )
}

private func identityRevalidationBackend(
  appIdentity: AppRuntimeIdentity,
  runtimeIdentityProvider: @escaping WorkspaceAudioControlBackend.RuntimeIdentityProvider,
  processObjectTranslator: @escaping WorkspaceAudioControlBackend.ProcessObjectTranslator,
  factoryCalls: CaptureProbeCounter
) -> WorkspaceAudioControlBackend {
  let app = AudioApp(
    id: "com.example.player",
    logicalID: "com.example.player",
    pid: 42,
    bundleID: "com.example.player",
    displayName: "Player",
    category: .media,
    isActive: true,
    routingState: .live,
    compatibility: .supported,
    runtimeIdentity: appIdentity
  )
  var snapshot = hardeningSnapshot()
  snapshot.apps = [app]
  return WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    captureAuthorization: .authorized,
    controllerFactory: { app, processObjectIDs, _, _, _ in
      factoryCalls.increment()
      return try PerAppTapController.testingController(
        appID: app.id,
        logicalID: app.logicalID,
        targetProcessObjectIDs: processObjectIDs
      )
    },
    processTargetResolver: { _ in
      ResolvedProcessTarget(
        targetRuntimeIdentity: appIdentity,
        processes: [ResolvedProcessObject(id: 7, runtimeIdentity: appIdentity)],
        requiresLiveIdentityValidation: true
      )
    },
    liveRuntimeIdentityProvider: runtimeIdentityProvider,
    processObjectTranslator: processObjectTranslator
  )
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

// MARK: - Stale Core Audio objects (WAV-002)

@Test func vanishedAudioObjectIsClassifiedApartFromRealFailures() {
  // '!obj' — the object stopped existing between enumeration and the read.
  // Ordinary app churn, and the one status that must never reach the log as a
  // warning: 1.3.0 emitted 34 of these in a single audit window.
  #expect(CoreAudioObjectReadOutcome(kAudioHardwareBadObjectError) == .objectDisappeared)
  #expect(kAudioHardwareBadObjectError == 560_947_818)

  #expect(CoreAudioObjectReadOutcome(noErr) == .ok)

  // Everything else stays visible: permission trouble, unknown properties,
  // device faults, and bad-size reads all still deserve a warning.
  for status in [
    kAudioHardwareUnknownPropertyError,
    kAudioHardwareBadPropertySizeError,
    kAudioHardwareNotRunningError,
    kAudioHardwareIllegalOperationError,
    kAudioHardwareBadDeviceError,
    OSStatus(-50),
  ] {
    #expect(CoreAudioObjectReadOutcome(status) == .failed(status))
    #expect(CoreAudioObjectReadOutcome(status).isObjectDisappeared == false)
  }
}

@Test func staleObjectTallyDeduplicatesWithinAPass() {
  var tally = StaleAudioObjectTally()
  #expect(tally.isEmpty)
  #expect(tally.count == 0)

  let firstSighting = tally.record(AudioObjectID(41))
  // The same dead object is read twice in one pass (running-output check, then
  // pid). It must count once, so the summary line reports objects, not reads.
  let repeatSighting = tally.record(AudioObjectID(41))
  #expect(firstSighting)
  #expect(repeatSighting == false)
  #expect(tally.count == 1)

  let otherObject = tally.record(AudioObjectID(42))
  #expect(otherObject)
  #expect(tally.count == 2)
  #expect(tally.isEmpty == false)

  // A fresh pass starts clean — a tally never carries IDs across enumerations.
  let next = StaleAudioObjectTally()
  #expect(next.isEmpty)
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

private final class CaptureProbeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }

  func increment() {
    lock.withLock { count += 1 }
  }
}

// MARK: - Route liveness (the 1.3.0 rebuild loop)

@Test func silentRouteIsNotMistakenForADeadOne() {
  // The whole point of the rule: an app holding its IO open while emitting
  // digital silence keeps producing callbacks, so the tick advances and the
  // route reads as alive. Judging by level instead is what made 1.3.0 destroy
  // and rebuild a working route every six seconds, forever.
  #expect(RouteLivenessJudgment.isRendering(currentTick: 5_001, previousTick: 5_000))
  #expect(RouteLivenessJudgment.isRendering(currentTick: 1, previousTick: 0))
}

@Test func routeThatStoppedRenderingIsDetected() {
  // A stalled IO proc leaves the count exactly where it was.
  #expect(RouteLivenessJudgment.isRendering(currentTick: 5_000, previousTick: 5_000) == false)
  #expect(RouteLivenessJudgment.isRendering(currentTick: 0, previousTick: 0) == false)
}

@Test func firstObservationNeverCondemnsARoute() {
  // One sample cannot prove absence, and the caller has no baseline yet. Biased
  // toward "alive" for exactly one poll: a wrong "dead" destroys a working
  // route, a wrong "alive" costs one extra 250 ms poll.
  #expect(RouteLivenessJudgment.isRendering(currentTick: 0, previousTick: nil))
  #expect(RouteLivenessJudgment.isRendering(currentTick: .max, previousTick: nil))
}

@Test func rebuiltControllerAndCounterWraparoundBothReadAsRendering() {
  // A fresh controller restarts its counter at 0 against a stale high baseline,
  // and the counter wraps with &+= — both are "different", so neither can
  // strand a live route as falsely dead.
  #expect(RouteLivenessJudgment.isRendering(currentTick: 0, previousTick: 9_999))
  #expect(RouteLivenessJudgment.isRendering(currentTick: 0, previousTick: .max))
}

// MARK: - Tap input stream layout

@Test func tapInputStreamLayoutEnablesOnlyTheTrailingTapStreamsWhenCountsAgree() {
  // Output-only device (built-in speakers, Bluetooth output): the tap is the
  // only input stream, everything is enabled, no offset.
  let speakers = TapInputStreamLayout(aggregateInputStreamCount: 1, subDeviceInputStreamCount: 0, tapStreamCount: 1)
  #expect(speakers.tapStreamOffset == 0)
  #expect(speakers.enabledStreamRange == nil)

  // A headset or virtual device with one input stream: the device's stream
  // comes first, the tap's after it. Only the tap's stream is enabled.
  let headset = TapInputStreamLayout(aggregateInputStreamCount: 2, subDeviceInputStreamCount: 1, tapStreamCount: 1)
  #expect(headset.tapStreamOffset == 1)
  #expect(headset.enabledStreamRange == 1..<2)

  // An interface with several input streams and a non-interleaved tap.
  let interface = TapInputStreamLayout(aggregateInputStreamCount: 5, subDeviceInputStreamCount: 3, tapStreamCount: 2)
  #expect(interface.tapStreamOffset == 3)
  #expect(interface.enabledStreamRange == 3..<5)

  // Counts that do not add up mean the layout is not understood: enable
  // everything and let the callback's exact-count check report a mismatch.
  let unexpected = TapInputStreamLayout(aggregateInputStreamCount: 3, subDeviceInputStreamCount: 1, tapStreamCount: 1)
  #expect(unexpected.tapStreamOffset == 0)
  #expect(unexpected.enabledStreamRange == nil)
  let missingTap = TapInputStreamLayout(aggregateInputStreamCount: 1, subDeviceInputStreamCount: 1, tapStreamCount: 1)
  #expect(missingTap.tapStreamOffset == 0)
  #expect(missingTap.enabledStreamRange == nil)
}
