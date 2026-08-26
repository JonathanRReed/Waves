import AudioToolbox
import Foundation
import WavesAudioCore

struct CleanupStatusObservation: Hashable, Sendable {
  let appID: String?
  let stage: CleanupStage
  let nativeStatus: Int32
  let detail: String?

  init(
    appID: String? = nil,
    stage: CleanupStage,
    nativeStatus: Int32,
    detail: String? = nil
  ) {
    self.appID = appID
    self.stage = stage
    self.nativeStatus = nativeStatus
    self.detail = detail
  }
}

func checkedCleanupDegradations(
  from observations: [CleanupStatusObservation]
) -> [CleanupDegradation] {
  observations.compactMap { observation in
    guard observation.nativeStatus != noErr else { return nil }
    return CleanupDegradation(
      appID: observation.appID,
      stage: observation.stage,
      nativeStatus: observation.nativeStatus,
      detail: observation.detail
    )
  }
}

struct MutingTapTeardownPreparationResult: Equatable, Sendable {
  let tapMuteReleaseStatus: OSStatus
  let ioProcStopStatus: OSStatus
  let tapMuteRestoreStatus: OSStatus?
  let didAttemptIOProcStop: Bool

  enum AudiblePath: Equatable, Sendable {
    case originalHardware
    case wavesRenderer
    case uncertain
  }

  /// Native resources are safe to destroy only after Core Audio confirms that
  /// the IO proc stopped. An unmuted tap is fail-open for sound, but a failed
  /// stop can still deliver a late callback and therefore cannot be destroyed.
  var canDestroyNativeResources: Bool {
    tapMuteReleaseStatus == noErr && didAttemptIOProcStop && ioProcStopStatus == noErr
  }

  var keepsRendererAndCallbackResourcesAlive: Bool { !canDestroyNativeResources }

  var audiblePath: AudiblePath {
    if canDestroyNativeResources { return .originalHardware }
    if ioProcStopStatus != noErr, tapMuteRestoreStatus == noErr { return .wavesRenderer }
    return .uncertain
  }

  var criticalDiagnostic: String? {
    guard ioProcStopStatus != noErr, let tapMuteRestoreStatus, tapMuteRestoreStatus != noErr else {
      return nil
    }
    return "Renderer stop failed and tap mute rollback failed. Waves retained callback resources because the audible path is uncertain."
  }

  func cleanupDegradation(appID: String) -> CleanupDegradation? {
    guard let criticalDiagnostic else { return nil }
    return CleanupDegradation(
      appID: appID,
      stage: .controllerDisposal,
      nativeStatus: tapMuteRestoreStatus,
      detail: criticalDiagnostic
    )
  }

  /// Either an unmuted tap or a stopped reader restores the process's original
  /// hardware playback path.
  var originalAudioIsFailOpen: Bool {
    audiblePath == .originalHardware
  }
}

/// Makes a `.mutedWhenTapped` route fail open before its renderer is disabled.
///
/// The order is part of the safety contract. If both native calls fail, the
/// renderer stays live so the muting tap cannot strand the target app in
/// silence. A successful mute-property write may still be applied by HAL
/// asynchronously, so the renderer is deactivated only after stop succeeds.
enum MutingTapTeardownPreparation {
  static func perform(
    makeOriginalAudioAudible: () -> OSStatus,
    stopIOProc: () -> OSStatus,
    restoreTapMuting: () -> OSStatus,
    deactivateRenderer: () -> Void
  ) -> MutingTapTeardownPreparationResult {
    let muteReleaseStatus = makeOriginalAudioAudible()
    guard muteReleaseStatus == noErr else {
      return MutingTapTeardownPreparationResult(
        tapMuteReleaseStatus: muteReleaseStatus,
        ioProcStopStatus: noErr,
        tapMuteRestoreStatus: nil,
        didAttemptIOProcStop: false
      )
    }
    let stopStatus = stopIOProc()
    if stopStatus == noErr {
      deactivateRenderer()
      return MutingTapTeardownPreparationResult(
        tapMuteReleaseStatus: muteReleaseStatus,
        ioProcStopStatus: stopStatus,
        tapMuteRestoreStatus: nil,
        didAttemptIOProcStop: true
      )
    }
    return MutingTapTeardownPreparationResult(
      tapMuteReleaseStatus: muteReleaseStatus,
      ioProcStopStatus: stopStatus,
      tapMuteRestoreStatus: restoreTapMuting(),
      didAttemptIOProcStop: true
    )
  }
}

/// Runs a cleanup once, memoizing its result — including a failed one.
///
/// This is what makes repeated shutdown requests safe: the second call returns
/// the same rows without repeating destructive native teardown. A retry after a
/// failure is a *deliberate* act, not something that should fall out of calling
/// `dispose()` twice — see `reset()` and the backend's orphaned-controller
/// retry, which is bounded and driven from route maintenance.
final class IdempotentCleanupResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: [CleanupDegradation]?

  func run(_ cleanup: () -> [CleanupDegradation]) -> [CleanupDegradation] {
    lock.lock()
    defer { lock.unlock() }
    if let result { return result }
    let result = cleanup()
    self.result = result
    return result
  }

  /// Clears the memo so the next `run` executes again. Only for an explicit,
  /// bounded retry of a teardown that previously failed.
  func reset() {
    lock.lock()
    result = nil
    lock.unlock()
  }
}
