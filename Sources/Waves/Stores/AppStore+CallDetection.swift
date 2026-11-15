import AppKit
import Foundation
import WavesAudioCore

// MARK: - Call detection: what "you're on a call" means for muting media

/// How Waves decides a call is in progress for "Mute media during calls".
enum CallDetectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
  /// A conferencing app is the frontmost app. The behavior through 1.7.
  case frontmostCallApp
  /// An app the user chose is running microphone input, wherever it is.
  case microphoneInUse

  var id: Self { self }

  var displayName: String {
    switch self {
    case .frontmostCallApp: "When a call app is in front"
    case .microphoneInUse: "When a chosen app is using the microphone"
    }
  }
}

/// The microphone-mode call state. Session-only; nothing here is persisted.
struct MicrophoneCallState {
  /// Debounced: true from the first capture by a chosen app until capture has
  /// stayed stopped for the hold.
  var isActive = false
  /// Chosen apps seen capturing, kept through the hold for diagnostics.
  var appIDs: [String] = []
  /// The state the last automatic pass acted on, so passes act only on edges.
  var lastApplied: Bool?
  var endHoldTask: Task<Void, Never>?
}

/// What the diagnostics export shows while microphone detection is on.
struct CallDetectionDiagnostics: Equatable, Sendable {
  var isDetected: Bool
  var appNames: [String]
}

enum CallDetectionPolicy {
  /// How long capture must stay stopped before media is unmuted. Long enough to
  /// ride over the input stream briefly closing while a call app switches
  /// microphones or renegotiates audio (typically well under a second), short
  /// enough that media is back about as fast as the "unmuted" notice appears.
  static let callEndHold = Duration.seconds(2)

  /// Call apps Waves knows by bundle ID, offered when they are installed even
  /// if they have not played sound yet. Each one infers as a conferencing or
  /// communication app (see `AppDiscoveryPolicy.inferCategory`).
  static let knownCallAppBundleIDs = [
    "us.zoom.xos",
    "com.microsoft.teams2",
    "com.microsoft.teams",
    "com.apple.FaceTime",
    "com.cisco.webexmeetingsapp",
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
  ]

  /// The starting list for microphone mode: call apps Waves has seen, then the
  /// known call apps that are installed. Order is kept, duplicates dropped.
  static func suggestedCallAppIDs(
    seenApps: [AudioApp],
    isInstalled: (String) -> Bool
  ) -> [String] {
    let seen = seenApps
      .filter { $0.category == .conferencing || $0.category == .communication }
      .map(\.logicalID)
    var result: [String] = []
    for id in seen + knownCallAppBundleIDs.filter(isInstalled) where !result.contains(id) {
      result.append(id)
    }
    return result
  }

  /// The chosen apps that are capturing, in the order the user listed them.
  ///
  /// A capture belongs to a chosen app when it comes from that app's own
  /// process, or from a helper inside that app's bundle (resolved to the
  /// outermost `.app` the same way the backend resolves routing helpers), or
  /// when Core Audio reports a helper bundle ID in the app's bundle family.
  static func callingAppIDs(
    captures: [MicrophoneCaptureProcess],
    chosenAppIDs: [String],
    apps: [AudioApp]
  ) -> [String] {
    guard !captures.isEmpty, !chosenAppIDs.isEmpty else { return [] }
    var capturing = Set<String>()
    for capture in captures {
      for app in apps where app.pid == capture.pid
        || (capture.owningAppBundlePath != nil
          && app.runtimeIdentity?.outerBundlePath == capture.owningAppBundlePath)
      {
        capturing.insert(app.logicalID)
      }
      if let owningID = capture.owningAppBundleID {
        capturing.insert(owningID)
      }
      if let reported = capture.reportedBundleID {
        for id in chosenAppIDs
        where AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: id, candidateBundleID: reported) {
          capturing.insert(id)
        }
      }
    }
    return chosenAppIDs.filter(capturing.contains)
  }
}

extension AppStore {
  /// The chosen call apps for microphone mode, or empty before the user first
  /// picks that mode.
  var callDetectionAppIDs: [String] {
    preferences.callDetectionAppIDs ?? []
  }

