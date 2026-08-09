import AudioToolbox
import Foundation
import WavesAudioCore

extension AudioObjectID {
  static let unknown = AudioObjectID(kAudioObjectUnknown)
}

struct PerAppTapControllerTeardownNativeCalls: Sendable {
  let makeOriginalAudioAudible: @Sendable () -> OSStatus
  let stopIOProc: @Sendable () -> OSStatus
  let restoreTapMuting: @Sendable () -> OSStatus
  let destroyIOProc: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
  let destroyAggregateDevice: @Sendable (AudioObjectID) -> OSStatus
  let destroyProcessTap: @Sendable (AudioObjectID) -> OSStatus

  init(
    makeOriginalAudioAudible: @escaping @Sendable () -> OSStatus,
    stopIOProc: @escaping @Sendable () -> OSStatus,
    restoreTapMuting: @escaping @Sendable () -> OSStatus,
    destroyIOProc: @escaping @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus = { _, _ in noErr },
    destroyAggregateDevice: @escaping @Sendable (AudioObjectID) -> OSStatus = { _ in noErr },
    destroyProcessTap: @escaping @Sendable (AudioObjectID) -> OSStatus = { _ in noErr }
  ) {
    self.makeOriginalAudioAudible = makeOriginalAudioAudible
    self.stopIOProc = stopIOProc
    self.restoreTapMuting = restoreTapMuting
    self.destroyIOProc = destroyIOProc
    self.destroyAggregateDevice = destroyAggregateDevice
    self.destroyProcessTap = destroyProcessTap
  }
}

final class PerAppTapController: @unchecked Sendable {
  let appID: String
  let appName: String
  let targetProcessFamily: TargetProcessFamily
  var targetProcessObjectIDs: [AudioObjectID] {
    targetProcessFamily.processObjectIDs.sorted()
  }
  /// Cleared once its destroy succeeds. Core Audio reuses object IDs, so an ID
  /// that has already been released must never be destroyed a second time — it
  /// may by then belong to something else entirely. Only matters because a
  /// failed teardown is now retried (`retryDispose`).
  private(set) var tapID: AudioObjectID
  private(set) var aggregateDeviceID: AudioObjectID

  private let tapDescription: CATapDescription
  private let stateBox: TapRenderStateBox
  private let audioFormatPlan: AudioFormatPlan
  private let equalizerDSP: EqualizerDSP
  private let managedAudioEqualizerDSP: EqualizerDSP
  private let voiceBandAnalyzer: VoiceBandEnergyAnalyzer
  private let callbackQueue: DispatchQueue
  private let callbackQueueKey = DispatchSpecificKey<UUID>()
  private let callbackQueueToken = UUID()
  private var ioProcID: AudioDeviceIOProcID?
  private var didStartIOProc = false
  private let testingIsActive: Bool
  private let disposeOnce = IdempotentCleanupResult()
  private var retainedCleanupDegradations: [CleanupDegradation] = []
  private var equalizerSettings: EqualizerSettings
  private var managedAudioEqualizerSettings: GlobalEqualizerSettings
  private var equalizerHeadroomGain: Float
  /// Invalidates a scheduled headroom release when a newer EQ change lands
  /// first. Accessed only on `callbackQueue`, like the gain itself.
  private var equalizerHeadroomReleaseGeneration: UInt64 = 0
  private var adaptiveGain: Float
  /// Testing reaches the controller's real disposal sequence while replacing
  /// only the Core Audio calls that require a live tap and renderer.
  private let teardownNativeCalls: PerAppTapControllerTeardownNativeCalls?

