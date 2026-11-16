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

/// Runs a cleanup once, memoizing its result — including a failed one.
///
/// This is what makes repeated shutdown requests safe: the second call returns
/// the same rows without repeating destructive native teardown. A retry after a
/// failure is a *deliberate* act, not something that should fall out of calling
/// `dispose()` twice — see `reset()` and the backend's parked-controller
/// retry, driven from route maintenance.
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

  /// Clears the memo so the next `run` executes again. Only for an explicit
  /// retry of a teardown that previously failed.
  func reset() {
    lock.lock()
    result = nil
    lock.unlock()
  }
}
