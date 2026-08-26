import AppKit
import Foundation
import WavesAudioCore

// MARK: - AppStore value models
//
// Presentation and lifecycle value types the store publishes or returns.
// Runtime-only state stays on AppStore itself.

struct AppToast: Identifiable, Equatable {
  enum Kind {
    case success
    case warning
    case error
    case info
  }

  let id = UUID()
  let title: String
  let detail: String?
  let kind: Kind
  let duration: Duration

  /// The spoken form of the toast, shared by the banner's accessibility label
  /// and the one-shot VoiceOver announcement posted when the toast is added.
  var accessibilityMessage: String {
    let prefix: String
    switch kind {
    case .error:
      prefix = "Error. "
    case .warning:
      prefix = "Warning. "
    case .success, .info:
      prefix = ""
    }
    if let detail, !detail.isEmpty {
      return "\(prefix)\(title). \(detail)"
    }
    return "\(prefix)\(title)"
  }
}

struct EqualizerFocusRequest: Equatable {
  let appID: String
  let source: SourceFilter?
}

/// The mix as it stood the moment before a profile was applied: each visible
/// app's volume/mute/boost, captured so the user can put everything back with
/// one click when they're done (meeting over, game closed). Kept in memory
/// only — a restore point describes a moment, not a preference.
struct MixRestorePoint: Equatable {
  /// Name of the profile whose application created this restore point.
  let profileName: String
  /// Level-bearing entries for every app that was visible when captured.
  let entries: [ProfileEntry]
  let capturedAt: Date
}

/// Explicit fields layered onto the store's latest confirmed complete app state.
/// `replacesTargetDevice` distinguishes "leave the route alone" from an explicit
/// nil target (follow the system default).
struct AppIntentOverrides: Sendable {
  var desiredVolume: Float?
  var isMuted: Bool?
  var volumeBoost: Float?
  var equalizerSettings: EqualizerSettings?
  var targetDeviceUID: String?
  var replacesTargetDevice: Bool
  var isExcluded: Bool?
  var muteSource: MuteSource?

  init(
    desiredVolume: Float? = nil,
    isMuted: Bool? = nil,
    volumeBoost: Float? = nil,
    equalizerSettings: EqualizerSettings? = nil,
    targetDeviceUID: String? = nil,
    replacesTargetDevice: Bool = false,
    isExcluded: Bool? = nil,
    muteSource: MuteSource? = nil
  ) {
    self.desiredVolume = desiredVolume
    self.isMuted = isMuted
    self.volumeBoost = volumeBoost
    self.equalizerSettings = equalizerSettings
    self.targetDeviceUID = targetDeviceUID
    self.replacesTargetDevice = replacesTargetDevice
    self.isExcluded = isExcluded
    self.muteSource = muteSource
  }
}

enum AppIntentPersistencePolicy: Sendable {
  case none
  case acceptedUserIntent(updateDevicePreset: Bool)
}

enum AppIntentFeedbackPolicy: Sendable {
  case none
  case directControl(
    successTitle: String,
    successDetail: String?,
    failureTitle: String
  )
  case exclusion(appName: String, announce: Bool)
  case reinclusion(appName: String, announce: Bool)
}

struct AppIntentProjection: Sendable {
  let generation: UInt64
  let intent: AppRouteIntent
  let muteSource: MuteSource?
}

enum AcceptedIntentPersistenceResult {
  case notRequested
  case saved
  case settingsFailed(String)
  case devicePresetFailed(String)
}

struct ProfilePersistenceResult {
  var settingsError: String?
  var devicePresetError: String?

  var isFullySaved: Bool {
    settingsError == nil && devicePresetError == nil
  }
}

enum AppStartupState: Equatable {
  case idle
  case awaitingPrivacy
  case savingPrivacyConsent
  case startingAudio
  case running
  case failed(String)
  case shuttingDown
}

enum ProfileSaveResult: Equatable, Sendable {
  case saved(UUID)
  case unavailableDuringShutdown
  case blankName
  case nameTooLong(maximum: Int)
  case duplicateName(String)
  case noEligibleApps