  init(
    appID: String,
    appName: String,
    logicalID: String,
    targetProcessObjectIDs: [AudioObjectID],
    targetProcessLifetimeIdentities: [AppProcessLifetimeIdentity] = [],
    tapDescription: CATapDescription,
    tapID: AudioObjectID,
    aggregateDeviceID: AudioObjectID,
    volume: Float,
    volumeBoost: Float,
    muted: Bool,
    equalizerSettings: EqualizerSettings,
    managedAudioEqualizerSettings: GlobalEqualizerSettings,
    adaptiveGainDB: Float,
    audioFormatPlan: AudioFormatPlan,
    teardownNativeCalls: PerAppTapControllerTeardownNativeCalls? = nil,
    testingIsActive: Bool = false
  ) throws {
    self.appID = appID
    self.appName = appName
    self.targetProcessFamily = TargetProcessFamily(
      logicalID: logicalID,
      processObjectIDs: targetProcessObjectIDs,
      processLifetimeIdentities: targetProcessLifetimeIdentities
    )
    self.tapDescription = tapDescription
    self.tapID = tapID
    self.aggregateDeviceID = aggregateDeviceID
    self.audioFormatPlan = audioFormatPlan
    self.teardownNativeCalls = teardownNativeCalls
    self.testingIsActive = testingIsActive
    self.equalizerDSP = EqualizerDSP(
      sampleRate: audioFormatPlan.sampleRate,
      channelCount: audioFormatPlan.channelCount,
      settings: equalizerSettings
    )
    self.managedAudioEqualizerDSP = EqualizerDSP(
      sampleRate: audioFormatPlan.sampleRate,
      channelCount: audioFormatPlan.channelCount,
      settings: managedAudioEqualizerSettings.equalizerSettings
    )
    self.voiceBandAnalyzer = VoiceBandEnergyAnalyzer(
      sampleRate: audioFormatPlan.sampleRate,
      channelCount: audioFormatPlan.channelCount
    )
    self.equalizerSettings = equalizerSettings
    self.managedAudioEqualizerSettings = managedAudioEqualizerSettings
    self.equalizerHeadroomGain = GlobalEqualizerSettings.combinedHeadroomGain(
      perApp: equalizerSettings,
      managedAudio: managedAudioEqualizerSettings
    )
    let safeAdaptiveGainDB = adaptiveGainDB.isFinite ? min(3, max(-18, adaptiveGainDB)) : 0
    self.adaptiveGain = Float(pow(10, Double(safeAdaptiveGainDB) / 20))
    self.callbackQueue = DispatchQueue(label: "com.waves.backend.tap.\(appID)", qos: .userInitiated)
    let initialState = TapRenderState(
      volume: volume,
      volumeBoost: volumeBoost,
      isMuted: muted ? 1 : 0,
      isActive: 1,
      peakLevel: 0,
      rmsLevel: 0,
      analysisRMS: 0,
      voiceBandEnergy: 0,
      renderTick: 0
    )
    self.stateBox = TapRenderStateBox(initialState: initialState)
    self.callbackQueue.setSpecific(key: callbackQueueKey, value: callbackQueueToken)
  }

  static func testingController(
    appID: String,
    logicalID: String? = nil,
    targetProcessObjectIDs: [AudioObjectID] = [],
    teardownNativeCalls: PerAppTapControllerTeardownNativeCalls? = nil
  ) throws -> PerAppTapController {
    let description = CATapDescription(stereoMixdownOfProcesses: [])
    description.name = "Waves-Testing"
    description.uuid = UUID()
    description.muteBehavior = .mutedWhenTapped
    description.isPrivate = true
    guard
      let format = AudioFormatPlan(
        sampleFormat: .float32,
        sampleRate: 48_000,
        channelCount: 2,
        isInterleaved: true,
        bytesPerSample: 4,
        bytesPerFrame: 8
      )
    else {
      throw BackendError.managedRouteUnavailable("Could not make a test audio format.")
    }
    return try PerAppTapController(
      appID: appID,
      appName: "Testing",
      logicalID: logicalID ?? appID,
      targetProcessObjectIDs: targetProcessObjectIDs,
      tapDescription: description,
      tapID: 10_001,
      aggregateDeviceID: 10_002,
      volume: 1,
      volumeBoost: 1,
      muted: false,
      equalizerSettings: EqualizerSettings(),
      managedAudioEqualizerSettings: GlobalEqualizerSettings(),
      adaptiveGainDB: 0,
      audioFormatPlan: format,
      teardownNativeCalls: teardownNativeCalls,
      testingIsActive: true
    )
  }

