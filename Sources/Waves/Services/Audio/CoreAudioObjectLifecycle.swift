import AudioToolbox
import Foundation

enum ProcessTapAggregatePolicy {
  /// `true` makes AudioDeviceStart wait until the target emits its first audio.
  /// Waves starts an explicit IO proc, so waiting only blocks route creation.
  static let autoStartEnabled = false
}

/// What a Core Audio property read on a specific object actually means.
///
/// Core Audio hands out object IDs that can stop being valid at any instant: an
/// app quits, a browser helper exits, a device is unplugged — all between the
/// moment Waves enumerates the object list and the moment it reads a property
/// off one of those objects. Core Audio reports that as
/// `kAudioHardwareBadObjectError` (`'!obj'`, 560947818).
///
/// That is ordinary lifecycle, not a fault. Through 1.3.0 every non-`noErr`
/// status was logged at warning level, so routine app churn produced a warning
/// storm — 34 of them in a single audit window — that buried the failures which
/// genuinely need attention (permission problems, malformed property sizes,
/// device faults). Classifying the status keeps those visible while treating a
/// vanished object as the non-event it is.
enum CoreAudioObjectReadOutcome: Equatable, Sendable {
  /// The read succeeded.
  case ok
  /// The object no longer exists. Skip it; the next enumeration pass will have
  /// an accurate list. Never retry the same ID — it cannot come back.
  case objectDisappeared
  /// A real failure worth surfacing.
  case failed(OSStatus)

  init(_ status: OSStatus) {
    switch status {
    case noErr: self = .ok
    case kAudioHardwareBadObjectError: self = .objectDisappeared
    default: self = .failed(status)
    }
  }

  var isObjectDisappeared: Bool { self == .objectDisappeared }
}

/// Counts objects that vanished mid-enumeration so one pass reports one summary
/// line instead of one warning per object, and so the same object cannot be
/// reported twice within a pass.
struct StaleAudioObjectTally {
  private(set) var objectIDs: Set<AudioObjectID> = []

  var count: Int { objectIDs.count }
  var isEmpty: Bool { objectIDs.isEmpty }

  /// Returns true the first time a given object is recorded in this pass.
  @discardableResult
  mutating func record(_ objectID: AudioObjectID) -> Bool {
    objectIDs.insert(objectID).inserted
  }
}