  var savedProfileID: UUID? {
    guard case .saved(let id) = self else { return nil }
    return id
  }

  var message: String? {
    switch self {
    case .saved:
      nil
    case .unavailableDuringShutdown:
      "Waves is closing. Reopen it before saving this profile."
    case .blankName:
      "Enter a profile name."
    case .nameTooLong(let maximum):
      "Keep the profile name to \(maximum) characters or fewer."
    case .duplicateName(let name):
      "A profile named “\(name)” already exists."
    case .noEligibleApps:
      "Select at least one app that is not excluded from Waves."
    }
  }
}

enum AppShutdownCompletion: Hashable, Sendable {
  case clean
  case degraded
}

enum PersistenceStoreIdentifier: String, Hashable, Sendable {
  case preferences
  case profiles
  case session
  case deviceVolumePresets
  case privacySetup

  var displayName: String {
    switch self {
    case .preferences: "settings"
    case .profiles: "profiles"
    case .session: "session"
    case .deviceVolumePresets: "device presets"
    case .privacySetup: "privacy setup"
    }
  }
}

struct AppShutdownResult: Hashable, Sendable {
  let completion: AppShutdownCompletion
  let persistenceDegradations: [String]
  let backendResult: BackendShutdownResult?

  init(
    persistenceDegradations: [String] = [],
    backendResult: BackendShutdownResult? = nil
  ) {
    var seen = Set<String>()
    self.persistenceDegradations = persistenceDegradations.filter {
      seen.insert($0).inserted
    }
    self.backendResult = backendResult
    let backendIsClean = backendResult.map { $0.completion == .clean } ?? true
    self.completion =
      self.persistenceDegradations.isEmpty && backendIsClean
      ? .clean
      : .degraded
  }
}

struct AppStoreLifecycleSnapshot: Equatable, Sendable {
  let intent: AppIntentCoordinatorLifecycleSnapshot
  let persistence: AppStorePersistenceLifecycleSnapshot
  let adaptive: AdaptiveMixCoordinatorLifecycleSnapshot
  let deviceSuppression: DeviceChangeSuppressionLifecycleSnapshot
  let startupTaskCount: Int
  let ownedOperationCount: Int
  let hasLevelPoll: Bool
  let hasSessionMaintenance: Bool
  let toastDismissalCount: Int
  let lingerTaskCount: Int
  let observerCount: Int
  let backendStarted: Bool

  var isIdle: Bool {
    intent == .idle
      && persistence == .idle
      && adaptive == .idle
      && deviceSuppression == .idle
      && startupTaskCount == 0
      && ownedOperationCount == 0
      && !hasLevelPoll
      && !hasSessionMaintenance
      && toastDismissalCount == 0
      && lingerTaskCount == 0
      && observerCount == 0
      && !backendStarted
  }
}

struct GuidedMixerTourPresentation: Equatable, Sendable {
  let moment: GuidedMixerTourMoment
  let appName: String
  let isTargetAvailable: Bool
}

enum PrivacySetupPresentationState: Equatable {
  case hidden
  case awaitingPrivacy
  case savingConsent
  case startingAudio
  case startupFailed(String)
}

struct OnboardingState: Equatable {
  var hasCompletedPrivacySetup = false
  var captureAuthorization: CaptureAuthorizationResult?
  var audioComponentInstalled = false
  var permissionsGranted = false
  // Default false (matching the other flags' needs-action default) so the step
  // starts in needs-action until syncOnboarding confirms a live output device,
  // rather than optimistically asserting a device before the first sync.
  var outputDeviceVisible = false
  var routeHealthReady = false
  var launchAtLoginEnabled = false
  var launchAtLoginRequiresApproval = false
}

extension Notification.Name {
  /// Posted when the user toggles keyboard shortcuts so the app delegate can
  /// install or remove the system-wide key monitor.
  static let wavesKeyboardShortcutsPreferenceChanged = Notification.Name("WavesKeyboardShortcutsPreferenceChanged")
}