  func flagGeometryMismatchForTesting() {
    stateBox.flagGeometryMismatch()
  }

  var isActive: Bool {
    stateBox.read().isActive != 0
      && (testingIsActive || (ioProcID != nil && aggregateDeviceID != .unknown))
  }

  func matches(_ target: TargetProcessFamily) -> Bool {
    targetProcessFamily.matches(target)
  }

  /// Whether this controller's existing tap already captures every process in
  /// `target`. Used so a parameter-only change (volume/mute/boost) on a
  /// browser/Electron app — whose audible helper PIDs churn between calls — reuses
  /// the live tap instead of tearing it down, while still rebuilding when a *new*
  /// audio-producing process appears that the current tap doesn't cover.
  func covers(_ target: TargetProcessFamily) -> Bool {
    targetProcessFamily.covers(target)
  }

  func apply(volume: Float, volumeBoost: Float, muted: Bool) {
    let clampedVolume = max(0.0, min(1.0, volume))
    let clampedBoost = max(1.0, min(4.0, volumeBoost))
    // Use async to avoid blocking the caller, especially important for real-time audio
    callbackQueue.async { [weak self] in
      self?.stateBox.writeVolumeAndMute(volume: clampedVolume, volumeBoost: clampedBoost, muted: muted)
    }
  }

  func setVolumeBoost(_ boost: Float) {
    let clampedBoost = max(1.0, min(4.0, boost))
    let currentState = stateBox.read()
    callbackQueue.async { [weak self] in
      self?.stateBox.writeVolumeAndMute(
        volume: currentState.volume,
        volumeBoost: clampedBoost,
        muted: currentState.isMuted != 0
      )
    }
  }

  func setEqualizer(_ settings: EqualizerSettings) {
    callbackQueue.async { [weak self] in
      guard let self else { return }
      self.equalizerSettings = settings
      self.equalizerDSP.update(settings: settings)
      self.updateEqualizerHeadroomGain()
    }
  }

  func setManagedAudioEqualizer(_ settings: GlobalEqualizerSettings) {
    callbackQueue.async { [weak self] in
      guard let self else { return }
      self.managedAudioEqualizerSettings = settings
      self.managedAudioEqualizerDSP.update(settings: settings.equalizerSettings)
      self.updateEqualizerHeadroomGain()
    }
  }