  func setCallDetectionMode(_ mode: CallDetectionMode) {
    guard requireAudioRunning() else { return }
    guard preferences.callDetectionMode != mode else { return }
    preferences.callDetectionMode = mode
    if mode == .microphoneInUse, preferences.callDetectionAppIDs == nil {
      preferences.callDetectionAppIDs = CallDetectionPolicy.suggestedCallAppIDs(
        seenApps: session.apps,
        isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
      )
    }
    persistPreferences()
    // The new mode decides afresh. If it sees no call, the automatic mutes the
    // old mode made are released; if it does, they stay, with no unmute flicker.
    previousFrontmostApp = nil
    microphoneCall.lastApplied = nil
    checkAutoPauseMusic()
  }

  func setCallDetectionApp(_ appID: String, isChosen: Bool) {
    guard requireAudioRunning() else { return }
    var ids = callDetectionAppIDs
    if isChosen {
      guard !ids.contains(appID) else { return }
      ids.append(appID)
    } else {
      guard ids.contains(appID) else { return }
      ids.removeAll { $0 == appID }
    }
    preferences.callDetectionAppIDs = ids
    persistPreferences()
    microphoneActivityChanged()
  }

  /// Starts the microphone monitor only while microphone mode is on and audio
  /// is running, and stops it (dropping any call state) otherwise. Called at
  /// the top of every automatic pass, so every path that changes the toggle,
  /// the mode, or Adaptive Mix lands here.
  func syncMicrophoneCallMonitoring() {
    let shouldMonitor =
      startupState == .running
      && preferences.autoPauseMusicForConferencing
      && preferences.callDetectionMode == .microphoneInUse
    if shouldMonitor {
      guard !microphoneActivityMonitor.isRunning else { return }
      microphoneActivityMonitor.start { [weak self] in
        self?.microphoneActivityChanged()
      }
      _ = updateMicrophoneCall(holdExpired: false)
    } else {
      microphoneActivityMonitor.stop()
      microphoneCall.endHoldTask?.cancel()
      microphoneCall = MicrophoneCallState()
    }
  }

  func microphoneActivityChanged() {
    guard startupState == .running, microphoneActivityMonitor.isRunning else { return }
    if updateMicrophoneCall(holdExpired: false) {
      checkAutoPauseMusic()
    }
  }

  /// Folds the monitor's current reading into `microphoneCall`. Returns true
  /// when the debounced call state changed. A call starts at once; it ends only
  /// after capture has stayed stopped for the hold.
  private func updateMicrophoneCall(holdExpired: Bool) -> Bool {
    let calling = CallDetectionPolicy.callingAppIDs(
      captures: microphoneActivityMonitor.capturingProcesses(),
      chosenAppIDs: callDetectionAppIDs,
      apps: session.apps
    )
    if !calling.isEmpty {
      microphoneCall.endHoldTask?.cancel()
      microphoneCall.endHoldTask = nil
      microphoneCall.appIDs = calling
      guard !microphoneCall.isActive else { return false }
      microphoneCall.isActive = true
      return true
    }
    guard microphoneCall.isActive else { return false }
    if holdExpired {
      microphoneCall.isActive = false
      microphoneCall.appIDs = []
      return true
    }
    guard microphoneCall.endHoldTask == nil else { return false }
    let sleep = callEndHoldSleep
    microphoneCall.endHoldTask = Task { @MainActor [weak self] in
      do { try await sleep(CallDetectionPolicy.callEndHold) } catch { return }
      guard !Task.isCancelled, let self else { return }
      self.microphoneCall.endHoldTask = nil
      guard self.startupState == .running, self.microphoneActivityMonitor.isRunning else { return }
      if self.updateMicrophoneCall(holdExpired: true) {
        self.checkAutoPauseMusic()
      }
    }
    return false
  }

  /// Present only while microphone detection is on, so the export says nothing
  /// about the microphone for anyone who never opted in.
  var callDetectionDiagnostics: CallDetectionDiagnostics? {
    guard preferences.autoPauseMusicForConferencing,
      preferences.callDetectionMode == .microphoneInUse
    else { return nil }
    return CallDetectionDiagnostics(
      isDetected: microphoneCall.isActive,
      appNames: microphoneCall.isActive
        ? microphoneCall.appIDs.map { FriendlyAppName.resolve($0, in: session.apps) }
        : []
    )
  }

  /// Waits until every owned operation, including automatic passes, finishes.
  func drainOwnedOperations() async {
    while let task = ownedOperationTasks.values.first {
      await task.value
    }
  }
}
