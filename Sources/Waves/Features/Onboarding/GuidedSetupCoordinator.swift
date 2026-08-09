import Foundation
import Observation
import WavesAudioCore

struct GuidedSetupFacts: Equatable, Sendable {
  var hasAcceptedPrivacy: Bool
  var captureAuthorization: CaptureAuthorizationResult?
  var audioComponentInstalled: Bool
  var outputDeviceVisible: Bool
  var routeHealthReady: Bool
  var isAudioRunning: Bool

  static let empty = GuidedSetupFacts(
    hasAcceptedPrivacy: false,
    captureAuthorization: nil,
    audioComponentInstalled: false,
    outputDeviceVisible: false,
    routeHealthReady: false,
    isAudioRunning: false
  )

  var isReadyForCoreMixing: Bool {
    hasAcceptedPrivacy
      && captureAuthorization == .authorized
      && audioComponentInstalled
      && outputDeviceVisible
      && isAudioRunning
  }
}

enum RequiredReadinessIssueID: Equatable, Sendable {
  case audioStartup
  case managedAudioSupport
  case audioCapture
  case outputDevice
  case managedRoutes
}

enum RequiredReadinessSeverity: Equatable, Sendable {
  case blocking
  case warning
}

enum GuidedSetupRepairAction: Equatable, Sendable {
  case recheck
  case openCaptureSettings
  case openSoundSettings
  case recoverRoutes
}

struct RequiredReadinessIssue: Equatable, Identifiable, Sendable {
  let id: RequiredReadinessIssueID
  let title: String
  let detail: String
  let severity: RequiredReadinessSeverity
  let repairAction: GuidedSetupRepairAction?

  var continuationLabel: String? {
    severity == .warning ? "You can continue" : nil
  }
}

struct GuidedSetupActions {
  let acceptPrivacyAndStart: @MainActor () async -> Void
  let currentFacts: @MainActor () -> GuidedSetupFacts
  let refreshDiagnostics: @MainActor () -> Void
}

@Observable
@MainActor
final class GuidedSetupCoordinator {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private(set) var phase: GuidedSetupPhase
  private(set) var facts = GuidedSetupFacts.empty
  private let readinessStabilityInterval: Duration
  private let sleep: Sleep
  private var activeStabilityToken: UUID?
  private var tasks: [UUID: Task<Void, Never>] = [:]

  init(
    initialPhase: GuidedSetupPhase = .welcome,
    readinessStabilityInterval: Duration = .milliseconds(350),
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    phase = initialPhase
    self.readinessStabilityInterval = readinessStabilityInterval
    self.sleep = sleep
  }

  var trackedTaskCount: Int { tasks.count }

  var issues: [RequiredReadinessIssue] {
    Self.readinessIssues(for: facts)
  }

  func update(facts: GuidedSetupFacts) {
    self.facts = facts

    if phase == .waitingForMacOS, facts.hasAcceptedPrivacy {
      phase = .readiness
    }

    reconcileStableReadiness()
  }

  func performPrimaryAction(using actions: GuidedSetupActions) async {
    switch phase {
    case .welcome:
      phase = facts.hasAcceptedPrivacy ? .readiness : .permissionPreflight
      reconcileStableReadiness()
    case .permissionPreflight:
      phase = .waitingForMacOS
      await actions.acceptPrivacyAndStart()
      update(facts: actions.currentFacts())
      if !facts.hasAcceptedPrivacy {
        phase = .permissionPreflight
      }
    case .waitingForMacOS:
      update(facts: actions.currentFacts())
    case .readiness:
      reconcileStableReadiness()
    case .ready:
      break
    }
  }

  func performRepair(
    _ action: GuidedSetupRepairAction,
    using actions: GuidedSetupActions
  ) async {
    guard action == .recheck else { return }
    await actions.acceptPrivacyAndStart()
    actions.refreshDiagnostics()
    update(facts: actions.currentFacts())
  }

  func cancel() {
    cancelStableAdvance()
  }

  func drain() async {
    while !tasks.isEmpty {
      let pending = Array(tasks.values)
      for task in pending { await task.value }
    }
  }

  private func reconcileStableReadiness() {
    guard phase == .readiness, facts.isReadyForCoreMixing else {
      cancelStableAdvance()
      return
    }
    scheduleStableAdvanceIfNeeded()
  }

  private func scheduleStableAdvanceIfNeeded() {
    guard activeStabilityToken == nil else { return }
    let token = UUID()
    activeStabilityToken = token
    let sleep = sleep
    let interval = readinessStabilityInterval
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await sleep(interval)
      } catch {
        finishTask(token: token)
        return
      }
      guard !Task.isCancelled,
        activeStabilityToken == token,
        phase == .readiness,
        facts.isReadyForCoreMixing
      else {
        finishTask(token: token)
        return
      }
      activeStabilityToken = nil
      phase = .ready
      finishTask(token: token)
    }
    tasks[token] = task
  }

  private func cancelStableAdvance() {
    guard let activeStabilityToken else { return }
    tasks[activeStabilityToken]?.cancel()
    self.activeStabilityToken = nil
  }

  private func finishTask(token: UUID) {
    tasks.removeValue(forKey: token)
    if activeStabilityToken == token {
      activeStabilityToken = nil
    }
  }

  private static func readinessIssues(for facts: GuidedSetupFacts) -> [RequiredReadinessIssue] {
    var result: [RequiredReadinessIssue] = []

    if !facts.isAudioRunning {
      result.append(
        RequiredReadinessIssue(
          id: .audioStartup,
          title: "Waves is still starting",
          detail: "Wait for the managed-audio service to finish starting, then check again.",
          severity: .blocking,
          repairAction: .recheck
        )
      )
    }

    if !facts.audioComponentInstalled {
      result.append(
        RequiredReadinessIssue(
          id: .managedAudioSupport,
          title: "Managed audio support is not ready",
          detail: "Waves has not confirmed the Core Audio process-tap path on this Mac.",
          severity: .blocking,
          repairAction: .recheck
        )
      )
    }

    if facts.captureAuthorization != .authorized {
      let action: GuidedSetupRepairAction? =
        facts.captureAuthorization == .notGranted ? .openCaptureSettings : .recheck
      result.append(
        RequiredReadinessIssue(
          id: .audioCapture,
          title: "Audio Capture access needs attention",
          detail: captureDetail(for: facts.captureAuthorization),
          severity: .blocking,
          repairAction: action
        )
      )
    }

    if !facts.outputDeviceVisible {
      result.append(
        RequiredReadinessIssue(
          id: .outputDevice,
          title: "Choose an audio output",
          detail: "Connect or select speakers or headphones in System Settings, then return to Waves.",
          severity: .blocking,
          repairAction: .openSoundSettings
        )
      )
    }

    if !facts.routeHealthReady {
      result.append(
        RequiredReadinessIssue(
          id: .managedRoutes,
          title: "Managed routes need repair",
          detail: "Waves can open the mixer now, or rebuild managed routes before you continue.",
          severity: .warning,
          repairAction: .recoverRoutes
        )
      )
    }

    return result
  }

  private static func captureDetail(
    for authorization: CaptureAuthorizationResult?
  ) -> String {
    switch authorization {
    case .authorized:
      "Audio Capture access is ready."
    case .notGranted:
      "Enable Waves under Privacy & Security, then return here."
    case .undetermined, nil:
      "macOS has not returned an Audio Capture decision yet."
    case .probeFailed(let status):
      "The Audio Capture check failed with status \(status). Check again before changing settings."
    case .unsupported:
      "This macOS version does not provide the Audio Capture authorization Waves requires."
    }
  }
}