  /// Runs on `callbackQueue`. Extra attenuation lands immediately; *reduced*
  /// attenuation is held for three smoothing windows first, because the EQ
  /// coefficients themselves ramp to their new curve over ~20 ms — releasing
  /// protection while the old boost is still partially in the filters would
  /// clip exactly the transient the headroom exists to absorb.
  private func updateEqualizerHeadroomGain() {
    let target = GlobalEqualizerSettings.combinedHeadroomGain(
      perApp: equalizerSettings,
      managedAudio: managedAudioEqualizerSettings
    )
    equalizerHeadroomReleaseGeneration &+= 1
    if target <= equalizerHeadroomGain {
      equalizerHeadroomGain = target
      return
    }
    let generation = equalizerHeadroomReleaseGeneration
    callbackQueue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
      guard let self, self.equalizerHeadroomReleaseGeneration == generation else { return }
      self.equalizerHeadroomGain = target
    }
  }

  func setAdaptiveGainDB(_ gainDB: Float) {
    let safeGainDB = gainDB.isFinite ? min(3, max(-18, gainDB)) : 0
    callbackQueue.async { [weak self] in
      self?.adaptiveGain = Float(pow(10, Double(safeGainDB) / 20))
    }
  }

  func getCurrentLevels() -> (peak: Float, rms: Float) {
    stateBox.readLevels()
  }

  /// Monotonic count of IO render callbacks. A value that has not moved since
  /// the previous poll means the route really has stopped rendering.
  func currentRenderTick() -> UInt64 {
    stateBox.readRenderTick()
  }

  func getAdaptiveAnalysis() -> AdaptiveAnalysisLevels {
    stateBox.readAdaptiveAnalysis()
  }

  /// Claims the callback's coalesced geometry-mismatch signal from outside the
  /// realtime thread. Recovery work is deliberately owned by the backend actor.
  func consumeGeometryMismatch() -> Bool {
    stateBox.consumeGeometryMismatch()
  }

  func start() throws {
    var procID: AudioDeviceIOProcID?

    // REALTIME_CALLBACK_AUDIT_BEGIN callback
    let status = AudioDeviceCreateIOProcIDWithBlock(
      &procID,
      aggregateDeviceID,
      callbackQueue
    ) { _, inputData, _, outOutputData, _ in
      // First, unconditionally: this is what proves the route is still alive.
      // Every path below can legitimately produce silence.
      self.stateBox.markRenderTick()

      guard self.validatesCallbackGeometry(inputData, outputData: outOutputData) else {
        self.stateBox.flagGeometryMismatch()
        self.zeroOutput(outOutputData)
        return
      }

      let currentState = self.stateBox.read()

      guard currentState.isActive != 0 else {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0, analysisRMS: 0, voiceBandEnergy: 0)
        self.zeroOutput(outOutputData)
        return
      }

      if currentState.isMuted != 0 {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0, analysisRMS: 0, voiceBandEnergy: 0)
        self.zeroOutput(outOutputData)
        return
      }

      let volume = currentState.volume
      let volumeBoost = currentState.volumeBoost
      if volume == 0.0 {
        self.stateBox.writeLevels(peakLevel: 0, rmsLevel: 0, analysisRMS: 0, voiceBandEnergy: 0)
        self.zeroOutput(outOutputData)
        return
      }

      self.renderTappedAudio(
        inputData,
        to: outOutputData,
        volume: volume,
        volumeBoost: volumeBoost
      )
    }
    // REALTIME_CALLBACK_AUDIT_END callback

    if status != noErr {
      if let procID {
        retainedCleanupDegradations.append(
          contentsOf: checkedCleanupDegradations(from: [
            CleanupStatusObservation(
              appID: appID,
              stage: .ioProcDestroy,
              nativeStatus: AudioDeviceDestroyIOProcID(aggregateDeviceID, procID),
              detail: "Destroy IO proc returned by a failed create call"
            )
          ]))
      }
      throw BackendError.managedRouteUnavailable(
        "Failed to create IO proc for \(appName) (OSStatus: \(status))."
      )
    }

    guard let procID else {
      throw BackendError.managedRouteUnavailable(
        "Failed to create IO proc for \(appName)."
      )
    }

    ioProcID = procID
    try configureStreamUsage(for: procID)
    try configureStreamUsage(for: procID, scope: kAudioObjectPropertyScopeOutput)

    let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
    if startStatus != noErr {
      stateBox.setInactive()
      retainedCleanupDegradations.append(
        contentsOf: checkedCleanupDegradations(from: [
          CleanupStatusObservation(
            appID: appID,
            stage: .ioProcDestroy,
            nativeStatus: AudioDeviceDestroyIOProcID(aggregateDeviceID, procID),
            detail: "Destroy IO proc after aggregate-device start failure"
          )
        ]))
      ioProcID = nil
      throw BackendError.managedRouteUnavailable(
        "Failed to start aggregate device for \(appName) (OSStatus: \(startStatus))."
      )
    }
    didStartIOProc = true
  }

  private func configureStreamUsage(for procID: AudioDeviceIOProcID) throws {
    try configureStreamUsage(for: procID, scope: kAudioObjectPropertyScopeInput)
  }

  private func configureStreamUsage(
    for procID: AudioDeviceIOProcID,
    scope: AudioObjectPropertyScope
  ) throws {
    let streamCount = try streamCount(scope: scope)
    guard streamCount > 0 else { return }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyIOProcStreamUsage,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )

    guard
      let usageSize = NativeAudioStreamConfigurationPlan.usageAllocationSize(
        streamCount: streamCount
      )
    else {
      throw BackendError.managedRouteUnavailable(
        "Aggregate stream usage for \(appName) reported an unsupported stream count."
      )
    }
    let usagePointer = UnsafeMutableRawPointer.allocate(
      byteCount: usageSize,
      alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
    )
    defer { usagePointer.deallocate() }

    usagePointer.initializeMemory(as: UInt8.self, repeating: 0, count: usageSize)
    let typedUsage = usagePointer.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    typedUsage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
    typedUsage.pointee.mNumberStreams = streamCount

    let streamsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 0
    let streams =
      usagePointer
      .advanced(by: streamsOffset)
      .assumingMemoryBound(to: UInt32.self)
    for index in 0..<Int(streamCount) {
      streams[index] = 1
    }

    let status = AudioObjectSetPropertyData(
      aggregateDeviceID,
      &address,
      0,
      nil,
      UInt32(usageSize),
      usagePointer
    )

    if status != noErr {
      throw BackendError.managedRouteUnavailable(
        "Failed to enable aggregate stream usage for \(appName) (OSStatus: \(status))."
      )
    }
  }

  private func streamCount(scope: AudioObjectPropertyScope) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(aggregateDeviceID, &address, 0, nil, &dataSize)
    if status != noErr {
      throw BackendError.managedRouteUnavailable(
        "Failed to read stream configuration size for \(appName) (OSStatus: \(status))."
      )
    }

    guard dataSize >= UInt32(MemoryLayout<AudioBufferList>.size),
      dataSize <= UInt32(NativeAudioStreamConfigurationPlan.maximumPropertyByteCount)
    else {
      throw BackendError.managedRouteUnavailable(
        "Stream configuration for \(appName) returned an invalid property size."
      )
    }

    let allocatedSize = Int(dataSize)
    let bufferListPointer = UnsafeMutableRawPointer.allocate(
      byteCount: allocatedSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListPointer.deallocate() }
    bufferListPointer.initializeMemory(as: UInt8.self, repeating: 0, count: allocatedSize)

    status = AudioObjectGetPropertyData(
      aggregateDeviceID,
      &address,
      0,
      nil,
      &dataSize,
      bufferListPointer
    )
    if status != noErr {
      throw BackendError.managedRouteUnavailable(
        "Failed to read stream configuration for \(appName) (OSStatus: \(status))."
      )
    }
    guard dataSize <= UInt32(allocatedSize) else {
      throw BackendError.managedRouteUnavailable(
        "Stream configuration for \(appName) exceeded its reported capacity."
      )
    }

    let bytes = UnsafeRawBufferPointer(start: bufferListPointer, count: Int(dataSize))
    guard let count = NativeAudioStreamConfigurationPlan.streamCount(in: bytes) else {
      throw BackendError.managedRouteUnavailable(
        "Stream configuration for \(appName) returned inconsistent native data."
      )
    }
    return count
  }

  @discardableResult
  /// Retries a teardown that previously failed. Distinct from `dispose()`,
  /// which stays idempotent so a second shutdown request never repeats
  /// destructive native cleanup.
  func retryDispose() -> [CleanupDegradation] {
    disposeOnce.reset()
    return dispose()
  }

  @available(macOS 14.2, *)
  private func makeOriginalAudioAudible() -> OSStatus {
    guard tapID != .unknown else { return noErr }

    tapDescription.muteBehavior = .unmuted
    var descriptionReference: CFTypeRef = tapDescription
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyDescription,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    return withUnsafePointer(to: &descriptionReference) { pointer in
      AudioObjectSetPropertyData(
        tapID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<CFTypeRef>.size),
        pointer
      )
    }
  }

  @available(macOS 14.2, *)
  private func restoreTapMuting() -> OSStatus {
    guard tapID != .unknown else { return noErr }

    tapDescription.muteBehavior = .mutedWhenTapped
    var descriptionReference: CFTypeRef = tapDescription
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyDescription,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    return withUnsafePointer(to: &descriptionReference) { pointer in
      AudioObjectSetPropertyData(
        tapID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<CFTypeRef>.size),
        pointer
      )
    }
  }

  func dispose() -> [CleanupDegradation] {
    disposeOnce.run { [self] in
      var observations: [CleanupStatusObservation] = []

      func finish() -> [CleanupDegradation] {
        let result =
          retainedCleanupDegradations
          + checkedCleanupDegradations(from: observations)
        retainedCleanupDegradations.removeAll()
        return result
      }

      // A `.mutedWhenTapped` tap suppresses the process's direct hardware path
      // while this IO proc reads it. Release that mute before stopping or
      // deactivating the renderer. If both native operations fail, leave the
      // renderer active and retain every resource so the app remains audible.
      let shouldStop =
        teardownNativeCalls != nil || (didStartIOProc && ioProcID != nil && aggregateDeviceID != .unknown)
      let preparation = MutingTapTeardownPreparation.perform(
        makeOriginalAudioAudible: {
          if let teardownNativeCalls {
            return teardownNativeCalls.makeOriginalAudioAudible()
          }
          guard #available(macOS 14.2, *) else { return noErr }
          return makeOriginalAudioAudible()
        },
        stopIOProc: {
          if let teardownNativeCalls {
            return teardownNativeCalls.stopIOProc()
          }
          guard shouldStop, let procID = ioProcID else { return noErr }
          return AudioDeviceStop(aggregateDeviceID, procID)
        },
        restoreTapMuting: {
          if let teardownNativeCalls {
            return teardownNativeCalls.restoreTapMuting()
          }
          guard #available(macOS 14.2, *) else { return noErr }
          return restoreTapMuting()
        },
        deactivateRenderer: {
          stateBox.setInactive()
        }
      )

      if #available(macOS 14.2, *), tapID != .unknown {
        observations.append(
          CleanupStatusObservation(
            appID: appID,
            stage: .processTapReleaseMute,
            nativeStatus: preparation.tapMuteReleaseStatus,
            detail: "Release process tap mute before teardown"
          )
        )
      }
      if shouldStop, preparation.didAttemptIOProcStop {
        observations.append(
          CleanupStatusObservation(
            appID: appID,
            stage: .ioProcStop,
            nativeStatus: preparation.ioProcStopStatus,
            detail: "Stop controller IO proc"
          )
        )
      }
      if let degradation = preparation.cleanupDegradation(appID: appID) {
        observations.append(
          CleanupStatusObservation(
            appID: degradation.appID,
            stage: degradation.stage,
            nativeStatus: degradation.nativeStatus ?? preparation.tapMuteRestoreStatus ?? -1,
            detail: degradation.detail
          )
        )
      }
      guard preparation.canDestroyNativeResources else {
        return finish()
      }
      didStartIOProc = false
      drainCallbackQueue()

      // Each handle is forgotten only once its own destroy has SUCCEEDED, so a
      // retry re-attempts exactly the stages that failed and never re-destroys
      // one that already went away. Without this, a retry after (say) a failed
      // tap destroy would also destroy the aggregate device a second time — and
      // Core Audio reuses object IDs, so the second destroy could hit an
      // unrelated device.
      if let procID = ioProcID, aggregateDeviceID != .unknown {
        let destroyStatus =
          teardownNativeCalls?.destroyIOProc(aggregateDeviceID, procID)
          ?? AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        observations.append(
          CleanupStatusObservation(
            appID: appID,
            stage: .ioProcDestroy,
            nativeStatus: destroyStatus,
            detail: "Destroy controller IO proc"
          )
        )
        guard destroyStatus == noErr else { return finish() }
        ioProcID = nil
      } else {
        ioProcID = nil
      }

      if aggregateDeviceID != .unknown {
        let destroyStatus =
          teardownNativeCalls?.destroyAggregateDevice(aggregateDeviceID)
          ?? AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        observations.append(
          CleanupStatusObservation(
            appID: appID,
            stage: .aggregateDeviceDestroy,
            nativeStatus: destroyStatus,
            detail: "Destroy controller aggregate device"
          )
        )
        guard destroyStatus == noErr else { return finish() }
        aggregateDeviceID = .unknown
      }

      if #available(macOS 14.2, *), tapID != .unknown {
        let destroyStatus =
          teardownNativeCalls?.destroyProcessTap(tapID)
          ?? AudioHardwareDestroyProcessTap(tapID)
        observations.append(
          CleanupStatusObservation(
            appID: appID,
            stage: .processTapDestroy,
            nativeStatus: destroyStatus,
            detail: "Destroy controller process tap"
          )
        )
        if destroyStatus == noErr { tapID = .unknown }
      }

      return finish()
    }
  }

  deinit {
    _ = dispose()
  }

  // REALTIME_CALLBACK_AUDIT_BEGIN validatesCallbackGeometry
  private func validatesCallbackGeometry(
    _ inputData: UnsafePointer<AudioBufferList>?,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> Bool {
    guard let inputData else { return false }
    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
    let expectedBufferCount = audioFormatPlan.isInterleaved ? 1 : audioFormatPlan.channelCount
    guard inputBuffers.count == expectedBufferCount,
      outputBuffers.count == expectedBufferCount
    else {
      return false
    }

    var expectedByteCount: Int?
    for index in 0..<expectedBufferCount {
      let inputBuffer = inputBuffers[index]
      let outputBuffer = outputBuffers[index]
      let expectedChannels =
        audioFormatPlan.isInterleaved
        ? audioFormatPlan.channelCount
        : 1
      let inputByteCount = Int(inputBuffer.mDataByteSize)
      let outputByteCount = Int(outputBuffer.mDataByteSize)
      guard Int(inputBuffer.mNumberChannels) == expectedChannels,
        Int(outputBuffer.mNumberChannels) == expectedChannels,
        inputByteCount == outputByteCount,
        inputByteCount.isMultiple(of: audioFormatPlan.bytesPerFrame),
        inputByteCount == 0 || (inputBuffer.mData != nil && outputBuffer.mData != nil)
      else {
        return false
      }

      if let expectedByteCount {
        guard inputByteCount == expectedByteCount else { return false }
      } else {
        expectedByteCount = inputByteCount
      }
    }
    return true
  }
  // REALTIME_CALLBACK_AUDIT_END validatesCallbackGeometry

  // REALTIME_CALLBACK_AUDIT_BEGIN renderTappedAudio
  private func renderTappedAudio(
    _ inputData: UnsafePointer<AudioBufferList>?,
    to outputData: UnsafeMutablePointer<AudioBufferList>,
    volume: Float,
    volumeBoost: Float
  ) {
    guard let inputData else {
      zeroOutput(outputData)
      return
    }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

    var analysisSum: Float = 0
    var analysisSampleCount: UInt32 = 0
    var voiceEnergySum: Float = 0
    var voiceSampleCount: UInt32 = 0
    var finalPeak: Float = 0
    var finalSum: Float = 0
    var finalSampleCount: UInt32 = 0
    var channelOffset = 0

    let manualGain = volume * volumeBoost

    for index in outputBuffers.indices {
      let outputBuffer = outputBuffers[index]
      let bufferChannelCount = max(1, Int(outputBuffer.mNumberChannels))
      let currentChannelOffset = channelOffset
      channelOffset += bufferChannelCount
      guard let outputPointer = outputBuffer.mData else { continue }
      guard index < inputBuffers.count else {
        memset(outputPointer, 0, Int(outputBuffer.mDataByteSize))
        continue
      }

      let inputBuffer = inputBuffers[index]
      guard let inputPointer = inputBuffer.mData else {
        memset(outputPointer, 0, Int(outputBuffer.mDataByteSize))
        continue
      }

      let outputByteCount = Int(outputBuffer.mDataByteSize)
      let copyByteCount = min(Int(inputBuffer.mDataByteSize), outputByteCount)
      guard copyByteCount > 0 else { continue }

      memcpy(outputPointer, inputPointer, copyByteCount)
      if outputByteCount > copyByteCount {
        memset(outputPointer.advanced(by: copyByteCount), 0, outputByteCount - copyByteCount)
      }

      // Apply the combined compensation before either filter. EqualizerDSP
      // clamps typed samples to their valid range, so pre-attenuation is the
      // realtime-safe way to prevent stacked boosts from clipping internally.
      TapDSP.scale(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        gain: equalizerHeadroomGain
      )
      equalizerDSP.process(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        bufferChannelCount: bufferChannelCount,
        channelOffset: currentChannelOffset
      )
      managedAudioEqualizerDSP.process(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        bufferChannelCount: bufferChannelCount,
        channelOffset: currentChannelOffset
      )
      TapDSP.scale(
        outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        gain: manualGain
      )

      // Adaptive analysis observes the user's EQ and manual controls, but not
      // its own temporary correction, so it cannot chase itself.
      let (_, preAdaptiveSum, preAdaptiveSamples) = TapDSP.levels(
        from: outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat
      )
      analysisSum += preAdaptiveSum
      analysisSampleCount += preAdaptiveSamples
      let voice = voiceBandAnalyzer.analyze(
        UnsafeRawPointer(outputPointer),
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat,
        bufferChannelCount: bufferChannelCount,
        channelOffset: currentChannelOffset
      )
      voiceEnergySum += voice.energySum
      voiceSampleCount += voice.sampleCount

      TapDSP.scale(outputPointer, byteCount: copyByteCount, format: audioFormatPlan.sampleFormat, gain: adaptiveGain)

      let (bufferPeak, bufferSum, bufferSamples) = TapDSP.levels(
        from: outputPointer,
        byteCount: copyByteCount,
        format: audioFormatPlan.sampleFormat
      )
      finalPeak = max(finalPeak, bufferPeak)
      finalSum += bufferSum
      finalSampleCount += bufferSamples
    }

    let voiceBandEnergy =
      voiceSampleCount > 0
      ? voiceEnergySum / Float(voiceSampleCount)
      : 0
    stateBox.writeLevels(
      peakLevel: finalPeak,
      rmsLevel: TapDSP.rms(sum: finalSum, sampleCount: finalSampleCount),
      analysisRMS: TapDSP.rms(sum: analysisSum, sampleCount: analysisSampleCount),
      voiceBandEnergy: voiceBandEnergy.isFinite ? voiceBandEnergy : 0
    )
  }
  // REALTIME_CALLBACK_AUDIT_END renderTappedAudio

  // REALTIME_CALLBACK_AUDIT_BEGIN zeroOutput
  private func zeroOutput(_ outOutputData: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(outOutputData)
    for buffer in buffers {
      guard let data = buffer.mData else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
  }
  // REALTIME_CALLBACK_AUDIT_END zeroOutput

  private func drainCallbackQueue() {
    if DispatchQueue.getSpecific(key: callbackQueueKey) == callbackQueueToken {
      return
    }

    callbackQueue.sync {}
  }
}
