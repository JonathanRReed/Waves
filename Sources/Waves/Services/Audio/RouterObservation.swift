import AudioToolbox
import Foundation
import WavesAudioCore

enum RouterConflictObservationAction: Equatable, Sendable {
  case none
  case conflictActivated
  case conflictReleased
}

struct RouterConflictObservationDebouncer: Sendable {
  private let debounce: Duration
  private var appliedState: Bool?
  private var pendingState: Bool?
  private var pendingSince: Duration?

  init(debounce: Duration = .milliseconds(250)) {
    self.debounce = debounce
  }

  mutating func observe(conflictIsActive: Bool, at now: Duration) -> RouterConflictObservationAction {
    if pendingState != conflictIsActive {
      pendingState = conflictIsActive
      pendingSince = now
    }
    return advance(to: now)
  }

  mutating func advance(to now: Duration) -> RouterConflictObservationAction {
    guard let pendingState, let pendingSince, now - pendingSince >= debounce else { return .none }
    self.pendingState = nil
    self.pendingSince = nil
    guard appliedState != pendingState else { return .none }
    appliedState = pendingState
    return pendingState ? .conflictActivated : .conflictReleased
  }
}

final class RouterObservationListenerBlockReference: @unchecked Sendable {
  let block: AudioObjectPropertyListenerBlock

  init(_ block: @escaping AudioObjectPropertyListenerBlock) {
    self.block = block
  }
}

struct RouterObservationListenerNativeCalls {
  let add: @Sendable (AudioObjectPropertySelector, RouterObservationListenerBlockReference) -> OSStatus
  let remove: @Sendable (AudioObjectPropertySelector, RouterObservationListenerBlockReference) -> OSStatus

  static func live(on queue: DispatchQueue) -> Self {
    Self(
      add: { selector, listener in
        var address = AudioObjectPropertyAddress(
          mSelector: selector,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectAddPropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &address, queue, listener.block
        )
      },
      remove: { selector, listener in
        var address = AudioObjectPropertyAddress(
          mSelector: selector,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &address, queue, listener.block
        )
      }
    )
  }
}

final class RouterObservationListenerLifecycle: @unchecked Sendable {
  private static let selectors = [
    kAudioHardwarePropertyProcessObjectList,
    kAudioHardwarePropertyTapList,
  ]

  private let nativeCalls: RouterObservationListenerNativeCalls
  private let fallbackInterval: Int
  private var listener: RouterObservationListenerBlockReference?
  private(set) var installedSelectors: [AudioObjectPropertySelector] = []
  private var fallbackTicks = 0

  init(nativeCalls: RouterObservationListenerNativeCalls, fallbackInterval: Int = 4) {
    self.nativeCalls = nativeCalls
    self.fallbackInterval = max(1, fallbackInterval)
  }

  var requiresFallbackReobservation: Bool {
    installedSelectors.count != Self.selectors.count
  }

  var installedSelectorCount: Int { installedSelectors.count }

  func install(onObservedChange: @escaping @Sendable () -> Void) -> [CleanupDegradation] {
    if listener == nil {
      listener = RouterObservationListenerBlockReference { count, addresses in
        let observed = (0..<Int(count)).contains { index in
          Self.selectors.contains(addresses[index].mSelector)
        }
        guard observed else { return }
        onObservedChange()
      }
    }
    guard let listener else { return [] }

    var degradations: [CleanupDegradation] = []
    for selector in Self.selectors where !installedSelectors.contains(selector) {
      let status = nativeCalls.add(selector, listener)
      if status == noErr {
        installedSelectors.append(selector)
      } else {
        degradations.append(
          CleanupDegradation(
            stage: .listenerInstallation,
            nativeStatus: status,
            detail: "Add router observation listener selector \(selector)"
          ))
      }
    }
    return degradations
  }

  func consumeFallbackReobservationTick() -> Bool {
    guard requiresFallbackReobservation else {
      fallbackTicks = 0
      return false
    }
    fallbackTicks += 1
    guard fallbackTicks >= fallbackInterval else { return false }
    fallbackTicks = 0
    return true
  }

  func remove() -> [CleanupDegradation] {
    guard let listener else { return [] }
    let degradations = installedSelectors.compactMap { selector -> CleanupDegradation? in
      let status = nativeCalls.remove(selector, listener)
      guard status != noErr else { return nil }
      return CleanupDegradation(
        stage: .listenerRemoval,
        nativeStatus: status,
        detail: "Remove router observation listener selector \(selector)"
      )
    }
    installedSelectors.removeAll()
    self.listener = nil
    fallbackTicks = 0
    return degradations
  }
}
