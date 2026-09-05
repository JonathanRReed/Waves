import AudioToolbox
import Foundation

struct AudioPropertyChanges: OptionSet, Sendable {
  let rawValue: UInt8

  static let defaultOutput = Self(rawValue: 1 << 0)
  static let deviceInventory = Self(rawValue: 1 << 1)
  static let routerObservation = Self(rawValue: 1 << 2)

  static func outputChanges(in addresses: UnsafeBufferPointer<AudioObjectPropertyAddress>) -> Self {
    var changes: Self = []
    for address in addresses {
      switch address.mSelector {
      case kAudioHardwarePropertyDefaultOutputDevice: changes.insert(.defaultOutput)
      case kAudioHardwarePropertyDevices: changes.insert(.deviceInventory)
      default: break
      }
      if changes == [.defaultOutput, .deviceInventory] { break }
    }
    return changes
  }

  var outputSelectors: [AudioObjectPropertySelector] {
    var selectors: [AudioObjectPropertySelector] = []
    if contains(.defaultOutput) { selectors.append(kAudioHardwarePropertyDefaultOutputDevice) }
    if contains(.deviceInventory) { selectors.append(kAudioHardwarePropertyDevices) }
    return selectors
  }
}

/// Property callbacks retain only a fixed set of dirty flags and one wakeup.
/// Flags are unioned independently of the wake stream so dropping redundant
/// wakeups cannot erase a default-output change behind an inventory event.
final class AudioPropertyChangeMailbox: @unchecked Sendable {
  let wakeups: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let lock = NSLock()
  private var pending: AudioPropertyChanges = []
  private var finished = false

  init() {
    (wakeups, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func enqueue(_ changes: AudioPropertyChanges) {
    guard !changes.isEmpty else { return }
    let shouldWake = lock.withLock {
      guard !finished else { return false }
      pending.formUnion(changes)
      return true
    }
    if shouldWake { continuation.yield() }
  }

  func takePending() -> AudioPropertyChanges {
    lock.withLock {
      let changes = pending
      pending = []
      return changes
    }
  }

  func finish() {
    lock.withLock {
      finished = true
      pending = []
    }
    continuation.finish()
  }
}
