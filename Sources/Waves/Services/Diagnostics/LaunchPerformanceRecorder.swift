import Foundation
import OSLog

enum LaunchMilestone: String, CaseIterable, Sendable {
  case processInit
  case storeReady
  case firstFrame
  case backendStarted
  case snapshotReady
  case restoredRoutesReady
  case firstControlSubmitted
  case firstControlConfirmed
  case dockSettledObservation

  var outputName: String {
    switch self {
    case .processInit: "ProcessInit"
    case .storeReady: "StoreReady"
    case .firstFrame: "MainWindowViewAppeared"
    case .backendStarted: "BackendStarted"
    case .snapshotReady: "SnapshotReady"
    case .restoredRoutesReady: "RestoredRoutesReady"
    case .firstControlSubmitted: "FirstControlSubmitted"
    case .firstControlConfirmed: "FirstControlConfirmed"
    case .dockSettledObservation: "DockSettledObservation"
    }
  }
}

struct LaunchPerformanceSample: Equatable, Sendable {
  let milestone: LaunchMilestone
  let elapsed: Duration
}

struct LaunchTelemetryEvent: Equatable, Sendable {
  let name: String
  let elapsedNanoseconds: Int64

  var payload: String { "elapsedNs=\(elapsedNanoseconds)" }
}

@MainActor
final class LaunchPerformanceRecorder {
  private struct ControlTransaction: Equatable {
    let appID: String
    let generation: UInt64
    let submittedAt: ContinuousClock.Instant
  }

  private(set) static var active: LaunchPerformanceRecorder?

  private let clock = ContinuousClock()
  private let origin: ContinuousClock.Instant
  private let signposter: OSSignposter?
  private let emitEvent: (LaunchMilestone, LaunchTelemetryEvent) -> Void
  private var samples: [LaunchMilestone: LaunchPerformanceSample] = [:]
  private var launchInterval: OSSignpostIntervalState?
  private var pendingControl: ControlTransaction?
  private var controlInterval: OSSignpostIntervalState?

  init(
    signpostsEnabled: Bool = true,
    eventSink: ((LaunchTelemetryEvent) -> Void)? = nil
  ) {
    origin = clock.now
    let signposter: OSSignposter?
    if signpostsEnabled {
      signposter = OSSignposter(
        logger: Logger(
          subsystem: Bundle.main.bundleIdentifier ?? "com.jonathanreed.Waves",
          category: "LaunchPerformance"
        )
      )
    } else {
      signposter = nil
    }
    self.signposter = signposter
    if let eventSink {
      emitEvent = { _, event in eventSink(event) }
    } else if let signposter {
      emitEvent = { milestone, event in
        Self.emitFixedSignpost(
          signposter: signposter,
          for: milestone,
          elapsedNanoseconds: event.elapsedNanoseconds
        )
      }
    } else {
      emitEvent = { _, _ in }
    }
    launchInterval = signposter?.beginInterval("LaunchToRestoredRoutesReady")
  }

  static func activateLive() -> LaunchPerformanceRecorder {
    if let active { return active }
    let recorder = LaunchPerformanceRecorder()
    active = recorder
    recorder.mark(.processInit)
    return recorder
  }

  var snapshot: [LaunchPerformanceSample] {
    samples.values.sorted {
      if $0.elapsed == $1.elapsed {
        return LaunchMilestone.allCases.firstIndex(of: $0.milestone)!
          < LaunchMilestone.allCases.firstIndex(of: $1.milestone)!
      }
      return $0.elapsed < $1.elapsed
    }
  }

  var snapshotDescription: String {
    snapshot.map { "\($0.milestone.outputName)=\(nanoseconds($0.elapsed))" }
      .joined(separator: "\n")
  }

  func mark(_ milestone: LaunchMilestone) {
    record(milestone, at: clock.now)
  }

  func controlSubmitted(appID: String, generation: UInt64) {
    guard samples[.firstControlSubmitted] == nil, pendingControl == nil else { return }
    let submittedAt = clock.now
    pendingControl = ControlTransaction(appID: appID, generation: generation, submittedAt: submittedAt)
    record(.firstControlSubmitted, at: submittedAt)
    if let signposter {
      controlInterval = signposter.beginInterval("FirstControlConfirmation")
    }
  }

  func controlFinished(appID: String, generation: UInt64, confirmed: Bool) {
    guard let pendingControl,
      pendingControl.appID == appID,
      pendingControl.generation == generation
    else { return }

    defer {
      self.pendingControl = nil
      controlInterval = nil
    }
    if let signposter, let controlInterval {
      signposter.endInterval("FirstControlConfirmation", controlInterval)
    }
    guard confirmed else { return }
    record(.firstControlConfirmed, at: clock.now)
  }

  private func record(_ milestone: LaunchMilestone, at instant: ContinuousClock.Instant) {
    guard samples[milestone] == nil else { return }
    let sample = LaunchPerformanceSample(
      milestone: milestone,
      elapsed: origin.duration(to: instant)
    )
    samples[milestone] = sample
    let event = LaunchTelemetryEvent(
      name: milestone.outputName,
      elapsedNanoseconds: nanoseconds(sample.elapsed)
    )
    emitEvent(milestone, event)
    if milestone == .restoredRoutesReady, let signposter, let launchInterval {
      signposter.endInterval("LaunchToRestoredRoutesReady", launchInterval)
      self.launchInterval = nil
    }
  }

  private static func emitFixedSignpost(
    signposter: OSSignposter,
    for milestone: LaunchMilestone,
    elapsedNanoseconds: Int64
  ) {
    switch milestone {
    case .processInit:
      signposter.emitEvent("ProcessInit", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .storeReady:
      signposter.emitEvent("StoreReady", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .firstFrame:
      signposter.emitEvent("MainWindowViewAppeared", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .backendStarted:
      signposter.emitEvent("BackendStarted", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .snapshotReady:
      signposter.emitEvent("SnapshotReady", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .restoredRoutesReady:
      signposter.emitEvent("RestoredRoutesReady", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .firstControlSubmitted:
      signposter.emitEvent("FirstControlSubmitted", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .firstControlConfirmed:
      signposter.emitEvent("FirstControlConfirmed", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    case .dockSettledObservation:
      signposter.emitEvent("DockSettledObservation", "elapsedNs=\(elapsedNanoseconds, privacy: .public)")
    }
  }

  private func nanoseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000_000_000
      + components.attoseconds / 1_000_000_000
  }
}
