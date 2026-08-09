import Observation

enum GuidedMixerTourMoment: Int, CaseIterable, Equatable, Sendable {
  case chooseSound
  case setLevel
  case muteAndRestore
  case goFurther

  var requiresAcceptedMixerIntent: Bool {
    switch self {
    case .setLevel, .muteAndRestore:
      true
    case .chooseSound, .goFurther:
      false
    }
  }
}

enum GuidedMixerTourState: Equatable, Sendable {
  case inactive
  case active(moment: GuidedMixerTourMoment, appID: String)
}

enum GuidedMixerTourTransition: Equatable, Sendable {
  case noChange
  case advanced(GuidedMixerTourMoment)
  case completed
}

enum GuidedMixerTourEndReason: Equatable, Sendable {
  case button
  case escape
  case notNow
}

enum GuidedMixerTourEvent: Equatable, Sendable {
  case acceptedIntent(appID: String, desiredVolume: Float, isMuted: Bool)
}

struct GuidedMixerTourLifecycleSnapshot: Equatable, Sendable {
  let trackedTaskCount: Int

  var isIdle: Bool { trackedTaskCount == 0 }
}

@Observable
@MainActor
final class GuidedMixerTourCoordinator {
  private(set) var state: GuidedMixerTourState = .inactive
  private(set) var targetDisplayName: String?
  private var originalVolume: Float?
  private var originalMuted: Bool?
  private var observedMuteChange = false

  var lifecycleSnapshot: GuidedMixerTourLifecycleSnapshot {
    GuidedMixerTourLifecycleSnapshot(trackedTaskCount: 0)
  }

  func start(
    appID: String,
    displayName: String? = nil,
    originalVolume: Float? = nil,
    originalMuted: Bool? = nil,
    at moment: GuidedMixerTourMoment = .chooseSound
  ) {
    targetDisplayName = displayName
    self.originalVolume = originalVolume
    self.originalMuted = originalMuted
    observedMuteChange = false
    state = .active(moment: moment, appID: appID)
  }

  func observe(_ event: GuidedMixerTourEvent) {
    guard case let .active(moment, targetAppID) = state else { return }
    guard case let .acceptedIntent(appID, desiredVolume, isMuted) = event,
      appID == targetAppID
    else { return }

    switch moment {
    case .setLevel:
      guard let originalVolume,
        abs(desiredVolume - originalVolume) > 0.005
      else { return }
      state = .active(moment: .muteAndRestore, appID: targetAppID)

    case .muteAndRestore:
      guard let originalMuted else { return }
      if isMuted != originalMuted {
        observedMuteChange = true
      } else if observedMuteChange {
        state = .active(moment: .goFurther, appID: targetAppID)
      }

    case .chooseSound, .goFurther:
      break
    }
  }

  @discardableResult
  func advance() -> GuidedMixerTourTransition {
    guard case let .active(moment, appID) = state else { return .noChange }
    let moments = GuidedMixerTourMoment.allCases
    guard let index = moments.firstIndex(of: moment) else { return .noChange }
    let nextIndex = moments.index(after: index)
    guard nextIndex < moments.endIndex else {
      resetObservedState()
      state = .inactive
      return .completed
    }
    let nextMoment = moments[nextIndex]
    state = .active(moment: nextMoment, appID: appID)
    return .advanced(nextMoment)
  }

  @discardableResult
  func back() -> Bool {
    guard case let .active(moment, appID) = state else { return false }
    let moments = GuidedMixerTourMoment.allCases
    guard let index = moments.firstIndex(of: moment), index > moments.startIndex else {
      return false
    }
    state = .active(moment: moments[moments.index(before: index)], appID: appID)
    return true
  }

  @discardableResult
  func end(reason _: GuidedMixerTourEndReason) -> Bool {
    guard state != .inactive else { return false }
    resetObservedState()
    state = .inactive
    return true
  }

  private func resetObservedState() {
    targetDisplayName = nil
    originalVolume = nil
    originalMuted = nil
    observedMuteChange = false
  }
}
