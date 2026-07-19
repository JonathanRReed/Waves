import Accessibility
import AppKit
import ApplicationServices
import Foundation
import Observation
import OSLog
import WavesAudioCore

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

private struct AppIntentProjection: Sendable {
  let generation: UInt64
  let intent: AppRouteIntent
  let muteSource: MuteSource?
}

private enum AcceptedIntentPersistenceResult {
  case notRequested
  case saved
  case settingsFailed(String)
  case devicePresetFailed(String)
}

private struct ProfilePersistenceResult {
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

enum AppShutdownCompletion: Hashable, Sendable {
  case clean
  case degraded
}

struct AppShutdownResult: Hashable, Sendable {
  let completion: AppShutdownCompletion
  let persistenceDegradations: [String]
  let backendResult: BackendShutdownResult?

  init(
    persistenceDegradations: [String] = [],
    backendResult: BackendShutdownResult? = nil
  ) {
    self.persistenceDegradations = persistenceDegradations
    self.backendResult = backendResult
    let backendIsClean = backendResult.map { $0.completion == .clean } ?? true
    self.completion = persistenceDegradations.isEmpty && backendIsClean
      ? .clean
      : .degraded
  }
}

enum PrivacySetupPresentationState: Equatable {
  case hidden
  case awaitingPrivacy
  case savingConsent
  case startingAudio
  case startupFailed(String)
}

@Observable
@MainActor
final class AppStore {
  var session: AudioSessionSnapshot
  var profiles: [Profile]
  /// The most recent profile result after AppStore generation checks and row-level
  /// reconciliation. Retained so diagnostics/tests can inspect every source row in
  /// its original order instead of reducing a mixed apply to one boolean.
  private(set) var lastProfileApplyResult: ProfileApplyResult?
  /// The profile the user last selected, used to highlight it in the UI and —
  /// for membership-only grouping profiles — to scope the main window. Not
  /// persisted; a fresh launch starts with no active profile.
  var activeProfileID: UUID?
  /// Bumped every time a profile is applied/selected, so the main window can
  /// re-focus that profile even when `activeProfileID` is unchanged (e.g.
  /// re-applying the already-active profile from the menu bar).
  private(set) var profileFocusToken = 0
  /// The source scope the menu bar's "N more in Waves" overflow link last
  /// asked the main window to show (e.g. tapping "13 more" under Recent).
  /// Paired with `sourceFocusToken` (bumped on every request, even a repeat
  /// of the same filter) using the same pattern as `profileFocusToken` —
  /// without this, opening the main window from that link could land on
  /// whatever scope the window happened to be on, not the apps the user was
  /// actually trying to see.
  private(set) var sourceFocusRequest: SourceFilter?
  private(set) var sourceFocusToken = 0
  private(set) var equalizerFocusRequest: EqualizerFocusRequest?
  private(set) var equalizerFocusToken = 0
  var onboarding = OnboardingState()
  var preferences: UserPreferences
  var diagnostics: DiagnosticsReport?
  var isRefreshing = false
  var isRecovering = false
  var isLoading = false
  var toasts: [AppToast] = []
  private(set) var loginItemStatus = LoginItemStatus(
    isEnabled: false,
    isUserIntentEnabled: false,
    statusDescription: "Disabled"
  )
  var deviceVolumePresets = DeviceVolumePresets()
  var availableDevices: [AudioDevice] = []
  /// Live per-app output levels for meters, populated only while a UI surface
  /// is visible (kept out of `session` so updates don't trigger re-sorts).
  var liveLevels: [String: AudioLevels] = [:]
  /// Logical IDs of apps that are audible now OR went quiet within the last
  /// `liveLingerWindow`. A just-silenced app stays in the Live list for a beat so
  /// a brief gap, track change, or pause doesn't make its row flicker out — and so
  /// its controls stay put for a moment in case the user wants to grab them or the
  /// signal returns. Only Live-list *membership* lingers; the metered
  /// `mixedAudioLevel` still follows the real signal, so the header ribbon eases
  /// down to nothing on its own.
  private(set) var recentlyLiveIDs: Set<String> = []

  private let backend: any AudioControlBackend
  private let preferencesStore: any PreferencesPersisting
  private let profileStore: any ProfilesPersisting
  private let sessionStore: any SessionPersisting
  private let loginItemService: any LoginItemServicing
  private let deviceVolumePresetsStore: any DeviceVolumePresetsPersisting
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "AppStore")
  private(set) var startupState: AppStartupState
  private(set) var privacySetupError: String?
  private var isSafeBootstrapComplete = false
  private var privacySetupTask: Task<Void, Never>?
  private var audioStartupTask: Task<Void, Never>?
  private var shutdownTask: Task<AppShutdownResult, Never>?
  private(set) var shutdownResult: AppShutdownResult?
  private var ownedOperationTasks: [UUID: Task<Void, Never>] = [:]
  private var hasStartedAudioBackend = false
  private var isFinalizingShutdownPersistence = false
  // Captured once at init from DeviceVolumePresetsStore.load(); consumed (and
  // toasted) the first time start() runs so a corrupt-file recovery is
  // surfaced to the user instead of failing silently.
  private var didRecoverCorruptDeviceVolumePresets = false
  // Same one-shot recovery capture for the other three stores, so a corrupt
  // profiles/preferences/session file is surfaced to the user (with its
  // .corrupt backup mentioned) instead of resetting silently.
  private var didRecoverCorruptPreferences = false
  private var didRecoverCorruptProfiles = false
  private var didRecoverCorruptSession = false
  /// Slider-only projections are deliberately not transactions and never persist.
  private var pendingVolumeTargets: [String: Float] = [:]
  private var pendingEqualizerSettings: [String: EqualizerSettings] = [:]
  private var pendingEqualizerDebounceTasks: [String: Task<Void, Never>] = [:]
  /// One current transaction task and generation per logical app. Cancelling a
  /// task stops store-side reconciliation; backend generation checks remain the
  /// authority for native route work already in flight.
  private var appIntentTasks: [String: Task<AppIntentApplyResult, Never>] = [:]
  private var currentAppIntentGeneration: [String: UInt64] = [:]
  private var optimisticAppIntentProjections: [String: AppIntentProjection] = [:]
  /// Profile batches share one generation across every source row. Tasks remain
  /// tracked even after a newer profile supersedes them so test/shutdown drains do
  /// not report idle while an older backend batch is still unwinding.
  private var profileApplyTasks: [UInt64: Task<Void, Never>] = [:]
  private var currentProfileGeneration: UInt64?
  /// Last backend-confirmed controls, kept separate from visible optimistic state.
  private var confirmedAppsByLogicalID: [String: AudioApp] = [:]
  private var confirmedEqualizerByLogicalID: [String: EqualizerSettings] = [:]
  private var durableIntentMutationGeneration: [String: UInt64] = [:]
  private var devicePresetMutationGeneration: [String: UInt64] = [:]
  /// Last snapshots whose store writes actually completed. Rollback must use
  /// these, never another transaction's still-provisional in-memory values.
  private var durablySavedPreferences = UserPreferences()
  private var durablySavedDeviceVolumePresets = DeviceVolumePresets()
  private var toastDismissals: [UUID: Task<Void, Never>] = [:]
  private var deviceChangeObserver: Task<Void, Never>?
  // Reentrancy guard so rapid device flapping (dock/undock, BT connect) can't
  // stack overlapping handleDeviceChange Tasks that each reassign `session`
  // mid-flight (interleaved snapshot reassignments and preset restores would
  // leave the UI on whichever pass happened to land last).
  private var isHandlingDeviceChange = false
  // Set when a device-change event arrives while a handler is already in flight.
  // The in-flight handler clears it and runs exactly one more pass, so a coalesced
  // event (rapid dock/undock, Bluetooth reconnect) is never dropped.
  private var pendingDeviceChangeRerun = false
  // Set briefly by selectOutputDevice so the Core Audio default-device listener's
  // ensuing handleDeviceChange suppresses its "Output device changed" info toast:
  // a manual switch already shows an "Output switched" success toast, so a second
  // toast for the same switch is just noise.
  private var pendingSelfInitiatedDeviceID: String?
  private var frontmostAppObserver: NSObjectProtocol?
  private var appTerminationObserver: NSObjectProtocol?
  private var levelPollTask: Task<Void, Never>?
  private var sessionMaintenanceTask: Task<Void, Never>?
  private(set) var sessionMaintenanceStartCount = 0
  private var adaptiveMixTask: Task<Void, Never>?
  // At most one persistence runner exists per full-value store. Calls replace the
  // pending immutable snapshot while that runner is active, keeping task tracking
  // bounded to four tasks even during rapid UI edits.
  private var pendingPreferencesPersistence: UserPreferences?
  private var pendingProfilesPersistence: [Profile]?
  private var pendingSessionPersistence: AudioSessionSnapshot?
  private var pendingDevicePresetsPersistence: DeviceVolumePresets?
  private var preferencesPersistenceTask: Task<Void, Never>?
  private var profilesPersistenceTask: Task<Void, Never>?
  private var sessionPersistenceTask: Task<Void, Never>?
  private var devicePresetsPersistenceTask: Task<Void, Never>?
  private(set) var persistenceFailureCount = 0
  private(set) var lastPersistenceError: String?
  private var persistenceFailureHistory: [String] = []
  private var lastPersistenceWarningDate: Date?
  private let persistenceWarningDebounceInterval: TimeInterval = 5
  private var speechDetectionStates: [String: SpeechDetectionState] = [:]
  private var speechDuckingStates: [String: SpeechDuckingState] = [:]
  private var loudnessTrimStates: [String: LoudnessTrimState] = [:]
  private var liveLevelsRefcount = 0
  private var isRunningSessionMaintenance = false
  // Per-app one-shot tasks that drop an app out of the lingering-live set once it
  // has been quiet for `liveLingerWindow`. Cancelled (and the app kept) the moment
  // it becomes audible again.
  private var lingerRemovalTasks: [String: Task<Void, Never>] = [:]
  private var liveLingerWindow: Duration { preferences.liveListLinger.duration }
  private let sessionMaintenanceInterval = Duration.seconds(8)
  private let adaptiveMixInterval = Duration.milliseconds(100)
  private let maxToasts = 3
  private let defaultToastDuration = Duration.seconds(2.0)
  // Failures need longer on screen than routine successes: 2.0s is too short to
  // read a full error string, so .error/.warning toasts that don't pass an
  // explicit duration default to a longer lifetime.
  private let errorToastDuration = Duration.seconds(4.5)
  private var previousFrontmostApp: String?
  private var pausedMusicApps: Set<String> = []
  // Reentrancy guard mirroring isHandlingDeviceChange: rapid frontmost-app
  // switches (activate Zoom, cmd-tab away within ~100ms) must not stack
  // overlapping pause/resume passes that each read mute state captured before
  // the other's backend writes landed — media could end up auto-muted with no
  // call app frontmost and nothing to resume it until the next app switch.
  private var isRunningAutoPausePass = false
  // Set when checkAutoPauseMusic fires while a pass is in flight. The runner
  // clears it and runs exactly one more pass, which re-reads the *current*
  // frontmost app — so the latest app switch always wins and none are dropped.
  private var pendingAutoPausePassRerun = false
  /// Leave ample space between store generations and the backend's temporary
  /// legacy-call allocator. Profile/automation migration will remove that bridge.
  private static let appIntentGenerationStride: UInt64 = 1 << 32
  private static var appIntentGenerationCounter: UInt64 = 0
  private var urlSchemeRequestTimes: [Date] = []
  private let maxURLSchemeRequests = 10
  private let urlSchemeRequestWindow: TimeInterval = 60
  // Debounce the "throttled" toast so a flood of dropped commands surfaces at
  // most one toast per window instead of one per dropped command.
  private var lastURLSchemeThrottleToast: Date?
  private let urlSchemeThrottleToastInterval: TimeInterval = 5

  init(
    backend: any AudioControlBackend,
    preferencesStore: any PreferencesPersisting,
    profileStore: any ProfilesPersisting,
    sessionStore: any SessionPersisting,
    loginItemService: any LoginItemServicing,
    deviceVolumePresetsStore: any DeviceVolumePresetsPersisting,
    initialStartupState: AppStartupState = .idle
  ) {
    self.backend = backend
    self.preferencesStore = preferencesStore
    self.profileStore = profileStore
    self.sessionStore = sessionStore
    self.loginItemService = loginItemService
    self.deviceVolumePresetsStore = deviceVolumePresetsStore
    self.startupState = initialStartupState
    self.hasStartedAudioBackend = initialStartupState == .running
    let loadedPreferences = preferencesStore.load()
    let loadedDeviceVolumePresets = deviceVolumePresetsStore.load()
    self.preferences = loadedPreferences
    self.profiles = profileStore.load(defaults: Profile.defaults)
    self.session = sessionStore.load() ?? Self.emptySession
    self.deviceVolumePresets = loadedDeviceVolumePresets
    self.durablySavedPreferences = loadedPreferences
    self.durablySavedDeviceVolumePresets = loadedDeviceVolumePresets
    self.didRecoverCorruptDeviceVolumePresets = deviceVolumePresetsStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptPreferences = preferencesStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptProfiles = profileStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptSession = sessionStore.consumeDidRecoverFromCorruptFile()
    var shouldPersistPreferences = false
    // Migrate pins recorded only on the persisted session (builds before pin
    // state moved into preferences) into the authoritative set, just once.
    if preferences.pinnedAppIDs.isEmpty {
      let sessionPins = session.apps.filter(\.isPinned).map(\.logicalID)
      if !sessionPins.isEmpty {
        preferences.pinnedAppIDs = Array(Set(sessionPins))
        shouldPersistPreferences = true
      }
    }
    // Only manual sort depends on a saved order; fall back to name if it is
    // missing. Activity sort needs no stored order and must be preserved across
    // launches.
    if preferences.sortMode == .manual && preferences.customAppOrder.isEmpty {
      preferences.sortMode = .name
      shouldPersistPreferences = true
    }
    if !preferences.urlSchemeAutomationAcknowledged {
      preferences.enableURLScheme = false
      preferences.urlSchemeAutomationAcknowledged = true
      shouldPersistPreferences = true
    }
    if Self.migrateDurableAppIntents(in: &preferences, from: session) {
      shouldPersistPreferences = true
    }
    confirmedAppsByLogicalID = Dictionary(
      session.apps.map { ($0.logicalID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    confirmedEqualizerByLogicalID = preferences.appAudioIntents.mapValues(\.equalizerSettings)
    for (appID, equalizer) in preferences.appEqualizerSettings
      where confirmedEqualizerByLogicalID[appID] == nil {
      confirmedEqualizerByLogicalID[appID] = equalizer
    }
    loginItemStatus = loginItemService.status
    if preferences.launchAtLoginEnabled != loginItemStatus.isUserIntentEnabled {
      preferences.launchAtLoginEnabled = loginItemStatus.isUserIntentEnabled
      shouldPersistPreferences = true
    }
    self.onboarding = OnboardingState(
      launchAtLoginEnabled: loginItemStatus.isEnabled,
      launchAtLoginRequiresApproval: loginItemStatus.requiresApproval
    )
    if shouldPersistPreferences {
      enqueuePreferencesPersistence(preferences)
    }
    syncOnboarding(using: session)
  }

  var visibleApps: [AudioApp] {
    // Pin state is authoritative in preferences (so it survives an app quitting
    // and relaunching). Reconcile every app's isPinned here — the single source
    // feeding pinnedApps, liveApps, recentApps, and every view — so the rest of
    // the app can keep reading the familiar `app.isPinned`.
    let pinned = Set(preferences.pinnedAppIDs)
    let filtered = session.apps
      .filter { preferences.showSystemProcesses || $0.category != .system }
      .map { app -> AudioApp in
        guard app.isPinned != pinned.contains(app.logicalID) else { return app }
        var reconciled = app
        reconciled.isPinned = pinned.contains(app.logicalID)
        return reconciled
      }
    return sortedApps(filtered)
  }

  var pinnedApps: [AudioApp] {
    visibleApps.filter(\.isPinned)
  }

  var activeApps: [AudioApp] {
    visibleApps.filter(\.isActive)
  }

  private static let liveLevelThreshold: Float = 0.0015

  /// Whether an app is actively producing audio right now.
  ///
  /// A `.live` app is audible but not yet managed. A `.managed` app (Waves owns
  /// its route) must keep counting as live while it's *still producing output* —
  /// otherwise the moment you nudge a playing app's volume it flips to `.managed`
  /// and vanishes from the Live list even though sound is still coming out. The
  /// authoritative "is it making sound now" signal is the live-level poll
  /// (`liveLevels`, refreshed a few times a second while a surface is visible);
  /// fall back to the last snapshot levels when the poll isn't running.
  func isLive(_ app: AudioApp) -> Bool {
    if app.routingState == .live { return true }
    guard app.routingState == .managed, !app.isMuted else { return false }
    if let levels = liveLevels[app.logicalID] {
      return max(levels.rms, levels.peak) > Self.liveLevelThreshold
    }
    return max(app.peakLevel, app.rmsLevel) > Self.liveLevelThreshold
  }

  /// True when the app is producing audio right now, OR went quiet within the
  /// linger window. Drives Live-list membership (which lingers for a couple of
  /// seconds so rows don't blink out on a brief gap); the metered
  /// `mixedAudioLevel` deliberately keeps using `isLive` so the visualizer still
  /// follows the real signal and fades out.
  func isRecentlyLive(_ app: AudioApp) -> Bool {
    isLive(app) || recentlyLiveIDs.contains(app.logicalID)
  }

  var liveApps: [AudioApp] {
    visibleApps.filter(isRecentlyLive)
  }

  /// Apps producing audio *right now* — no linger. `liveApps` (the Live list)
  /// deliberately lingers a just-silenced app for a couple of seconds so its row
  /// doesn't blink out, but "is something playing this instant" affordances — the
  /// menu-bar status text/icon, the brand-mark drift, the "X playing" header
  /// summary, the menu-bar accessibility label — must follow the *real* signal
  /// (exactly like the visualizer ribbon, which fades to nothing), or they'd keep
  /// asserting playback for the whole linger window after sound has stopped.
  var actuallyLiveApps: [AudioApp] {
    visibleApps.filter(isLive)
  }

  /// Whether anything is producing audio right now (no linger). Cheaper than
  /// `!actuallyLiveApps.isEmpty` — short-circuits without building an array.
  var hasLiveAudio: Bool {
    visibleApps.contains(where: isLive)
  }

  /// Combined live audio energy (0...1) across every currently-playing app, for
  /// the header visualizer. Independent app streams have random relative phase,
  /// so their *powers* add — root-sum-of-squares is the physically correct mix
  /// (a plain average would fall when a quiet app joins a loud one). A managed
  /// app contributes its measured RMS/peak; an audible-but-unmanaged `.live` app,
  /// which Waves can't meter without tapping it, contributes a small nominal
  /// floor so it still registers. A perceptual power curve + soft `tanh` clamp
  /// keeps quiet mixes visible and loud mixes from slamming the ceiling.
  var mixedAudioLevel: Float {
    var energy = 0.0
    for app in visibleApps where !app.isMuted && isLive(app) {
      let measured = liveLevels[app.logicalID].map { Double(max($0.rms, $0.peak * 0.8)) } ?? 0
      let contribution = measured > 0.001 ? measured : 0.12 // floor for unmetered live apps
      energy += contribution * contribution
    }
    guard energy > 0 else { return 0 }
    let perceptual = pow(energy.squareRoot(), 0.6)
    return Float(tanh(1.6 * perceptual))
  }

  /// Per-app live contributions for the header visualizer's superposition
  /// rendering — each currently-playing app's identity plus its perceptual
  /// level, capped to the loudest few so the band stays legible. Follows the
  /// same real-signal rule as `mixedAudioLevel` (isLive, no linger) so every
  /// component wave genuinely fades out when its app goes quiet, and the same
  /// nominal floor for audible-but-unmetered `.live` apps.
  var waveComponents: [WaveComponent] {
    var components: [WaveComponent] = []
    for app in visibleApps where !app.isMuted && isLive(app) {
      let measured = liveLevels[app.logicalID].map { Double(max($0.rms, $0.peak * 0.8)) } ?? 0
      // A slightly higher nominal floor than mixedAudioLevel's: an audible
      // but unmetered app should still ripple visibly in the showcase band.
      let level = measured > 0.001 ? measured : 0.18
      components.append(WaveComponent(id: app.logicalID, level: min(1, pow(level, 0.5))))
    }
    guard components.count > 6 else { return components }
    return Array(components.sorted { $0.level > $1.level }.prefix(6))
  }

  var recentApps: [AudioApp] {
    guard preferences.showRecentApps else { return [] }
    // Recent = visible apps that are neither live nor pinned, so an app never
    // renders in more than one menu-panel section (Pinned / Live / Recent).
    // Evaluate visibleApps once and derive both sets locally rather than calling
    // the liveApps/pinnedApps computed props (which would each re-sort visibleApps).
    let visible = visibleApps
    // Exclude lingering-live apps too (isRecentlyLive), so a just-silenced app
    // doesn't briefly appear in BOTH Live (still lingering) and Recent.
    let liveIDs = Set(visible.filter(isRecentlyLive).map(\.logicalID))
    return visible.filter { !$0.isPinned && !liveIDs.contains($0.logicalID) }
  }

  var currentDeviceID: String? {
    session.currentDevice?.id
  }

  private func invalidateVisibleAppsCache() {
    // No-op cache removed; keep explicit invalidation points intact for future
    // callers without forcing a runtime write during view updates.
  }

  var currentDeviceName: String {
    session.currentDevice?.name ?? "No output device"
  }

  var menuBarIconName: String {
    if !isAudioRunning {
      return "lock.shield.fill"
    }
    // Reflect what the app is actually doing rather than an average of all
    // apps' volumes (which carries little meaning).
    if visibleApps.contains(where: \.isMuted) {
      return "speaker.slash.fill"
    }
    // Reflect what's playing *now*, not the lingering Live list — the glyph must
    // drop back to the idle wave the moment audio actually stops.
    if hasLiveAudio {
      return "speaker.wave.3.fill"
    }
    return "speaker.wave.2.fill"
  }

  var sourceInventorySummary: String {
    let count = visibleApps.count
    let label = count == 1 ? "running app" : "running apps"
    return "\(count) \(label)"
  }

  var isAudioRunning: Bool {
    startupState == .running
  }

  var privacySetupPresentationState: PrivacySetupPresentationState {
    switch startupState {
    case .idle:
      return preferences.hasCompletedPrivacySetup ? .startingAudio : .awaitingPrivacy
    case .shuttingDown:
      return .hidden
    case .awaitingPrivacy:
      return .awaitingPrivacy
    case .savingPrivacyConsent:
      return .savingConsent
    case .startingAudio:
      return .startingAudio
    case .running:
      return .hidden
    case let .failed(detail):
      return .startupFailed(detail)
    }
  }

  var hasActiveSessionMaintenance: Bool {
    sessionMaintenanceTask != nil
  }

  var launchAtLoginEnabled: Bool {
    get { preferences.launchAtLoginEnabled }
    set {
      do {
        try loginItemService.setEnabled(newValue)
        let status = loginItemService.status
        loginItemStatus = status
        preferences.launchAtLoginEnabled = status.isUserIntentEnabled
        onboarding.launchAtLoginEnabled = status.isEnabled
        onboarding.launchAtLoginRequiresApproval = status.requiresApproval
        persistPreferences()
        if status.isEnabled != newValue {
          // Only the .requiresApproval case actually points the user at the
          // System Settings approval path. Other failures (.notRegistered /
          // .notFound / @unknown) are generic enable failures and must not be
          // mislabeled as an approval issue.
          let needsApproval = status.requiresApproval
          showToast(
            title: needsApproval ? "Login item needs approval" : "Couldn't enable Launch at login",
            detail: status.statusDescription,
            kind: .warning,
            duration: .seconds(2.4)
          )
        }
      } catch {
        let status = loginItemService.status
        loginItemStatus = status
        preferences.launchAtLoginEnabled = status.isUserIntentEnabled
        onboarding.launchAtLoginEnabled = status.isEnabled
        onboarding.launchAtLoginRequiresApproval = status.requiresApproval
        persistPreferences()
        showToast(title: "Login item update failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  var launchAtLoginRequiresApproval: Bool {
    loginItemStatus.requiresApproval
  }

  var launchAtLoginStatusDescription: String {
    loginItemStatus.statusDescription
  }

  func openLoginItemsSettings() {
    loginItemService.openSystemSettingsLoginItems()
  }

  func start() {
    performSafeBootstrapIfNeeded()

    switch startupState {
    case .savingPrivacyConsent, .startingAudio, .running, .failed, .shuttingDown:
      return
    case .idle, .awaitingPrivacy:
      break
    }

    guard preferences.hasCompletedPrivacySetup else {
      startupState = .awaitingPrivacy
      isLoading = false
      return
    }

    beginAudioStartupIfNeeded()
  }

  /// Accepts the local-processing explanation, makes that choice durable, and only
  /// then starts the capture-capable audio backend. Reusing this action after a
  /// startup failure retries audio without asking for consent again.
  func acceptPrivacySetupAndStart() async {
    performSafeBootstrapIfNeeded()
    guard startupState != .shuttingDown else { return }

    if let privacySetupTask {
      await privacySetupTask.value
      return
    }

    if preferences.hasCompletedPrivacySetup {
      beginAudioStartupIfNeeded()
      await audioStartupTask?.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.persistPrivacyConsentAndStartAudio()
    }
    privacySetupTask = task
    await task.value
  }

  func waitForAudioStartup() async {
    await audioStartupTask?.value
  }

  func promptToFinishSetup() {
    presentFinishSetupMessage()
  }

  private func performSafeBootstrapIfNeeded() {
    guard !isSafeBootstrapComplete else { return }
    isSafeBootstrapComplete = true
    isLoading = false
    syncOnboarding(using: session)
  }

  private func persistPrivacyConsentAndStartAudio() async {
    startupState = .savingPrivacyConsent
    privacySetupError = nil
    preferences.hasCompletedPrivacySetup = true
    onboarding.hasCompletedPrivacySetup = true

    do {
      try await savePreferencesDurably()
    } catch {
      preferences.hasCompletedPrivacySetup = false
      onboarding.hasCompletedPrivacySetup = false
      privacySetupError = "Waves couldn't save your setup choice. Check that your user Library is writable, then try again. \(error.localizedDescription)"
      startupState = .awaitingPrivacy
      privacySetupTask = nil
      reportPersistenceFailure(storeName: "privacy setup", error: error, showWarning: false)
      showToast(
        title: "Setup wasn't saved",
        detail: privacySetupError,
        kind: .error
      )
      return
    }

    privacySetupTask = nil
    guard !Task.isCancelled, startupState != .shuttingDown else { return }
    beginAudioStartupIfNeeded()
    await audioStartupTask?.value
  }

  private func beginAudioStartupIfNeeded() {
    guard preferences.hasCompletedPrivacySetup else {
      startupState = .awaitingPrivacy
      return
    }
    guard audioStartupTask == nil else { return }
    guard startupState != .running, startupState != .shuttingDown else { return }

    startupState = .startingAudio
    privacySetupError = nil
    isLoading = session.apps.isEmpty
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performAudioStartup()
    }
    audioStartupTask = task
  }

  private func performAudioStartup() async {
    defer {
      isLoading = false
      audioStartupTask = nil
    }

    do {
      let warmSnapshot = session
      if !warmSnapshot.apps.isEmpty {
        session = warmSnapshot
        syncOnboarding(using: session)
      }

      try await backend.start()
      // Even if shutdown began while backend.start() was suspended, record the
      // successful native start so the checked shutdown path tears it back down.
      hasStartedAudioBackend = true
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      let built = await backend.currentSnapshot()
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      session = mergedSession(with: built, cached: warmSnapshot)
      invalidateVisibleAppsCache()
      cleanupStaleEntries()
      await reapplyRestoredAudioState()
      if preferences.adaptiveMixMode.usesSpeechFocus,
         preferences.autoPauseMusicForConferencing {
        preferences.autoPauseMusicForConferencing = false
        persistPreferences()
      }
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      availableDevices = await backend.availableOutputDevices()
      persistSessionSnapshot()
      syncOnboarding(using: session)

      observeDeviceChanges()
      observeFrontmostAppChanges()
      observeAppTermination()
      startupState = .running
      startSessionMaintenance()
      restartAdaptiveMixing()
      startLiveLevelPollingIfNeeded()
      checkAutoPauseMusic()
      presentRecoveredStoreWarningIfNeeded()
      showToast(title: "Waves is ready", detail: "Per-app audio mixer loaded.", kind: .success)
    } catch {
      guard startupState != .shuttingDown else { return }
      let detail = error.localizedDescription
      startupState = .failed(detail)
      privacySetupError = detail
      showToast(title: "Startup failed", detail: detail, kind: .error, duration: .seconds(3.2))
    }
  }

  private func presentRecoveredStoreWarningIfNeeded() {
    // One combined toast for every store that had to reset a corrupted file — the
    // originals are preserved beside the replacements, and the user deserves to
    // know both facts instead of seeing a silent reset.
    var recoveredStores: [String] = []
    if didRecoverCorruptDeviceVolumePresets { recoveredStores.append("device presets") }
    if didRecoverCorruptProfiles { recoveredStores.append("profiles") }
    if didRecoverCorruptPreferences { recoveredStores.append("settings") }
    if didRecoverCorruptSession { recoveredStores.append("session") }
    didRecoverCorruptDeviceVolumePresets = false
    didRecoverCorruptProfiles = false
    didRecoverCorruptPreferences = false
    didRecoverCorruptSession = false
    if !recoveredStores.isEmpty {
      showToast(
        title: "Saved data recovered",
        detail: "Corrupted \(recoveredStores.joined(separator: ", ")) reset to defaults. Originals kept as .corrupt files.",
        kind: .warning
      )
    }
  }

  @discardableResult
  private func requireAudioRunning() -> Bool {
    guard startupState == .running else {
      presentFinishSetupMessage()
      return false
    }
    return true
  }

  @discardableResult
  private func startOwnedOperation(
    _ operation: @escaping @MainActor @Sendable (AppStore) async -> Void
  ) -> Bool {
    guard startupState != .shuttingDown else { return false }
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.ownedOperationTasks.removeValue(forKey: id) }
      await operation(self)
    }
    ownedOperationTasks[id] = task
    return true
  }

  private func presentFinishSetupMessage() {
    guard !toasts.contains(where: { $0.title == "Finish setup" }) else { return }
    let detail: String
    switch startupState {
    case .startingAudio, .savingPrivacyConsent:
      detail = "Waves is still finishing setup. Wait a moment, then try again."
    case .failed:
      detail = "Waves couldn't start. Use Retry Start Waves on the setup screen."
    case .idle, .awaitingPrivacy:
      detail = "Choose Continue and Start Waves before using audio controls."
    case .running:
      return
    case .shuttingDown:
      detail = "Waves is closing and can't change audio now."
    }
    showToast(title: "Finish setup", detail: detail, kind: .warning)
  }

  func refresh(
    announce: Bool = true,
    reevaluateAutomation: Bool = true
  ) {
    guard requireAudioRunning() else { return }
    guard !isRefreshing else { return }

    isRefreshing = true
    isLoading = session.apps.isEmpty
    startOwnedOperation { store in
      await store.performRefresh(
        announce: announce,
        reevaluateAutomation: reevaluateAutomation
      )
    }
  }

  private func performRefresh(
    announce: Bool,
    reevaluateAutomation: Bool
  ) async {
    defer {
      isRefreshing = false
      isLoading = false
    }

    do {
      let knownAppIDs = Set(session.apps.map(\.logicalID))
      let refreshed = try await backend.refresh()
      guard !Task.isCancelled, startupState == .running else { return }
      session = mergedSession(with: refreshed, cached: session)
      invalidateVisibleAppsCache()
      cleanupStaleEntries()
      await restoreNewlyAppearedConfiguredApps(excluding: knownAppIDs)
      guard !Task.isCancelled, startupState == .running else { return }
      persistSessionSnapshot()
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      syncOnboarding(using: session)
      if reevaluateAutomation {
        checkAutoPauseMusic()
      }
      if announce {
        let visibleCount = visibleApps.count
        showToast(title: "Library refreshed", detail: "\(visibleCount) app\(visibleCount == 1 ? "" : "s") detected.", kind: .info)
      }
    } catch {
      guard startupState == .running else { return }
      showToast(title: "Refresh failed", detail: error.localizedDescription, kind: .error)
    }
  }

  private func startSessionMaintenance() {
    guard startupState == .running else { return }
    guard sessionMaintenanceTask == nil else { return }
    sessionMaintenanceStartCount += 1
    sessionMaintenanceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: self.sessionMaintenanceInterval)
        guard !Task.isCancelled else { return }
        await self.performSilentSessionRefresh()
      }
    }
  }

  private func performSilentSessionRefresh() async {
    guard startupState == .running,
          !isRefreshing,
          !isRecovering,
          !isLoading,
          !isRunningSessionMaintenance,
          pendingVolumeTargets.isEmpty else {
      return
    }

    isRunningSessionMaintenance = true
    defer { isRunningSessionMaintenance = false }

    do {
      let knownAppIDs = Set(session.apps.map(\.logicalID))
      let rebuilt = try await backend.refresh()
      session = mergedSession(with: rebuilt, cached: session)
      invalidateVisibleAppsCache()
      cleanupStaleEntries()
      await restoreNewlyAppearedConfiguredApps(excluding: knownAppIDs)
      persistSessionSnapshot()
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      availableDevices = await backend.availableOutputDevices()
      syncOnboarding(using: session)
      checkAutoPauseMusic()
    } catch {
      logger.debug("Silent session refresh failed: \(error.localizedDescription)")
    }
  }

  func handleURLScheme(_ url: URL) {
    guard requireAudioRunning() else { return }
    guard preferences.enableURLScheme else {
      logger.warning("URL scheme invocation rejected because URL schemes are disabled")
      return
    }

    guard url.scheme == "waves",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = components.host, !host.isEmpty else {
      return
    }

    // Charge the rate limit only against well-formed waves:// commands so a
    // flood of malformed URLs cannot exhaust the quota for legitimate ones.
    guard checkURLSchemeRateLimit() else {
      logger.warning("URL scheme invocation rejected because the rate limit was exceeded")
      // Surface a debounced warning so throttled automation isn't silent in-app,
      // while ensuring the throttle toast itself cannot be spammed.
      let now = Date()
      if lastURLSchemeThrottleToast.map({ now.timeIntervalSince($0) >= urlSchemeThrottleToastInterval }) ?? true {
        lastURLSchemeThrottleToast = now
        showToast(
          title: "URL command throttled",
          detail: "Too many commands — try again shortly.",
          kind: .warning
        )
      }
      return
    }

    logger.info("URL scheme invoked: \(host, privacy: .public)")

    switch host {
    case "set-volume":
      handleURLSetVolume(components)
    case "mute":
      handleURLMute(components)
    case "apply-profile", "apply-preset":
      // "apply-preset" kept as a deprecated alias from before the rename.
      handleURLApplyProfile(components)
    case "refresh":
      refresh()
    default:
      logger.warning("URL scheme invoked with unknown host: \(host, privacy: .public)")
      showToast(
        title: "URL command blocked",
        detail: "Unknown command: \(String(host.prefix(64)))",
        kind: .warning
      )
    }
  }

  private func handleURLSetVolume(_ components: URLComponents) {
    guard let appID = components.queryItems?.first(where: { $0.name == "app" })?.value,
          let volumeValue = components.queryItems?.first(where: { $0.name == "volume" })?.value,
          appID.count <= 256,
          volumeValue.count <= 32,
          let volume = Float(volumeValue),
          volume >= 0,
          volume <= 1 else {
      showToast(title: "URL command blocked", detail: "Set-volume command was invalid.", kind: .warning)
      return
    }

    guard let app = session.apps.first(matchingAppKey: appID) else {
      showToast(title: "URL command blocked", detail: "App not found: \(String(appID.prefix(64)))", kind: .warning)
      return
    }

    guard !isExcluded(app) else {
      showToast(title: "URL command blocked", detail: "App is excluded from Waves.", kind: .warning)
      return
    }

    setDesiredVolume(volume, for: app)
    commitDesiredVolume(for: app)
  }

  private func handleURLMute(_ components: URLComponents) {
    guard let appID = components.queryItems?.first(where: { $0.name == "app" })?.value,
          let muteValue = components.queryItems?.first(where: { $0.name == "muted" })?.value,
          appID.count <= 256,
          muteValue.count <= 16,
          let shouldMute = Bool(muteValue) else {
      showToast(title: "URL command blocked", detail: "Mute command was invalid.", kind: .warning)
      return
    }

    guard let app = session.apps.first(matchingAppKey: appID) else {
      showToast(title: "URL command blocked", detail: "App not found: \(String(appID.prefix(64)))", kind: .warning)
      return
    }

    guard !isExcluded(app) else {
      showToast(title: "URL command blocked", detail: "App is excluded from Waves.", kind: .warning)
      return
    }

    setMuted(shouldMute, for: app)
  }

  private func handleURLApplyProfile(_ components: URLComponents) {
    guard let profileName = components.queryItems?.first(where: { $0.name == "name" })?.value,
          profileName.count <= 256 else {
      showToast(title: "URL command blocked", detail: "Profile command was invalid.", kind: .warning)
      return
    }

    guard let profile = profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(profileName) == .orderedSame }) else {
      showToast(title: "Profile not found", detail: "No profile named: \(String(profileName.prefix(64)))", kind: .warning)
      return
    }

    applyProfile(profile)
  }

  private func checkURLSchemeRateLimit() -> Bool {
    let now = Date()
    let cutoff = now.addingTimeInterval(-urlSchemeRequestWindow)
    urlSchemeRequestTimes.removeAll { $0 < cutoff }
    guard urlSchemeRequestTimes.count < maxURLSchemeRequests else {
      return false
    }
    urlSchemeRequestTimes.append(now)
    return true
  }

  // MARK: - Complete app-intent transactions

  private static func allocateAppIntentGeneration() -> UInt64 {
    appIntentGenerationCounter &+= appIntentGenerationStride
    return appIntentGenerationCounter
  }

  /// Reusable transaction boundary for direct controls today and profile /
  /// automation orchestration in the follow-up pass. Every request is complete,
  /// generated from confirmed runtime state plus explicit overrides.
  @discardableResult
  func applyAppIntent(
    forAppID appID: String,
    overrides: AppIntentOverrides = AppIntentOverrides(),
    reason: AppRouteIntentReason,
    persistencePolicy: AppIntentPersistencePolicy = .none,
    feedbackPolicy: AppIntentFeedbackPolicy = .none,
    optimistic: Bool = false
  ) async -> AppIntentApplyResult {
    guard requireAudioRunning() else {
      return AppIntentApplyResult(
        appID: appID,
        generation: 0,
        outcome: .failed,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: session.backendStatus,
        detail: "Finish setup before changing app audio."
      )
    }
    return await startAppIntentTransaction(
      forAppID: appID,
      overrides: overrides,
      reason: reason,
      persistencePolicy: persistencePolicy,
      feedbackPolicy: feedbackPolicy,
      optimistic: optimistic
    ).value
  }

  @discardableResult
  private func startAppIntentTransaction(
    forAppID appID: String,
    overrides: AppIntentOverrides,
    reason: AppRouteIntentReason,
    persistencePolicy: AppIntentPersistencePolicy,
    feedbackPolicy: AppIntentFeedbackPolicy,
    optimistic: Bool
  ) -> Task<AppIntentApplyResult, Never> {
    guard startupState != .shuttingDown else {
      let result = AppIntentApplyResult(
        appID: appID,
        generation: 0,
        outcome: .failed,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: session.backendStatus,
        detail: "Waves is shutting down."
      )
      return Task { result }
    }
    let generation = Self.allocateAppIntentGeneration()
    let intent = completeAppRouteIntent(
      forAppID: appID,
      overrides: overrides,
      generation: generation,
      reason: reason
    )
    let projectedMuteSource = overrides.muteSource
      ?? (overrides.isMuted == nil
        ? session.apps.first(matchingAppKey: appID)?.muteSource
        : nil)

    appIntentTasks[appID]?.cancel()
    currentAppIntentGeneration[appID] = generation
    if optimistic {
      let projection = AppIntentProjection(
        generation: generation,
        intent: intent,
        muteSource: projectedMuteSource
      )
      optimisticAppIntentProjections[appID] = projection
      applyOptimisticProjection(projection, toAppID: appID)
    } else {
      optimisticAppIntentProjections.removeValue(forKey: appID)
    }

    let backend = backend
    let deviceIDAtSubmission = currentDeviceID
    let task = Task { @MainActor [weak self] in
      let backendResult = await backend.applyAppIntent(intent)
      guard let self else { return backendResult }
      return await self.finishAppIntentTransaction(
        intent: intent,
        projectedMuteSource: projectedMuteSource,
        backendResult: backendResult,
        persistencePolicy: persistencePolicy,
        deviceIDAtSubmission: deviceIDAtSubmission,
        feedbackPolicy: feedbackPolicy
      )
    }
    appIntentTasks[appID] = task
    return task
  }

  private func completeAppRouteIntent(
    forAppID appID: String,
    overrides: AppIntentOverrides,
    generation: UInt64,
    reason: AppRouteIntentReason
  ) -> AppRouteIntent {
    let confirmed = confirmedAppsByLogicalID[appID]
      ?? session.apps.first(matchingAppKey: appID)
    var desiredVolume = confirmed?.desiredVolume ?? 1
    var isMuted = confirmed?.isMuted ?? false
    var volumeBoost = confirmed?.volumeBoost ?? 1
    var equalizer = confirmedEqualizerByLogicalID[appID]
      ?? preferences.appAudioIntents[appID]?.equalizerSettings
      ?? preferences.appEqualizerSettings[appID]
      ?? EqualizerSettings()
    var targetDeviceUID = confirmed?.targetDeviceUID

    // A newer complete edit must carry forward the user's still-current projected
    // fields from the transaction it supersedes; a slider-only pending target is
    // intentionally excluded until commitDesiredVolume establishes a boundary.
    if let projection = optimisticAppIntentProjections[appID],
       currentAppIntentGeneration[appID] == projection.generation,
       !projection.intent.isExcluded {
      desiredVolume = projection.intent.desiredVolume
      isMuted = projection.intent.isMuted
      volumeBoost = projection.intent.volumeBoost
      equalizer = projection.intent.equalizerSettings
      targetDeviceUID = projection.intent.targetDeviceUID
    }

    if let value = overrides.desiredVolume { desiredVolume = value }
    if let value = overrides.isMuted { isMuted = value }
    if let value = overrides.volumeBoost { volumeBoost = value }
    if let value = overrides.equalizerSettings { equalizer = value }
    if overrides.replacesTargetDevice { targetDeviceUID = overrides.targetDeviceUID }

    return AppRouteIntent(
      appID: appID,
      desiredVolume: desiredVolume,
      isMuted: isMuted,
      volumeBoost: volumeBoost,
      equalizerSettings: equalizer,
      targetDeviceUID: targetDeviceUID,
      generation: generation,
      reason: reason,
      isExcluded: overrides.isExcluded
        ?? preferences.excludedAppIDs.contains(appID)
    )
  }

  private func finishAppIntentTransaction(
    intent: AppRouteIntent,
    projectedMuteSource: MuteSource?,
    backendResult: AppIntentApplyResult,
    persistencePolicy: AppIntentPersistencePolicy,
    deviceIDAtSubmission: String?,
    feedbackPolicy: AppIntentFeedbackPolicy
  ) async -> AppIntentApplyResult {
    let appID = intent.appID
    guard currentAppIntentGeneration[appID] == intent.generation else {
      return AppIntentApplyResult(
        appID: appID,
        generation: intent.generation,
        outcome: .superseded,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: backendResult.backendStatus,
        detail: "A newer AppStore transaction superseded this result."
      )
    }
    guard backendResult.generation == intent.generation else {
      if optimisticAppIntentProjections[appID]?.generation == intent.generation {
        optimisticAppIntentProjections.removeValue(forKey: appID)
      }
      let confirmedSnapshot = await backend.currentSnapshot()
      if currentAppIntentGeneration[appID] == intent.generation {
        session = mergedSession(with: confirmedSnapshot, cached: session)
        syncOnboarding(using: session)
        persistSessionSnapshot()
        appIntentTasks.removeValue(forKey: appID)
      }
      return AppIntentApplyResult(
        appID: appID,
        generation: intent.generation,
        outcome: .superseded,
        resultingApp: session.apps.first(matchingAppKey: appID),
        backendStatus: confirmedSnapshot.backendStatus,
        detail: "The backend returned a result for a different generation."
      )
    }

    optimisticAppIntentProjections.removeValue(forKey: appID)
    reconcileAppIntentResult(
      backendResult,
      intent: intent,
      projectedMuteSource: projectedMuteSource
    )

    let persistenceResult: AcceptedIntentPersistenceResult
    if backendResult.outcome == .applied || backendResult.outcome == .noChange {
      confirmedEqualizerByLogicalID[appID] = intent.equalizerSettings
      persistenceResult = await persistAcceptedAppIntent(
        intent,
        result: backendResult,
        policy: persistencePolicy,
        deviceIDAtSubmission: deviceIDAtSubmission
      )
    } else {
      persistenceResult = .notRequested
    }

    let refreshedDiagnostics = await backend.diagnosticsReport()
    let captureAuthorization = await backend.captureAuthorizationResult()
    if currentAppIntentGeneration[appID] == intent.generation {
      diagnostics = refreshedDiagnostics
      onboarding.captureAuthorization = captureAuthorization
      syncOnboarding(using: session)
      presentAppIntentFeedback(
        backendResult,
        persistenceResult: persistenceResult,
        policy: feedbackPolicy
      )
      appIntentTasks.removeValue(forKey: appID)
    }
    return backendResult
  }

  private func reconcileAppIntentResult(
    _ result: AppIntentApplyResult,
    intent: AppRouteIntent,
    projectedMuteSource: MuteSource?
  ) {
    session.backendStatus = result.backendStatus
    if var resultingApp = result.resultingApp {
      let cachedMuteSource = session.apps
        .first(matchingAppKey: intent.appID)?.muteSource
      confirmedAppsByLogicalID[resultingApp.logicalID] = resultingApp
      resultingApp.isPinned = preferences.pinnedAppIDs.contains(resultingApp.logicalID)
      if resultingApp.isMuted {
        let accepted = result.outcome == .applied || result.outcome == .noChange
        resultingApp.muteSource = intent.reason == .automation && !accepted
          ? (cachedMuteSource ?? resultingApp.muteSource)
          : (projectedMuteSource ?? resultingApp.muteSource)
      } else {
        resultingApp.muteSource = .user
      }
      if preferences.excludedAppIDs.contains(resultingApp.logicalID)
        || result.outcome == .excluded {
        makeExcludedPresentation(&resultingApp)
      }
      if let index = session.apps.firstIndex(matchingAppKey: intent.appID) {
        session.apps[index] = resultingApp
      } else {
        session.apps.append(resultingApp)
      }
    } else if result.outcome == .unavailable {
      session.apps.removeAll { $0.logicalID == intent.appID || $0.id == intent.appID }
      confirmedAppsByLogicalID.removeValue(forKey: intent.appID)
    }
    applyPendingVolumeProjection(forAppID: intent.appID)
    invalidateVisibleAppsCache()
    syncOnboarding(using: session)
    persistSessionSnapshot()
  }

  private func applyOptimisticProjection(
    _ projection: AppIntentProjection,
    toAppID appID: String
  ) {
    guard let index = session.apps.firstIndex(matchingAppKey: appID) else { return }
    if projection.intent.isExcluded {
      makeExcludedPresentation(&session.apps[index])
    } else {
      session.apps[index].desiredVolume = projection.intent.desiredVolume
      session.apps[index].isMuted = projection.intent.isMuted
      session.apps[index].volumeBoost = projection.intent.volumeBoost
      session.apps[index].targetDeviceUID = projection.intent.targetDeviceUID
      session.apps[index].muteSource = projection.muteSource ?? session.apps[index].muteSource
      if session.apps[index].routingState == .managed {
        session.apps[index].appliedVolume = projection.intent.isMuted
          ? 0
          : projection.intent.desiredVolume
      }
    }
    invalidateVisibleAppsCache()
  }

  private func applyPendingVolumeProjection(forAppID appID: String) {
    guard let target = pendingVolumeTargets[appID],
          let index = session.apps.firstIndex(matchingAppKey: appID),
          !preferences.excludedAppIDs.contains(appID) else { return }
    session.apps[index].desiredVolume = target
    if session.apps[index].routingState == .managed {
      session.apps[index].appliedVolume = session.apps[index].isMuted ? 0 : target
    }
  }

  private func makeExcludedPresentation(_ app: inout AudioApp) {
    app.desiredVolume = 1
    app.appliedVolume = nil
    app.isMuted = false
    app.volumeBoost = 1
    app.muteSource = .user
    app.targetDeviceUID = nil
    app.routingState = .monitorOnly
    app.peakLevel = 0
    app.rmsLevel = 0
    app.notes = nil
  }

  private func persistAcceptedAppIntent(
    _ intent: AppRouteIntent,
    result: AppIntentApplyResult,
    policy: AppIntentPersistencePolicy,
    deviceIDAtSubmission: String?
  ) async -> AcceptedIntentPersistenceResult {
    guard case let .acceptedUserIntent(updateDevicePreset) = policy else {
      return .notRequested
    }

    let appID = intent.appID
    let acceptedApp = result.resultingApp
    let durableIntent = PersistedAppAudioIntent(
      appID: appID,
      desiredVolume: acceptedApp?.desiredVolume ?? intent.desiredVolume,
      isMuted: acceptedApp?.isMuted ?? intent.isMuted,
      volumeBoost: acceptedApp?.volumeBoost ?? intent.volumeBoost,
      equalizerSettings: intent.equalizerSettings,
      targetDeviceUID: acceptedApp?.targetDeviceUID ?? intent.targetDeviceUID
    )
    durableIntentMutationGeneration[appID] = intent.generation
    preferences.appAudioIntents[appID] = durableIntent
    preferences.appEqualizerSettings[appID] = durableIntent.equalizerSettings
    invalidateVisibleAppsCache()

    do {
      try await savePreferencesDurably()
    } catch {
      if durableIntentMutationGeneration[appID] == intent.generation {
        if let savedIntent = durablySavedPreferences.appAudioIntents[appID] {
          preferences.appAudioIntents[appID] = savedIntent
        } else {
          preferences.appAudioIntents.removeValue(forKey: appID)
        }
        if let savedEqualizer = durablySavedPreferences.appEqualizerSettings[appID] {
          preferences.appEqualizerSettings[appID] = savedEqualizer
        } else {
          preferences.appEqualizerSettings.removeValue(forKey: appID)
        }
        durableIntentMutationGeneration.removeValue(forKey: appID)
      }
      reportPersistenceFailure(storeName: "settings", error: error, showWarning: false)
      return .settingsFailed(error.localizedDescription)
    }
    guard durableIntentMutationGeneration[appID] == intent.generation else {
      // A newer accepted transaction now owns durable and preset persistence.
      return .saved
    }
    durableIntentMutationGeneration.removeValue(forKey: appID)

    guard updateDevicePreset,
          preferences.enablePerDeviceVolumePresets,
          let deviceID = deviceIDAtSubmission else {
      return .saved
    }

    let mutationKey = "\(deviceID)\u{0}\(appID)"
    devicePresetMutationGeneration[mutationKey] = intent.generation
    deviceVolumePresets.saveVolumeSettings(
      for: appID,
      deviceID: deviceID,
      settings: AppVolumeSettings(
        desiredVolume: durableIntent.desiredVolume,
        isMuted: durableIntent.isMuted,
        volumeBoost: durableIntent.volumeBoost
      )
    )
    do {
      try await saveDeviceVolumePresetsDurably()
    } catch {
      if devicePresetMutationGeneration[mutationKey] == intent.generation {
        if let savedPreset = durablySavedDeviceVolumePresets
          .getVolumeSettings(for: appID, deviceID: deviceID) {
          deviceVolumePresets.saveVolumeSettings(
            for: appID,
            deviceID: deviceID,
            settings: savedPreset
          )
        } else {
          deviceVolumePresets.deviceVolumes[deviceID]?.removeValue(forKey: appID)
          if deviceVolumePresets.deviceVolumes[deviceID]?.isEmpty == true {
            deviceVolumePresets.deviceVolumes.removeValue(forKey: deviceID)
          }
        }
        devicePresetMutationGeneration.removeValue(forKey: mutationKey)
      }
      reportPersistenceFailure(storeName: "device presets", error: error, showWarning: false)
      return .devicePresetFailed(error.localizedDescription)
    }
    if devicePresetMutationGeneration[mutationKey] == intent.generation {
      devicePresetMutationGeneration.removeValue(forKey: mutationKey)
    }
    return .saved
  }

  private func presentAppIntentFeedback(
    _ result: AppIntentApplyResult,
    persistenceResult: AcceptedIntentPersistenceResult,
    policy: AppIntentFeedbackPolicy
  ) {
    switch persistenceResult {
    case let .settingsFailed(detail):
      showToast(
        title: "Applied, but could not save",
        detail: detail,
        kind: .warning
      )
      return
    case let .devicePresetFailed(detail):
      showToast(
        title: "Applied, but device preset was not saved",
        detail: detail,
        kind: .warning
      )
      return
    case .notRequested, .saved:
      break
    }

    switch policy {
    case .none:
      return
    case let .directControl(successTitle, successDetail, failureTitle):
      switch result.outcome {
      case .applied, .noChange:
        guard result.resultingApp?.routingState == .managed else { return }
        if !successTitle.isEmpty {
          showToast(
            title: successTitle,
            detail: successDetail,
            kind: .success,
            duration: .seconds(1.2)
          )
        }
      case .superseded:
        return
      case .excluded:
        showToast(title: failureTitle, detail: "This app is excluded from Waves.", kind: .warning)
      case .unavailable:
        showToast(title: failureTitle, detail: result.detail ?? "The app is no longer available.", kind: .warning)
      case .unsupported:
        showToast(title: failureTitle, detail: result.detail, kind: .warning)
      case .failed:
        showToast(title: failureTitle, detail: result.detail, kind: .error)
      }
    case let .exclusion(appName, announce):
      guard announce else { return }
      if result.outcome == .excluded {
        showToast(
          title: "Excluded from Waves",
          detail: appName,
          kind: .info,
          duration: .seconds(1.4)
        )
      } else if result.outcome != .superseded {
        showToast(title: "Couldn’t exclude \(appName)", detail: result.detail, kind: .error)
      }
    case let .reinclusion(appName, announce):
      guard announce else { return }
      if (result.outcome == .applied || result.outcome == .noChange),
         result.resultingApp?.routingState == .managed {
        showToast(
          title: "Managed by Waves",
          detail: appName,
          kind: .success,
          duration: .seconds(1.4)
        )
      } else if result.outcome != .superseded {
        showToast(
          title: "Couldn’t manage \(appName)",
          detail: result.detail ?? "A managed audio route is not available.",
          kind: result.outcome == .failed ? .error : .warning
        )
      }
    }
  }

  private func supersedeAppIntentWork(forAppID appID: String) {
    appIntentTasks[appID]?.cancel()
    appIntentTasks.removeValue(forKey: appID)
    currentAppIntentGeneration[appID] = Self.allocateAppIntentGeneration()
    optimisticAppIntentProjections.removeValue(forKey: appID)
  }

  func setDesiredVolume(_ value: Float, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    let appID = app.logicalID
    guard session.apps.firstIndex(matchingAppKey: appID) != nil else {
      showToast(
        title: "Volume change blocked",
        detail: BackendError.appNotFound(app.id).localizedDescription,
        kind: .warning
      )
      return
    }

    pendingVolumeTargets[appID] = max(0, min(1, value))
    applyPendingVolumeProjection(forAppID: appID)
    invalidateVisibleAppsCache()
  }

  func commitDesiredVolume(for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    let appID = app.logicalID
    let target = pendingVolumeTargets.removeValue(forKey: appID)
      ?? session.apps.first(matchingAppKey: appID)?.desiredVolume
      ?? app.desiredVolume
    startAppIntentTransaction(
      forAppID: appID,
      overrides: AppIntentOverrides(desiredVolume: target),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: true),
      feedbackPolicy: .directControl(
        successTitle: "Managed route active",
        successDetail: "\(app.displayName) set to \(Int(target * 100))%",
        failureTitle: "Volume change failed"
      ),
      optimistic: true
    )
  }

  private func cleanupStaleEntries() {
    let currentAppIDs = Set(session.apps.map(\.logicalID))
    let staleIDs = Set(currentAppIntentGeneration.keys).subtracting(currentAppIDs)
    for appID in staleIDs {
      supersedeAppIntentWork(forAppID: appID)
      currentAppIntentGeneration.removeValue(forKey: appID)
      confirmedAppsByLogicalID.removeValue(forKey: appID)
    }
    pendingVolumeTargets = pendingVolumeTargets.filter { currentAppIDs.contains($0.key) }
    pendingEqualizerSettings = pendingEqualizerSettings.filter { currentAppIDs.contains($0.key) }
    let staleEqualizerIDs = pendingEqualizerDebounceTasks.keys.filter {
      !currentAppIDs.contains($0)
    }
    for appID in staleEqualizerIDs {
      pendingEqualizerDebounceTasks[appID]?.cancel()
      pendingEqualizerDebounceTasks.removeValue(forKey: appID)
    }
    pausedMusicApps = pausedMusicApps.filter { currentAppIDs.contains($0) }
  }

  func setMuted(_ isMuted: Bool, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    if !isMuted { pausedMusicApps.remove(app.logicalID) }
    startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(isMuted: isMuted, muteSource: .user),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: true),
      feedbackPolicy: .directControl(
        successTitle: isMuted ? "App muted" : "App unmuted",
        successDetail: app.displayName,
        failureTitle: "Mute toggle failed"
      ),
      optimistic: true
    )
  }

  func setVolumeBoost(_ boost: Float, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    let clampedBoost = max(1, min(4, boost))
    startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(volumeBoost: clampedBoost),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: true),
      feedbackPolicy: .directControl(
        successTitle: "Boost updated",
        successDetail: "\(app.displayName): \(String(format: "%g", clampedBoost))x",
        failureTitle: "Boost update failed"
      ),
      optimistic: true
    )
  }

  // MARK: - Per-app equalizer and adaptive mixing

  func equalizerSettings(for app: AudioApp) -> EqualizerSettings {
    if let pending = pendingEqualizerSettings[app.logicalID] {
      return pending
    }
    if let projection = optimisticAppIntentProjections[app.logicalID],
       currentAppIntentGeneration[app.logicalID] == projection.generation {
      return projection.intent.equalizerSettings
    }
    return confirmedEqualizerByLogicalID[app.logicalID]
      ?? preferences.appAudioIntents[app.logicalID]?.equalizerSettings
      ?? preferences.appEqualizerSettings[app.logicalID]
      ?? EqualizerSettings()
  }

  func setEqualizerEnabled(_ enabled: Bool, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.isEnabled = enabled
    }
  }

  func setEqualizerMode(_ mode: EqualizerMode, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.mode = mode
    }
  }

  func setEqualizerGain(_ gainDB: Float, at index: Int, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.isEnabled = true
      settings.setGain(gainDB, at: index)
    }
  }

  func applyEqualizerPreset(_ preset: EqualizerPreset, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.isEnabled = true
      settings.applyPreset(preset)
    }
  }

  func resetEqualizer(for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.resetActiveMode()
    }
  }

  func setAdaptiveRole(_ role: AdaptiveAppRole, for app: AudioApp) {
    updateEqualizerSettings(for: app) { settings in
      settings.adaptiveRole = role
    }
  }

  func setAdaptiveMixMode(_ mode: AdaptiveMixMode) {
    guard requireAudioRunning() else { return }
    guard preferences.adaptiveMixMode != mode else { return }
    preferences.adaptiveMixMode = mode
    if mode.usesSpeechFocus {
      // The legacy frontmost-app behavior fully mutes media. It cannot run at
      // the same time as speech ducking without defeating the new mix.
      preferences.autoPauseMusicForConferencing = false
      previousFrontmostApp = nil
      checkAutoPauseMusic()
    }
    persistPreferences()
    restartAdaptiveMixing()
    showToast(
      title: "Adaptive Mix",
      detail: mode.displayName,
      kind: mode == .off ? .info : .success,
      duration: .seconds(1.4)
    )
  }

  private func updateEqualizerSettings(
    for app: AudioApp,
    mutation: (inout EqualizerSettings) -> Void
  ) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    var settings = equalizerSettings(for: app)
    mutation(&settings)
    pendingEqualizerSettings[app.logicalID] = settings
    scheduleEqualizerTransaction(settings, for: app)
  }

  private func scheduleEqualizerTransaction(_ settings: EqualizerSettings, for app: AudioApp) {
    let appID = app.logicalID
    pendingEqualizerDebounceTasks[appID]?.cancel()
    pendingEqualizerDebounceTasks[appID] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(80))
      } catch {
        return
      }
      guard let self, !Task.isCancelled,
            self.pendingEqualizerSettings[appID] == settings else { return }
      self.pendingEqualizerSettings.removeValue(forKey: appID)
      self.pendingEqualizerDebounceTasks.removeValue(forKey: appID)
      self.startAppIntentTransaction(
        forAppID: appID,
        overrides: AppIntentOverrides(equalizerSettings: settings),
        reason: .userEdit,
        persistencePolicy: .acceptedUserIntent(updateDevicePreset: false),
        feedbackPolicy: .directControl(
          successTitle: "",
          successDetail: nil,
          failureTitle: "EQ not active"
        ),
        optimistic: true
      )
    }
  }

  private func restartAdaptiveMixing() {
    guard startupState == .running else { return }
    adaptiveMixTask?.cancel()
    adaptiveMixTask = nil

    guard preferences.adaptiveMixMode != .off else {
      speechDetectionStates.removeAll()
      speechDuckingStates.removeAll()
      loudnessTrimStates.removeAll()
      startOwnedOperation { store in
        await store.backend.setAdaptiveGains([:])
      }
      return
    }

    adaptiveMixTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.performAdaptiveMixPass(elapsed: 0.1)
        guard !Task.isCancelled else { break }
        try? await Task.sleep(for: self.adaptiveMixInterval)
      }
      await self.backend.setAdaptiveGains([:])
    }
  }

  private func performAdaptiveMixPass(elapsed: TimeInterval) async {
    guard startupState == .running else { return }
    let analysis = await backend.adaptiveAnalysis()
    guard !Task.isCancelled, preferences.adaptiveMixMode != .off else { return }

    let mode = preferences.adaptiveMixMode
    let apps = visibleApps
    let liveIDs = Set(apps.map(\.logicalID))
    speechDetectionStates = speechDetectionStates.filter { liveIDs.contains($0.key) }
    speechDuckingStates = speechDuckingStates.filter { liveIDs.contains($0.key) }
    loudnessTrimStates = loudnessTrimStates.filter { liveIDs.contains($0.key) }

    var speechIsActive = false
    if mode.usesSpeechFocus {
      for app in apps {
        let settings = equalizerSettings(for: app)
        guard AdaptiveMixing.resolvedRole(settings.adaptiveRole, category: app.category) == .voice,
              let levels = analysis[app.logicalID],
              !app.isMuted else { continue }
        var state = speechDetectionStates[app.logicalID] ?? SpeechDetectionState()
        let isActive = state.update(
          fullBandRMS: Double(levels.rms),
          voiceBandEnergy: Double(levels.voiceBandEnergy),
          elapsed: elapsed
        )
        speechDetectionStates[app.logicalID] = state
        speechIsActive = speechIsActive || isActive
      }
    } else {
      speechDetectionStates.removeAll()
    }

    var gainsDB: [String: Float] = [:]
    gainsDB.reserveCapacity(apps.count)
    for app in apps {
      let settings = equalizerSettings(for: app)
      let levels = analysis[app.logicalID]
      let routeIsActive = app.routingState == .managed && levels != nil && !app.isMuted

      var duck = speechDuckingStates[app.logicalID] ?? SpeechDuckingState()
      let duckGain = duck.update(
        isSpeechActive: speechIsActive,
        isEligible: mode.usesSpeechFocus
          && routeIsActive
          && AdaptiveMixing.isSpeechDuckEligible(role: settings.adaptiveRole, category: app.category),
        elapsed: elapsed
      )
      speechDuckingStates[app.logicalID] = duck

      var loudness = loudnessTrimStates[app.logicalID] ?? LoudnessTrimState()
      let loudnessGain = loudness.update(
        rms: Double(levels?.rms ?? 0),
        isEligible: mode.usesLoudnessBalance
          && routeIsActive
          && AdaptiveMixing.isLoudnessBalanceEligible(role: settings.adaptiveRole, category: app.category),
        elapsed: elapsed
      )
      loudnessTrimStates[app.logicalID] = loudness

      gainsDB[app.logicalID] = Float(AdaptiveMixing.combinedGainDB(
        mode: mode,
        role: settings.adaptiveRole,
        category: app.category,
        speechDuckDB: duckGain,
        loudnessTrimDB: loudnessGain
      ))
    }

    guard !Task.isCancelled, startupState == .running,
          preferences.adaptiveMixMode == mode else { return }
    await backend.setAdaptiveGains(gainsDB)
  }

  func togglePinned(_ app: AudioApp) {
    guard requireAudioRunning() else { return }
    let appName = app.displayName
    let appKey = app.logicalID
    let willPin = !preferences.pinnedAppIDs.contains(appKey)

    // Pin state lives in preferences (authoritative + persisted), so it survives
    // the app quitting/relaunching and a full relaunch of Waves.
    if willPin {
      preferences.pinnedAppIDs.append(appKey)
    } else {
      preferences.pinnedAppIDs.removeAll { $0 == appKey }
    }
    persistPreferences()

    // Optimistically mirror onto the session row for immediate feedback (and so
    // any code reading session.apps directly agrees); visibleApps reconciles too.
    if let index = session.apps.firstIndex(matchingAppKey: appKey) {
      session.apps[index].isPinned = willPin
      invalidateVisibleAppsCache()
    }

    // Keep the backend snapshot in step on a best-effort basis; preferences
    // remains the source of truth, so a backend failure can't lose the pin.
    startOwnedOperation { store in
      try? await store.backend.pinApp(willPin, appID: appKey)
      guard !Task.isCancelled, store.startupState == .running else { return }
      store.persistSessionSnapshot()
    }

    showToast(
      title: willPin ? "Pinned to top" : "Unpinned",
      detail: appName,
      kind: .info,
      duration: .seconds(1.2)
    )
  }

  // MARK: - Live level metering (visibility-gated)

  /// Call when a mixer surface becomes visible. Reference-counted so multiple
  /// open surfaces (main window + menu bar) share one poller, and polling stops
  /// entirely when nothing is on screen (keeps idle CPU near zero).
  func beginLiveLevels() {
    guard startupState != .shuttingDown else { return }
    liveLevelsRefcount += 1
    startLiveLevelPollingIfNeeded()
  }

  private func startLiveLevelPollingIfNeeded() {
    guard startupState == .running, liveLevelsRefcount > 0 else { return }
    guard levelPollTask == nil else { return }
    levelPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(300))
        guard let self, !Task.isCancelled, self.startupState == .running else { return }
        let levels = await self.backend.audioLevels()
        // Re-check after the await (the poll may have been cancelled while
        // suspended). Skip the no-op level assignment to avoid needless redraws,
        // but always reconcile the lingering-live set so a just-silenced app is
        // scheduled to drop out — and a returning one is kept — every tick.
        guard !Task.isCancelled, self.startupState == .running else { return }
        if levels != self.liveLevels {
          self.liveLevels = levels
        }
        self.refreshLiveLinger()
      }
    }
  }

  /// Reconciles `recentlyLiveIDs` against who is audible right now. Apps that just
  /// started playing are added immediately (any pending removal cancelled); apps
  /// that just went quiet get a one-shot task that drops them after
  /// `liveLingerWindow`. Mutates the observed set only when membership actually
  /// changes, so a steady scene triggers no redraws.
  private func refreshLiveLinger() {
    let liveNow = Set(visibleApps.lazy.filter(isLive).map(\.logicalID))
    var next = recentlyLiveIDs

    // Audible now: keep it, and cancel any pending "drop it" task.
    for id in liveNow {
      if let task = lingerRemovalTasks.removeValue(forKey: id) { task.cancel() }
      next.insert(id)
    }

    // Lingering but no longer audible: schedule a single delayed removal.
    for id in next where !liveNow.contains(id) && lingerRemovalTasks[id] == nil {
      let window = liveLingerWindow
      lingerRemovalTasks[id] = Task { [weak self] in
        try? await Task.sleep(for: window)
        guard let self, !Task.isCancelled else { return }
        self.lingerRemovalTasks.removeValue(forKey: id)
        if self.recentlyLiveIDs.contains(id) {
          self.recentlyLiveIDs.remove(id)
        }
      }
    }

    if next != recentlyLiveIDs { recentlyLiveIDs = next }
  }

  func endLiveLevels() {
    liveLevelsRefcount = max(0, liveLevelsRefcount - 1)
    guard liveLevelsRefcount == 0 else { return }
    levelPollTask?.cancel()
    levelPollTask = nil
    liveLevels = [:]
    // No more poll ticks will arrive, so cancel pending linger removals and clear
    // the set rather than leave a stale "live" row frozen on a hidden surface.
    for task in lingerRemovalTasks.values { task.cancel() }
    lingerRemovalTasks.removeAll()
    recentlyLiveIDs = []
  }

  // MARK: - Per-app output routing

  func targetDevice(for app: AudioApp) -> AudioDevice? {
    guard let uid = app.targetDeviceUID else { return nil }
    return availableDevices.first { $0.id == uid }
  }

  /// Routes an app to a specific output device, or nil to follow the system
  /// default. The choice becomes durable only after the backend accepts it.
  func setOutputDevice(_ device: AudioDevice?, for app: AudioApp) {
    guard requireAudioRunning() else { return }
    guard !isExcluded(app) else { return }
    startAppIntentTransaction(
      forAppID: app.logicalID,
      overrides: AppIntentOverrides(
        targetDeviceUID: device?.id,
        replacesTargetDevice: true
      ),
      reason: .userEdit,
      persistencePolicy: .acceptedUserIntent(updateDevicePreset: false),
      feedbackPolicy: .directControl(
        successTitle: "Output set",
        successDetail: "\(app.displayName) → \(device?.name ?? "System default")",
        failureTitle: "Couldn't route \(app.displayName)"
      ),
      optimistic: true
    )
  }

  // MARK: - Exclusions (don't-tap escape hatch)

  func isExcluded(_ app: AudioApp) -> Bool {
    preferences.excludedAppIDs.contains(app.logicalID)
  }

  /// Excludes or re-includes an app from Waves' management. Excluded apps are
  /// never tapped, so their audio is left completely untouched — the escape
  /// hatch for DAWs, conferencing/echo-cancellation apps, and other audio tools
  /// that misbehave when their output is tapped.
  ///
  /// `showToast` is `false` only when called from `excludeUnroutableApps`,
  /// which shows one combined toast instead of one per app.
  func setExcluded(_ excluded: Bool, for app: AudioApp, showToast: Bool = true) {
    guard requireAudioRunning() else { return }
    let appID = app.logicalID
    var ids = Set(preferences.excludedAppIDs)
    if excluded {
      ids.insert(appID)
    } else {
      ids.remove(appID)
    }
    preferences.excludedAppIDs = Array(ids).sorted()
    persistPreferences()

    pendingVolumeTargets.removeValue(forKey: appID)
    pendingEqualizerSettings.removeValue(forKey: appID)
    pendingEqualizerDebounceTasks[appID]?.cancel()
    pendingEqualizerDebounceTasks.removeValue(forKey: appID)
    supersedeAppIntentWork(forAppID: appID)
    speechDetectionStates.removeValue(forKey: appID)
    speechDuckingStates.removeValue(forKey: appID)
    loudnessTrimStates.removeValue(forKey: appID)
    pausedMusicApps.remove(appID)

    if excluded {
      startAppIntentTransaction(
        forAppID: appID,
        overrides: AppIntentOverrides(isExcluded: true, muteSource: .user),
        reason: .userEdit,
        persistencePolicy: .none,
        feedbackPolicy: .exclusion(appName: app.displayName, announce: showToast),
        optimistic: true
      )
    } else {
      let overrides = effectiveRestorationOverrides(
        forAppID: appID,
        deviceID: currentDeviceID,
        includeDevicePreset: preferences.enablePerDeviceVolumePresets
      ) ?? AppIntentOverrides(isExcluded: false, muteSource: .user)
      startAppIntentTransaction(
        forAppID: appID,
        overrides: overrides,
        reason: .routeRecovery,
        persistencePolicy: .none,
        feedbackPolicy: .reinclusion(appName: app.displayName, announce: showToast),
        optimistic: false
      )
    }
    invalidateVisibleAppsCache()
  }

  /// Excludes every app in `apps` that does not expose a manageable audio stream
  /// (see `AudioApp.hasNoAudioCapability`) in one action, instead of requiring
  /// a right-click per row. Scoped to the apps passed in (the caller's current
  /// visible list) rather than the whole session.
  func excludeUnroutableApps(_ apps: [AudioApp]) {
    guard requireAudioRunning() else { return }
    let targets = apps.filter { $0.routingState == .error && $0.hasNoAudioCapability && !isExcluded($0) }
    guard !targets.isEmpty else { return }
    for app in targets {
      setExcluded(true, for: app, showToast: false)
    }
    showToast(
      title: "Excluded from Waves",
      detail: targets.count == 1 ? targets[0].displayName : "\(targets.count) apps without manageable audio streams",
      kind: .info,
      duration: .seconds(1.4)
    )
  }

  /// A bounded, deterministic plain-text snapshot suitable for a bug report.
  /// Potentially identifying fields are marked in the output, and live audio
  /// levels/samples are deliberately excluded.
  var diagnosticsExportText: String {
    DiagnosticsExportFormatter.format(
      metadata: .current,
      captureAuthorization: onboarding.captureAuthorization,
      session: session,
      apps: visibleApps,
      availableOutputDeviceCount: availableDevices.count,
      diagnostics: diagnostics,
      persistenceFailureCount: persistenceFailureCount,
      lastPersistenceError: lastPersistenceError,
      shutdownResult: shutdownResult
    )
  }

  func refreshOutputDevices() {
    guard requireAudioRunning() else { return }
    startOwnedOperation { store in
      let devices = await store.backend.availableOutputDevices()
      guard !Task.isCancelled, store.startupState == .running else { return }
      store.availableDevices = devices
    }
  }

  func selectOutputDevice(_ device: AudioDevice) {
    guard requireAudioRunning() else { return }
    guard device.id != currentDeviceID else { return }
    // Mark this switch as self-initiated so the device-change listener's
    // handleDeviceChange skips its duplicate "Output device changed" info toast.
    pendingSelfInitiatedDeviceID = device.id
    startOwnedOperation { store in
      do {
        try await store.backend.setDefaultOutputDevice(uid: device.id)
        let devices = await store.backend.availableOutputDevices()
        guard !Task.isCancelled, store.startupState == .running else { return }
        store.availableDevices = devices
        store.showToast(title: "Output switched", detail: device.name, kind: .success, duration: .seconds(1.4))
      } catch {
        guard store.startupState == .running else { return }
        store.pendingSelfInitiatedDeviceID = nil
        store.showToast(title: "Couldn't switch output", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func copyDiagnosticsToPasteboard() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(diagnosticsExportText, forType: .string)
    showToast(title: "Diagnostics copied", detail: "Paste into a bug report.", kind: .success, duration: .seconds(1.4))
  }

  private func observeDeviceChanges() {
    guard deviceChangeObserver == nil else { return }
    let events = backend.deviceChangeEvents
    deviceChangeObserver = Task { [weak self] in
      for await _ in events {
        guard let self else { return }
        self.handleDeviceChange()
      }
    }
  }

  func handleDeviceChange() {
    guard startupState == .running else { return }
    // Coalesce overlapping events instead of dropping them: a device-change in
    // flight already reassigns `session` and (optionally) walks
    // restoreDeviceVolumePresets across backend awaits; a second concurrent
    // pass would interleave those reassignments and restores. So we never run two
    // passes at once. But dropping the second event outright could leave the UI on the
    // earlier snapshot/device-list/onboarding (rapid dock/undock, Bluetooth
    // reconnect) until some unrelated refresh. Instead, record a pending rerun and
    // let the in-flight handler run exactly one more pass once it finishes.
    guard !isHandlingDeviceChange else {
      pendingDeviceChangeRerun = true
      return
    }
    isHandlingDeviceChange = true
    let started = startOwnedOperation { store in
      defer { store.isHandlingDeviceChange = false }
      repeat {
        store.pendingDeviceChangeRerun = false
        await store.performDeviceChangePass()
      } while !Task.isCancelled
        && store.startupState == .running
        && store.pendingDeviceChangeRerun
    }
    if !started {
      isHandlingDeviceChange = false
    }
  }

  private func performDeviceChangePass() async {
      // The lightweight refresh below must run on EVERY device-change event:
      // session.currentDevice, the device list, diagnostics, and onboarding would
      // otherwise go stale (picker label / checkmark stuck on the old device)
      // until some unrelated event refreshes them. This shared state sync is
      // unconditional; only per-device preset restore is gated, on its own toggle.
      //
      // The backend has already re-established managed routes before emitting the
      // event, so read the current snapshot rather than restoring again.
      let previousDeviceID = currentDeviceID
      // Merge cached-only fields (like the .autoConferencing muteSource tag,
      // which the backend never knows about) instead of reassigning wholesale
      // — a bare reassignment resets muteSource to .user, so auto-paused
      // media could never auto-resume after a device change.
      let backendSnapshot = await backend.currentSnapshot()
      guard !Task.isCancelled, startupState == .running else { return }
      session = mergedSession(with: backendSnapshot, cached: session)
      invalidateVisibleAppsCache()

      // Per-device preset restore additionally requires "Auto-restore device" —
      // it IS the auto-restore behavior for saved per-app volumes, so honoring
      // the per-device-presets toggle alone while ignoring the opt-out would
      // restore levels the user explicitly asked Waves not to apply automatically.
      if preferences.enablePerDeviceVolumePresets, preferences.autoRestoreDevice,
         let newDeviceID = currentDeviceID, previousDeviceID != newDeviceID {
        await restoreDeviceVolumePresets(for: newDeviceID)
      }

      persistSessionSnapshot()
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      availableDevices = await backend.availableOutputDevices()
      syncOnboarding(using: session)
      let didDefaultDeviceChange = previousDeviceID != currentDeviceID

      // Suppress the info toast when this change was triggered by our own
      // selectOutputDevice (which already showed an "Output switched" success
      // toast). Clearing the flag here makes it one-shot, so the next genuinely
      // external device change still announces itself.
      let wasSelfInitiated = didDefaultDeviceChange && pendingSelfInitiatedDeviceID == currentDeviceID
      if didDefaultDeviceChange {
        pendingSelfInitiatedDeviceID = nil
      }
      if didDefaultDeviceChange && !wasSelfInitiated {
        showToast(
          title: "Output device changed",
          detail: currentDeviceName,
          kind: .info,
          duration: .seconds(1.5)
        )
      }
  }

  private func effectiveRestorationOverrides(
    forAppID appID: String,
    deviceID: String?,
    includeDevicePreset: Bool
  ) -> AppIntentOverrides? {
    guard let durable = preferences.appAudioIntents[appID] else { return nil }
    var desiredVolume = durable.desiredVolume
    var isMuted = durable.isMuted
    var volumeBoost = durable.volumeBoost
    if includeDevicePreset,
       let deviceID,
       let preset = deviceVolumePresets.getVolumeSettings(for: appID, deviceID: deviceID) {
      desiredVolume = preset.desiredVolume
      isMuted = preset.isMuted
      volumeBoost = preset.volumeBoost
    }
    return AppIntentOverrides(
      desiredVolume: desiredVolume,
      isMuted: isMuted,
      volumeBoost: volumeBoost,
      equalizerSettings: durable.equalizerSettings,
      targetDeviceUID: durable.targetDeviceUID,
      replacesTargetDevice: true,
      isExcluded: false,
      muteSource: .user
    )
  }

  private func restoreConfiguredApp(
    appID: String,
    defaultReason: AppRouteIntentReason,
    deviceID: String?,
    includeDevicePreset: Bool
  ) async -> AppIntentApplyResult? {
    guard !preferences.excludedAppIDs.contains(appID),
          session.apps.contains(where: { $0.logicalID == appID }),
          let overrides = effectiveRestorationOverrides(
            forAppID: appID,
            deviceID: deviceID,
            includeDevicePreset: includeDevicePreset
          ) else { return nil }
    let hasPreset = includeDevicePreset
      && deviceID.map {
        deviceVolumePresets.getVolumeSettings(for: appID, deviceID: $0) != nil
      } == true
    return await startAppIntentTransaction(
      forAppID: appID,
      overrides: overrides,
      reason: hasPreset ? .devicePresetRestore : defaultReason,
      persistencePolicy: .none,
      feedbackPolicy: .none,
      optimistic: false
    ).value
  }

  private func reapplyRestoredAudioState() async {
    // Automatic conferencing mutes are session-only. Startup restoration always
    // begins from the committed durable user intent instead.
    for index in session.apps.indices where session.apps[index].muteSource == .autoConferencing {
      session.apps[index].muteSource = .user
    }
    pausedMusicApps.removeAll()

    let deviceID = currentDeviceID
    let includePreset = preferences.enablePerDeviceVolumePresets
      && preferences.autoRestoreDevice
    var failedPinnedAppIDs: [String] = []
    for appID in session.apps.map(\.logicalID) {
      guard let result = await restoreConfiguredApp(
        appID: appID,
        defaultReason: .startupRestore,
        deviceID: deviceID,
        includeDevicePreset: includePreset
      ) else { continue }
      let accepted = result.outcome == .applied || result.outcome == .noChange
      if !accepted, preferences.appAudioIntents[appID]?.targetDeviceUID != nil {
        failedPinnedAppIDs.append(appID)
      }
    }

    if !failedPinnedAppIDs.isEmpty {
      let count = failedPinnedAppIDs.count
      showToast(
        title: "Some pinned routes could not be restored",
        detail: count == 1
          ? "1 app couldn't be re-pinned to its saved output device."
          : "\(count) apps couldn't be re-pinned to their saved output devices.",
        kind: .error
      )
    }
  }

  private func restoreNewlyAppearedConfiguredApps(excluding knownAppIDs: Set<String>) async {
    let newAppIDs = session.apps.map(\.logicalID).filter { !knownAppIDs.contains($0) }
    guard !newAppIDs.isEmpty else { return }
    let includePreset = preferences.enablePerDeviceVolumePresets
      && preferences.autoRestoreDevice
    for appID in newAppIDs {
      _ = await restoreConfiguredApp(
        appID: appID,
        defaultReason: .startupRestore,
        deviceID: currentDeviceID,
        includeDevicePreset: includePreset
      )
    }
  }

  private func restoreDeviceVolumePresets(for deviceID: String) async {
    for appID in session.apps.map(\.logicalID) {
      _ = await restoreConfiguredApp(
        appID: appID,
        defaultReason: .deviceChange,
        deviceID: deviceID,
        includeDevicePreset: true
      )
    }
  }

  private struct ShutdownSettlingTasks {
    let mutationTasks: [Task<Void, Never>]
    let appIntentTasks: [Task<AppIntentApplyResult, Never>]
    let persistenceTasks: [Task<Void, Never>]
  }

  func shutdown() async -> AppShutdownResult {
    if let shutdownResult { return shutdownResult }
    if let shutdownTask { return await shutdownTask.value }

    // The lifecycle transition and cancellation publication are synchronous on
    // MainActor. Every public audio/profile/device/automation gate observes this
    // state before this method reaches its first suspension.
    startupState = .shuttingDown
    let settlingTasks = prepareForShutdown()
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return AppShutdownResult(
          persistenceDegradations: ["AppStore was released before shutdown could be verified."]
        )
      }
      return await self.performShutdown(settlingTasks: settlingTasks)
    }
    shutdownTask = task
    return await task.value
  }

  private func prepareForShutdown() -> ShutdownSettlingTasks {
    if let frontmostAppObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
      self.frontmostAppObserver = nil
    }
    if let appTerminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
      self.appTerminationObserver = nil
    }

    let persistenceTasks = [
      preferencesPersistenceTask,
      profilesPersistenceTask,
      sessionPersistenceTask,
      devicePresetsPersistenceTask,
    ].compactMap { $0 }
    let appTransactions = Array(appIntentTasks.values)
    var mutationTasks = [
      privacySetupTask,
      audioStartupTask,
      deviceChangeObserver,
      sessionMaintenanceTask,
      adaptiveMixTask,
      levelPollTask,
    ].compactMap { $0 }
    mutationTasks.append(contentsOf: ownedOperationTasks.values)
    mutationTasks.append(contentsOf: pendingEqualizerDebounceTasks.values)
    mutationTasks.append(contentsOf: profileApplyTasks.values)
    mutationTasks.append(contentsOf: toastDismissals.values)
    mutationTasks.append(contentsOf: lingerRemovalTasks.values)

    for task in mutationTasks { task.cancel() }
    for task in appTransactions { task.cancel() }
    for task in persistenceTasks { task.cancel() }

    privacySetupTask = nil
    audioStartupTask = nil
    deviceChangeObserver = nil
    sessionMaintenanceTask = nil
    adaptiveMixTask = nil
    levelPollTask = nil
    ownedOperationTasks.removeAll()
    pendingEqualizerDebounceTasks.removeAll()
    profileApplyTasks.removeAll()
    toastDismissals.removeAll()
    lingerRemovalTasks.removeAll()
    appIntentTasks.removeAll()
    preferencesPersistenceTask = nil
    profilesPersistenceTask = nil
    sessionPersistenceTask = nil
    devicePresetsPersistenceTask = nil

    for appID in Array(currentAppIntentGeneration.keys) {
      currentAppIntentGeneration[appID] = Self.allocateAppIntentGeneration()
    }
    currentProfileGeneration = nil
    pendingEqualizerSettings.removeAll()
    pendingVolumeTargets.removeAll()
    optimisticAppIntentProjections.removeAll()
    pendingDeviceChangeRerun = false
    pendingAutoPausePassRerun = false
    pendingSelfInitiatedDeviceID = nil
    liveLevelsRefcount = 0
    liveLevels.removeAll()
    recentlyLiveIDs.removeAll()

    return ShutdownSettlingTasks(
      mutationTasks: mutationTasks,
      appIntentTasks: appTransactions,
      persistenceTasks: persistenceTasks
    )
  }

  private func performShutdown(
    settlingTasks: ShutdownSettlingTasks
  ) async -> AppShutdownResult {
    for task in settlingTasks.mutationTasks {
      await task.value
    }
    for task in settlingTasks.appIntentTasks {
      _ = await task.value
    }
    for task in settlingTasks.persistenceTasks {
      await task.value
    }

    isRefreshing = false
    isRecovering = false
    isLoading = false
    isHandlingDeviceChange = false
    isRunningSessionMaintenance = false
    isRunningAutoPausePass = false

    if hasStartedAudioBackend {
      await backend.setAdaptiveGains([:])
      let confirmed = await backend.currentSnapshot()
      session = mergedSession(with: confirmed, cached: session)
      invalidateVisibleAppsCache()
      syncOnboarding(using: session)
    }

    let failureMarker = persistenceFailureHistory.count
    isFinalizingShutdownPersistence = true
    enqueuePreferencesPersistence(preferences)
    enqueueProfilesPersistence(profiles)
    enqueueSessionPersistence(session)
    enqueueDevicePresetsPersistence(deviceVolumePresets)
    do {
      try await drainAndFlushPersistence()
    } catch {
      reportPersistenceFailure(storeName: "saved data flush", error: error, showWarning: false)
    }
    isFinalizingShutdownPersistence = false
    let persistenceDegradations = Array(persistenceFailureHistory.dropFirst(failureMarker))

    let backendResult: BackendShutdownResult?
    if hasStartedAudioBackend {
      backendResult = await backend.shutdownWithResult()
      hasStartedAudioBackend = false
    } else {
      backendResult = nil
    }

    let result = AppShutdownResult(
      persistenceDegradations: persistenceDegradations,
      backendResult: backendResult
    )
    shutdownResult = result
    if result.completion == .clean {
      logger.info("Shutdown completed cleanly")
    } else {
      logger.error(
        "Shutdown completed with \(persistenceDegradations.count, privacy: .public) persistence degradation(s) and backend status \(String(describing: backendResult?.completion), privacy: .public)"
      )
    }
    return result
  }

  private func observeFrontmostAppChanges() {
    guard frontmostAppObserver == nil else { return }
    frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.checkAutoPauseMusic()
      }
    }
  }

  private func observeAppTermination() {
    guard appTerminationObserver == nil else { return }
    appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
      let bundleID = app.bundleIdentifier
      let pid = app.processIdentifier
      MainActor.assumeIsolated {
        self?.handleAppTermination(bundleID: bundleID, pid: pid)
      }
    }
  }

  private func handleAppTermination(bundleID: String?, pid: Int32) {
    guard startupState == .running else { return }
    // Release the quit app's tap/aggregate device promptly instead of waiting
    // for the next refresh. Termination must NOT clear the user's saved mute.
    startOwnedOperation { store in
      await store.backend.releaseControllers(
        forBundleID: bundleID,
        pid: pid,
        clearMuteState: false
      )
    }

    // Reflect the termination in the UI immediately.
    var changed = false
    // Every session row matching the quit process — collected BEFORE the
    // routing-state guard below — so linger cleanup covers an app that had
    // already gone quiet (its row sits in Live only via the linger set, with a
    // routingState already dropped to .monitorOnly) and would otherwise miss the
    // guard and ghost in Live until its timer fires.
    var matchedIDs: [String] = []
    for index in session.apps.indices {
      let app = session.apps[index]
      guard (bundleID != nil && app.bundleID == bundleID) || app.pid == pid else { continue }
      matchedIDs.append(app.logicalID)
      if app.isActive || app.routingState == .managed || app.routingState == .live {
        session.apps[index].isActive = false
        session.apps[index].routingState = .monitorOnly
        session.apps[index].appliedVolume = nil
        session.apps[index].peakLevel = 0
        session.apps[index].rmsLevel = 0
        changed = true
      }
    }
    pausedMusicApps = pausedMusicApps.filter { id in
      session.apps.contains { $0.logicalID == id }
    }
    // A quit app must not keep lingering as "live": cancel its pending linger drop
    // and remove it from the set now, so its row leaves the Live list at once
    // rather than ghosting there for the linger window after the process is gone.
    for id in matchedIDs {
      if let task = lingerRemovalTasks.removeValue(forKey: id) { task.cancel() }
      pendingEqualizerDebounceTasks[id]?.cancel()
      pendingEqualizerDebounceTasks.removeValue(forKey: id)
      pendingEqualizerSettings.removeValue(forKey: id)
      pendingVolumeTargets.removeValue(forKey: id)
      supersedeAppIntentWork(forAppID: id)
      speechDetectionStates.removeValue(forKey: id)
      speechDuckingStates.removeValue(forKey: id)
      loudnessTrimStates.removeValue(forKey: id)
    }
    if !matchedIDs.isEmpty {
      let next = recentlyLiveIDs.subtracting(matchedIDs)
      if next != recentlyLiveIDs { recentlyLiveIDs = next }
    }
    if changed { invalidateVisibleAppsCache() }

    // Resume hook for the quit (not switched-away-from) case: resume is normally
    // driven by didActivateApplication, but if a conferencing app quits/crashes
    // and macOS doesn't promptly activate another app, no resume pass fires and
    // auto-paused media stays muted. If any .autoConferencing-tagged mutes
    // remain, re-evaluate directly instead of waiting for the next activation.
    // Resetting previousFrontmostApp defeats checkAutoPauseMusic's
    // unchanged-frontmost short-circuit so the resume branch can run now.
    let hasAutoPausedRemaining = session.apps.contains {
      $0.isMuted && $0.muteSource == .autoConferencing
    }
    if hasAutoPausedRemaining {
      previousFrontmostApp = nil
      checkAutoPauseMusic()
    }
  }

  /// Updates the auto-pause preference. Toggling in either direction resets the
  /// frontmost guard and re-evaluates immediately (the pass short-circuits while
  /// frontmost is unchanged): turning it ON must pause for a conferencing app
  /// that is *already* frontmost, and turning it OFF must resume anything still
  /// auto-paused right away — every other resume path runs inside the auto-pause
  /// pass, so without this the toggle would strand auto-paused apps muted.
  func setAutoPauseMusicEnabled(_ enabled: Bool) {
    guard requireAudioRunning() else { return }
    let wasEnabled = preferences.autoPauseMusicForConferencing
    preferences.autoPauseMusicForConferencing = enabled
    if enabled {
      // Full muting and speech ducking are mutually exclusive. Preserve the
      // loudness layer when Both was selected, otherwise turn Adaptive Mix off.
      switch preferences.adaptiveMixMode {
      case .speechFocus:
        preferences.adaptiveMixMode = .off
        restartAdaptiveMixing()
      case .both:
        preferences.adaptiveMixMode = .loudnessBalance
        restartAdaptiveMixing()
      case .off, .loudnessBalance:
        break
      }
    }
    persistPreferences()
    if enabled != wasEnabled {
      previousFrontmostApp = nil
      checkAutoPauseMusic()
    }
  }

  /// Updates the auto-restore-device preference. Read directly by
  /// `performDeviceChangePass`/`start`/`refresh` wherever per-device volume
  /// presets are restored — the backend itself always re-establishes managed
  /// routes on a device change regardless of this preference (route recovery
  /// is core functionality, not the optional convenience this toggle covers).
  func setAutoRestoreDeviceEnabled(_ enabled: Bool) {
    guard requireAudioRunning() else { return }
    preferences.autoRestoreDevice = enabled
    persistPreferences()
  }

  /// Updates how long a just-quiet app stays in Live. Existing pending removals
  /// are rebuilt with the new timing so the control takes effect immediately.
  func setLiveListLinger(_ linger: LiveListLinger) {
    guard startupState != .shuttingDown else { return }
    guard preferences.liveListLinger != linger else { return }
    preferences.liveListLinger = linger
    persistPreferences()
    for task in lingerRemovalTasks.values { task.cancel() }
    lingerRemovalTasks.removeAll()
    refreshLiveLinger()
  }

  func checkAutoPauseMusic() {
    guard requireAudioRunning() else { return }
    // Coalesce overlapping passes (mirroring handleDeviceChange) so two never
    // run at once. Frontmost detection happens inside each pass, so the
    // coalesced rerun reads the *then-current* frontmost app — the latest app
    // switch always wins and none are dropped.
    guard !isRunningAutoPausePass else {
      pendingAutoPausePassRerun = true
      return
    }
    isRunningAutoPausePass = true
    let started = startOwnedOperation { store in
      defer { store.isRunningAutoPausePass = false }
      repeat {
        store.pendingAutoPausePassRerun = false
        await store.performAutoPausePass()
      } while !Task.isCancelled
        && store.startupState == .running
        && store.pendingAutoPausePassRerun
    }
    if !started {
      isRunningAutoPausePass = false
    }
  }

  private func performAutoPausePass() async {
    let enabled = preferences.autoPauseMusicForConferencing
    // With the preference off the pass still runs as a resume-only sweep (see
    // setAutoPauseMusicEnabled) — every other resume path lives inside this
    // pass, so bailing outright would strand auto-paused apps muted.
    if !enabled {
      guard session.apps.contains(where: { $0.isMuted && $0.muteSource == .autoConferencing }) else { return }
    }

    // Detect conferencing from the live frontmost application rather than the
    // session snapshot, whose `isActive` flags are only refreshed periodically.
    let frontmost = NSWorkspace.shared.frontmostApplication
    let currentFrontmostApp = frontmost?.bundleIdentifier
    guard currentFrontmostApp != previousFrontmostApp else { return }
    previousFrontmostApp = currentFrontmostApp

    let frontmostCategory = frontmost.map {
      AppDiscoveryPolicy.inferCategory(bundleID: $0.bundleIdentifier, displayName: $0.localizedName ?? "")
    }
    let isConferencingAppActive = enabled && frontmostCategory == .conferencing

    await applyAutomaticConferencingTransition(
      isConferencingActive: isConferencingAppActive
    )
  }

  /// Applies the automatic conferencing transition through the same complete,
  /// generation-aware intent boundary as direct controls. Kept internal so focused
  /// tests can drive the deterministic transition without changing the OS frontmost
  /// application. Automation never requests durable intent or device-preset saves.
  func applyAutomaticConferencingTransition(
    isConferencingActive: Bool
  ) async {
    guard requireAudioRunning() else { return }
    var pausedNames: [String] = []
    var resumedNames: [String] = []

    if isConferencingActive {
      let musicApps = visibleApps.filter {
        $0.category == .media && !$0.isMuted && !isExcluded($0)
      }
      for app in musicApps {
        let result = await applyAppIntent(
          forAppID: app.logicalID,
          overrides: AppIntentOverrides(
            isMuted: true,
            muteSource: .autoConferencing
          ),
          reason: .automation,
          persistencePolicy: .none,
          feedbackPolicy: .none,
          optimistic: false
        )
        guard (result.outcome == .applied || result.outcome == .noChange),
              result.resultingApp?.isMuted == true,
              session.apps.first(matchingAppKey: app.logicalID)?.isMuted == true,
              currentAppIntentGeneration[app.logicalID] == result.generation else {
          logger.error(
            "Auto-pause did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
          )
          continue
        }
        if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[index].muteSource = .autoConferencing
        }
        pausedMusicApps.insert(app.logicalID)
        pausedNames.append(app.displayName)
        logger.info("Auto-paused music app: \(app.displayName, privacy: .public)")
      }
    } else {
      let resumable = visibleApps.filter {
        $0.isMuted
          && $0.muteSource == .autoConferencing
          && pausedMusicApps.contains($0.logicalID)
          && !isExcluded($0)
      }
      for app in resumable {
        let result = await applyAppIntent(
          forAppID: app.logicalID,
          overrides: AppIntentOverrides(isMuted: false, muteSource: .user),
          reason: .automation,
          persistencePolicy: .none,
          feedbackPolicy: .none,
          optimistic: false
        )
        guard (result.outcome == .applied || result.outcome == .noChange),
              result.resultingApp?.isMuted == false,
              session.apps.first(matchingAppKey: app.logicalID)?.isMuted == false,
              currentAppIntentGeneration[app.logicalID] == result.generation else {
          logger.error(
            "Auto-resume did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
          )
          continue
        }
        if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[index].muteSource = .user
        }
        pausedMusicApps.remove(app.logicalID)
        resumedNames.append(app.displayName)
        logger.info("Auto-resumed music app: \(app.displayName, privacy: .public)")
      }
    }

    guard !pausedNames.isEmpty || !resumedNames.isEmpty else { return }
    invalidateVisibleAppsCache()
    persistSessionSnapshot()
    syncOnboarding(using: session)

    if !pausedNames.isEmpty {
      let detail = pausedNames.count == 1
        ? "\(pausedNames[0]) muted for your call."
        : "\(pausedNames.count) apps muted for your call."
      showToast(
        title: "Auto-paused media",
        detail: detail,
        kind: .info,
        duration: .seconds(2.4)
      )
    } else {
      let detail = resumedNames.count == 1
        ? "\(resumedNames[0]) resumed."
        : "\(resumedNames.count) apps resumed."
      showToast(
        title: "Resumed media",
        detail: detail,
        kind: .info,
        duration: .seconds(2.0)
      )
    }
  }

  func applyProfile(_ profile: Profile) {
    guard requireAudioRunning() else { return }
    let generation = Self.allocateAppIntentGeneration()
    currentProfileGeneration = generation
    let excludedAppIDsAtSubmission = Set(preferences.excludedAppIDs)
    var backendProfile = profile
    // Keep every source row in its original slot, but neutralize an excluded
    // row's audio fields before the batch reaches a backend that may not retain
    // AppStore-owned exclusion preferences. The coordinator maps that same row
    // back to `.excluded` below, so identity/order are preserved without even a
    // transient re-tap of an app the user told Waves to leave alone.
    backendProfile.entries = profile.entries.map { entry in
      excludedAppIDsAtSubmission.contains(entry.appID) && entry.hasLevels
        ? ProfileEntry(appID: entry.appID)
        : entry
    }
    let liveAppIDs = Set(session.apps.map(\.logicalID))
    let affectedLiveAppIDs = Set(profile.entries.compactMap { entry in
      entry.hasLevels && liveAppIDs.contains(entry.appID) ? entry.appID : nil
    })

    // A batch owns the same generation for every live actionable row. Cancel all
    // older store-side work before calling the backend so an old direct result or
    // delayed EQ debounce cannot project over the profile when it eventually lands.
    for appID in affectedLiveAppIDs {
      appIntentTasks[appID]?.cancel()
      appIntentTasks.removeValue(forKey: appID)
      pendingVolumeTargets.removeValue(forKey: appID)
      pendingEqualizerSettings.removeValue(forKey: appID)
      pendingEqualizerDebounceTasks[appID]?.cancel()
      pendingEqualizerDebounceTasks.removeValue(forKey: appID)
      optimisticAppIntentProjections.removeValue(forKey: appID)
      currentAppIntentGeneration[appID] = generation
    }

    // Preserve the immediate group-selection behavior for pure membership
    // profiles while still sending every source row through the ordered result API.
    if !profile.carriesLevels {
      focusProfile(profile.id)
    }

    let backend = backend
    let task = Task { @MainActor [weak self] in
      let backendResult = await backend.applyProfileWithResults(backendProfile, generation: generation)
      guard let self else { return }
      defer { self.profileApplyTasks.removeValue(forKey: generation) }
      await self.finishProfileApplication(
        profile,
        generation: generation,
        affectedLiveAppIDs: affectedLiveAppIDs,
        excludedAppIDsAtSubmission: excludedAppIDsAtSubmission,
        backendResult: backendResult
      )
    }
    profileApplyTasks[generation] = task
  }

  private func finishProfileApplication(
    _ profile: Profile,
    generation: UInt64,
    affectedLiveAppIDs: Set<String>,
    excludedAppIDsAtSubmission: Set<String>,
    backendResult: ProfileApplyResult
  ) async {
    var result = await normalizedProfileResult(
      profile,
      generation: generation,
      excludedAppIDsAtSubmission: excludedAppIDsAtSubmission,
      backendResult: backendResult
    )

    // A newer profile owns focus, persistence, diagnostics, and feedback. The old
    // backend call may still unwind, but it cannot publish any store state.
    guard currentProfileGeneration == generation else { return }

    reconcileProfileRuntime(
      result,
      profile: profile,
      generation: generation,
      affectedLiveAppIDs: affectedLiveAppIDs
    )
    let persistenceResult = await persistProfileRows(
      result,
      profile: profile,
      generation: generation
    )

    // Persistence and diagnostics are suspension points. A direct edit started
    // after the profile must own that app's final row and must not be described as
    // though the profile remained current for it.
    result = profileResultMarkingNewerAppTransactionsSuperseded(
      result,
      profile: profile,
      generation: generation
    )
    guard currentProfileGeneration == generation else { return }

    lastProfileApplyResult = result
    for row in result.rows {
      let detail = row.detail ?? "No additional detail."
      logger.info(
        "Profile row \(row.entryIndex, privacy: .public) \(row.appID, privacy: .public): \(String(describing: row.outcome), privacy: .public). \(detail, privacy: .public)"
      )
    }

    if profile.carriesLevels {
      focusProfile(profile.id)
    }
    diagnostics = await backend.diagnosticsReport()
    onboarding.captureAuthorization = await backend.captureAuthorizationResult()
    guard currentProfileGeneration == generation else { return }
    // A direct transaction may have refreshed backendStatus while diagnostics was
    // in flight; keep that newer session truth instead of restoring the batch's
    // older aggregate status here.
    syncOnboarding(using: session)
    persistSessionSnapshot()
    presentProfileFeedback(
      profile,
      result: result,
      persistenceResult: persistenceResult
    )
  }

  private func normalizedProfileResult(
    _ profile: Profile,
    generation: UInt64,
    excludedAppIDsAtSubmission: Set<String>,
    backendResult: ProfileApplyResult
  ) async -> ProfileApplyResult {
    let rowsByIndex = Dictionary(grouping: backendResult.rows, by: \.entryIndex)
    var backendStatus = backendResult.backendStatus
    var rows: [ProfileRowApplyResult] = []
    rows.reserveCapacity(profile.entries.count)

    for (entryIndex, entry) in profile.entries.enumerated() {
      guard entry.hasLevels else {
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .membershipOnly,
          resultingApp: nil
        ))
        continue
      }

      if currentProfileGeneration != generation
        || currentAppIntentGeneration[entry.appID].map({ $0 != generation }) == true {
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .superseded,
          resultingApp: nil,
          detail: "A newer AppStore transaction superseded this profile row."
        ))
        continue
      }

      guard let backendRow = rowsByIndex[entryIndex]?.first,
            backendRow.appID == entry.appID else {
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .failed,
          resultingApp: nil,
          detail: "The backend did not return the matching ordered profile row."
        ))
        continue
      }
      guard backendRow.generation == generation else {
        rows.append(ProfileRowApplyResult(
          entryIndex: entryIndex,
          appID: entry.appID,
          generation: generation,
          outcome: .superseded,
          resultingApp: nil,
          detail: "The backend returned this profile row for a different generation."
        ))
        continue
      }

      var row = backendRow
      if (row.outcome == .applied || row.outcome == .noChange), row.resultingApp == nil {
        row.outcome = .failed
        row.detail = "The backend reported success without a confirmed resulting app state."
      }

      // Excluded rows stayed in the ordered batch but reached the backend as
      // membership-only no-ops. Reassert the exclusion with the SAME generation
      // so the final row carries backend-confirmed excluded runtime state.
      if excludedAppIDsAtSubmission.contains(entry.appID), row.outcome != .excluded {
        let exclusionIntent = completeAppRouteIntent(
          forAppID: entry.appID,
          overrides: AppIntentOverrides(isExcluded: true, muteSource: .user),
          generation: generation,
          reason: .profileApply
        )
        let repaired = await backend.applyAppIntent(exclusionIntent)
        backendStatus = repaired.backendStatus
        guard currentProfileGeneration == generation,
              currentAppIntentGeneration[entry.appID] == generation else {
          rows.append(ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .superseded,
            resultingApp: nil,
            detail: "A newer transaction superseded exclusion restoration for this profile row."
          ))
          continue
        }
        if repaired.generation == generation, repaired.outcome == .excluded {
          row = ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: .excluded,
            resultingApp: repaired.resultingApp,
            detail: "This app is excluded from Waves; its profile levels were not retained."
          )
        } else {
          row = ProfileRowApplyResult(
            entryIndex: entryIndex,
            appID: entry.appID,
            generation: generation,
            outcome: repaired.outcome == .superseded ? .superseded : .failed,
            resultingApp: repaired.resultingApp,
            detail: repaired.detail ?? "Waves could not restore this app's exclusion after profile application."
          )
        }
      }
      rows.append(row)
    }

    return ProfileApplyResult(rows: rows, backendStatus: backendStatus)
  }

  private func reconcileProfileRuntime(
    _ result: ProfileApplyResult,
    profile: Profile,
    generation: UInt64,
    affectedLiveAppIDs: Set<String>
  ) {
    session.backendStatus = result.backendStatus

    for (entry, row) in zip(profile.entries, result.rows) {
      switch row.outcome {
      case .membershipOnly, .superseded:
        continue
      case .unavailable:
        if affectedLiveAppIDs.contains(entry.appID),
           currentAppIntentGeneration[entry.appID] == generation {
          session.apps.removeAll { $0.logicalID == entry.appID || $0.id == entry.appID }
          confirmedAppsByLogicalID.removeValue(forKey: entry.appID)
        }
      case .applied, .noChange, .excluded, .unsupported, .failed:
        guard var resultingApp = row.resultingApp else { continue }
        let cachedMuteSource = session.apps
          .first(matchingAppKey: entry.appID)?.muteSource
        confirmedAppsByLogicalID[resultingApp.logicalID] = resultingApp
        resultingApp.isPinned = preferences.pinnedAppIDs.contains(resultingApp.logicalID)
        if row.outcome == .excluded || preferences.excludedAppIDs.contains(resultingApp.logicalID) {
          makeExcludedPresentation(&resultingApp)
        } else if resultingApp.isMuted {
          resultingApp.muteSource = entry.isMuted != nil
            ? .user
            : (cachedMuteSource == .autoConferencing ? .autoConferencing : resultingApp.muteSource)
        } else {
          resultingApp.muteSource = .user
        }
        if let index = session.apps.firstIndex(matchingAppKey: entry.appID) {
          session.apps[index] = resultingApp
        } else {
          session.apps.append(resultingApp)
        }
      }
    }

    invalidateVisibleAppsCache()
    syncOnboarding(using: session)
    persistSessionSnapshot()
  }

  private func persistProfileRows(
    _ result: ProfileApplyResult,
    profile: Profile,
    generation: UInt64
  ) async -> ProfilePersistenceResult {
    var preferenceAppIDs = Set<String>()
    var devicePresetKeys: [(deviceID: String, appID: String)] = []
    let deviceID = preferences.enablePerDeviceVolumePresets ? currentDeviceID : nil

    for (entry, row) in zip(profile.entries, result.rows) {
      guard entry.hasLevels,
            row.outcome == .applied || row.outcome == .noChange || row.outcome == .unavailable,
            currentProfileGeneration == generation,
            currentAppIntentGeneration[entry.appID].map({ $0 == generation }) ?? true,
            let durableIntent = durableIntent(for: entry, row: row) else { continue }

      durableIntentMutationGeneration[entry.appID] = generation
      preferences.appAudioIntents[entry.appID] = durableIntent
      preferences.appEqualizerSettings[entry.appID] = durableIntent.equalizerSettings
      preferenceAppIDs.insert(entry.appID)

      if let deviceID {
        var preset = deviceVolumePresets.getVolumeSettings(
          for: entry.appID,
          deviceID: deviceID
        ) ?? AppVolumeSettings(
          desiredVolume: durableIntent.desiredVolume,
          isMuted: durableIntent.isMuted,
          volumeBoost: durableIntent.volumeBoost
        )
        if entry.desiredVolume != nil { preset.desiredVolume = durableIntent.desiredVolume }
        if entry.isMuted != nil { preset.isMuted = durableIntent.isMuted }
        if entry.volumeBoost != nil { preset.volumeBoost = durableIntent.volumeBoost }
        let mutationKey = "\(deviceID)\u{0}\(entry.appID)"
        devicePresetMutationGeneration[mutationKey] = generation
        deviceVolumePresets.saveVolumeSettings(
          for: entry.appID,
          deviceID: deviceID,
          settings: preset
        )
        if !devicePresetKeys.contains(where: { $0.deviceID == deviceID && $0.appID == entry.appID }) {
          devicePresetKeys.append((deviceID, entry.appID))
        }
      }
    }
    invalidateVisibleAppsCache()

    var persistenceResult = ProfilePersistenceResult()
    if !preferenceAppIDs.isEmpty {
      do {
        try await savePreferencesDurably()
        for appID in preferenceAppIDs where durableIntentMutationGeneration[appID] == generation {
          durableIntentMutationGeneration.removeValue(forKey: appID)
        }
      } catch {
        for appID in preferenceAppIDs where durableIntentMutationGeneration[appID] == generation {
          if let savedIntent = durablySavedPreferences.appAudioIntents[appID] {
            preferences.appAudioIntents[appID] = savedIntent
          } else {
            preferences.appAudioIntents.removeValue(forKey: appID)
          }
          if let savedEqualizer = durablySavedPreferences.appEqualizerSettings[appID] {
            preferences.appEqualizerSettings[appID] = savedEqualizer
          } else {
            preferences.appEqualizerSettings.removeValue(forKey: appID)
          }
          durableIntentMutationGeneration.removeValue(forKey: appID)
        }
        reportPersistenceFailure(storeName: "settings", error: error, showWarning: false)
        persistenceResult.settingsError = error.localizedDescription
      }
    }

    if !devicePresetKeys.isEmpty {
      do {
        try await saveDeviceVolumePresetsDurably()
        for key in devicePresetKeys {
          let mutationKey = "\(key.deviceID)\u{0}\(key.appID)"
          if devicePresetMutationGeneration[mutationKey] == generation {
            devicePresetMutationGeneration.removeValue(forKey: mutationKey)
          }
        }
      } catch {
        for key in devicePresetKeys {
          let mutationKey = "\(key.deviceID)\u{0}\(key.appID)"
          guard devicePresetMutationGeneration[mutationKey] == generation else { continue }
          if let savedPreset = durablySavedDeviceVolumePresets.getVolumeSettings(
            for: key.appID,
            deviceID: key.deviceID
          ) {
            deviceVolumePresets.saveVolumeSettings(
              for: key.appID,
              deviceID: key.deviceID,
              settings: savedPreset
            )
          } else {
            deviceVolumePresets.deviceVolumes[key.deviceID]?.removeValue(forKey: key.appID)
            if deviceVolumePresets.deviceVolumes[key.deviceID]?.isEmpty == true {
              deviceVolumePresets.deviceVolumes.removeValue(forKey: key.deviceID)
            }
          }
          devicePresetMutationGeneration.removeValue(forKey: mutationKey)
        }
        reportPersistenceFailure(storeName: "device presets", error: error, showWarning: false)
        persistenceResult.devicePresetError = error.localizedDescription
      }
    }

    return persistenceResult
  }

  private func durableIntent(
    for entry: ProfileEntry,
    row: ProfileRowApplyResult
  ) -> PersistedAppAudioIntent? {
    let existing = preferences.appAudioIntents[entry.appID]
    let equalizer = existing?.equalizerSettings
      ?? confirmedEqualizerByLogicalID[entry.appID]
      ?? preferences.appEqualizerSettings[entry.appID]
      ?? EqualizerSettings()

    switch row.outcome {
    case .applied, .noChange:
      guard let app = row.resultingApp else { return nil }
      // The backend's resulting app is the confirmed complete state used to fill
      // fields the source row omitted. The sole exception is an automatic
      // conferencing mute: a volume/boost-only profile must never make that
      // transient mute durable.
      let isAutomaticMute = entry.isMuted == nil
        && session.apps.first(matchingAppKey: entry.appID)?.muteSource == .autoConferencing
      return PersistedAppAudioIntent(
        appID: entry.appID,
        desiredVolume: app.desiredVolume,
        isMuted: isAutomaticMute ? (existing?.isMuted ?? false) : app.isMuted,
        volumeBoost: app.volumeBoost,
        equalizerSettings: equalizer,
        targetDeviceUID: app.targetDeviceUID
      )
    case .unavailable:
      return PersistedAppAudioIntent(
        appID: entry.appID,
        desiredVolume: entry.desiredVolume ?? existing?.desiredVolume ?? 1,
        isMuted: entry.isMuted ?? existing?.isMuted ?? false,
        volumeBoost: entry.volumeBoost ?? existing?.volumeBoost ?? 1,
        equalizerSettings: equalizer,
        targetDeviceUID: existing?.targetDeviceUID
      )
    case .membershipOnly, .superseded, .excluded, .unsupported, .failed:
      return nil
    }
  }

  private func profileResultMarkingNewerAppTransactionsSuperseded(
    _ result: ProfileApplyResult,
    profile: Profile,
    generation: UInt64
  ) -> ProfileApplyResult {
    let rows = zip(profile.entries, result.rows).map { entry, row in
      guard entry.hasLevels,
            currentAppIntentGeneration[entry.appID].map({ $0 != generation }) == true else {
        return row
      }
      return ProfileRowApplyResult(
        entryIndex: row.entryIndex,
        appID: row.appID,
        generation: row.generation,
        outcome: .superseded,
        resultingApp: nil,
        detail: "A newer direct app transaction superseded this profile row."
      )
    }
    return ProfileApplyResult(rows: rows, backendStatus: result.backendStatus)
  }

  private func presentProfileFeedback(
    _ profile: Profile,
    result: ProfileApplyResult,
    persistenceResult: ProfilePersistenceResult
  ) {
    let actionableRows = zip(profile.entries, result.rows).filter { entry, _ in entry.hasLevels }
    guard !actionableRows.isEmpty else {
      showToast(
        title: "Profile selected",
        detail: "\(profile.name) — \(profile.entries.count) \(profile.entries.count == 1 ? "app" : "apps")",
        kind: .info,
        duration: .seconds(1.4)
      )
      return
    }

    func count(_ outcome: ProfileRowApplyOutcome) -> Int {
      actionableRows.count { $0.1.outcome == outcome }
    }
    let appliedCount = count(.applied) + count(.noChange)
    let unavailableCount = count(.unavailable)
    let excludedCount = count(.excluded)
    let failedCount = count(.failed)
    let unsupportedCount = count(.unsupported)
    let supersededCount = count(.superseded)
    let hasOutcomeWarning = excludedCount + failedCount + unsupportedCount + supersededCount > 0
    let isFullSuccess = appliedCount == actionableRows.count
      && unavailableCount == 0
      && !hasOutcomeWarning
      && persistenceResult.isFullySaved

    if isFullSuccess {
      showToast(
        title: "Profile applied",
        detail: profile.name,
        kind: .success,
        duration: .seconds(1.4)
      )
      return
    }

    var summary: [String] = []
    if appliedCount > 0 { summary.append("\(appliedCount) applied") }
    if unavailableCount > 0, persistenceResult.settingsError == nil {
      summary.append("\(unavailableCount) saved for later")
    } else if unavailableCount > 0 {
      summary.append("\(unavailableCount) unavailable")
    }
    if excludedCount > 0 { summary.append("\(excludedCount) excluded") }
    if failedCount > 0 { summary.append("\(failedCount) failed") }
    if unsupportedCount > 0 { summary.append("\(unsupportedCount) unsupported") }
    if supersededCount > 0 { summary.append("\(supersededCount) superseded") }
    if let settingsError = persistenceResult.settingsError {
      summary.append("settings not saved: \(settingsError)")
    }
    if let devicePresetError = persistenceResult.devicePresetError {
      summary.append("device preset not saved: \(devicePresetError)")
    }

    let title: String
    let kind: AppToast.Kind
    if failedCount > 0 || persistenceResult.settingsError != nil {
      title = appliedCount == 0 && unavailableCount == 0
        ? "Profile apply failed"
        : "Profile applied with errors"
      kind = .error
    } else if hasOutcomeWarning || persistenceResult.devicePresetError != nil {
      title = "Profile partly applied"
      kind = .warning
    } else if appliedCount > 0 && unavailableCount > 0 {
      title = "Profile partly applied"
      kind = .info
    } else if unavailableCount > 0 {
      title = "Profile saved for later"
      kind = .info
    } else {
      title = "Profile not applied"
      kind = .warning
    }
    showToast(
      title: title,
      detail: summary.joined(separator: ", "),
      kind: kind,
      duration: .seconds(2.8)
    )
  }

  /// Discards every saved per-device volume/mute/boost preset — the escape
  /// hatch for Settings > Audio's "Clear All Saved Levels", for a user who
  /// wants to start over rather than have Waves keep re-applying old levels
  /// per device. Does not touch the `enablePerDeviceVolumePresets` preference
  /// itself, only the accumulated data.
  func clearDeviceVolumePresets() {
    deviceVolumePresets = DeviceVolumePresets()
    persistDeviceVolumePresets()
  }

  // MARK: - Profiles

  /// Visible apps that belong to `profile`, in the current sort order.
  func apps(in profile: Profile) -> [AudioApp] {
    let ids = Set(profile.appIDs)
    return visibleApps.filter { ids.contains($0.logicalID) }
  }

  /// Marks a profile as the active one and signals the main window to focus it.
  private func focusProfile(_ id: UUID) {
    activeProfileID = id
    profileFocusToken &+= 1
  }

  /// Signals the main window to switch to `filter`'s scope. Called by the
  /// menu bar's "N more in Waves" overflow link right before it opens the
  /// main window, so the window actually shows the apps the link promised
  /// instead of whatever scope it happened to already be on.
  func focusSource(_ filter: SourceFilter) {
    sourceFocusRequest = filter
    sourceFocusToken &+= 1
  }

  func focusEqualizer(for app: AudioApp, source: SourceFilter? = nil) {
    equalizerFocusRequest = EqualizerFocusRequest(appID: app.logicalID, source: source)
    equalizerFocusToken &+= 1
  }

  func consumeEqualizerFocusRequest() -> EqualizerFocusRequest? {
    defer { equalizerFocusRequest = nil }
    return equalizerFocusRequest
  }

  /// Reads and clears `sourceFocusRequest` so it applies at most once. Needed
  /// because the token/request are set *before* `openWindow` — when the main
  /// window was already closed, that call creates a brand-new `MainWindowView`
  /// whose `.onChange(of: sourceFocusToken)` starts observing only after the
  /// bump already happened, so it never fires for that request. The new view's
  /// `.onAppear` calls this instead to pick up the still-pending request; a
  /// window that was already open and alive gets it via the `onChange` path.
  /// Clearing on read prevents either path from re-applying a stale request on
  /// some later, unrelated reopen.
  func consumeSourceFocusRequest() -> SourceFilter? {
    defer { sourceFocusRequest = nil }
    return sourceFocusRequest
  }

  /// Creates or updates a profile from a chosen set of apps. When `captureLevels`
  /// is true, each app's current volume/mute/boost is baked into its entry;
  /// otherwise the entries are membership-only (a pure grouping). Pass an `id`
  /// to edit an existing profile in place (so a rename keeps its identity);
  /// otherwise a same-named profile is replaced, or a new one is appended.
  func saveProfile(id: UUID? = nil, named name: String, appIDs: [String], captureLevels: Bool) {
    guard startupState != .shuttingDown else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, trimmedName.count <= 100 else { return }

    // Resolve which existing profile (if any) this save targets: an explicit id
    // wins (an edit, even across a rename), otherwise fall back to a name match.
    let targetIndex = id.flatMap { id in profiles.firstIndex(where: { $0.id == id }) }
      ?? profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame })

    // Reject a rename that would collide with a *different* existing profile, so
    // an edit can't silently produce two profiles with the same name.
    if let collision = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }),
       collision != targetIndex {
      showToast(title: "Name already used", detail: "A profile named “\(trimmedName)” already exists.", kind: .warning)
      return
    }

    // Never bake an excluded app into a profile — applying it later would re-tap
    // an app the user explicitly told Waves to leave alone. Preserve the chosen
    // order while removing duplicates.
    let excluded = Set(preferences.excludedAppIDs)
    let appByID = Dictionary(session.apps.map { ($0.logicalID, $0) }, uniquingKeysWith: { first, _ in first })
    // When editing without re-capturing, keep each existing member's stored
    // levels rather than discarding them — so adding one app to "Focus" doesn't
    // wipe the saved mix. Only an explicit "Capture current levels" re-snapshots.
    let existingEntries: [String: ProfileEntry] = targetIndex.map {
      Dictionary(profiles[$0].entries.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
    } ?? [:]
    var seen = Set<String>()
    let entries: [ProfileEntry] = appIDs
      .filter { !excluded.contains($0) && seen.insert($0).inserted }
      .map { appID in
        if captureLevels, let app = appByID[appID] {
          return ProfileEntry(
            appID: appID,
            desiredVolume: app.desiredVolume,
            isMuted: app.isMuted,
            volumeBoost: app.volumeBoost
          )
        }
        // Preserve a previously-saved level for an existing member; otherwise the
        // entry is membership-only.
        return existingEntries[appID] ?? ProfileEntry(appID: appID)
      }

    if let targetIndex {
      var replacement = profiles[targetIndex]
      replacement.name = trimmedName
      replacement.entries = entries
      replacement.updatedAt = .now
      profiles[targetIndex] = replacement
      focusProfile(replacement.id)
    } else {
      let profile = Profile(name: trimmedName, entries: entries)
      profiles.append(profile)
      focusProfile(profile.id)
    }
    persistProfiles()
    showToast(
      title: "Profile saved",
      detail: trimmedName,
      kind: .success,
      duration: .seconds(1.6)
    )
  }

  func deleteProfiles(at offsets: IndexSet) {
    guard startupState != .shuttingDown else { return }
    let removedIDs = offsets.map { profiles[$0].id }
    profiles.remove(atOffsets: offsets)
    if let active = activeProfileID, removedIDs.contains(active) {
      activeProfileID = nil
    }
    persistProfiles()
    if !offsets.isEmpty {
      showToast(
        title: "Profile removed",
        detail: "Removed from your profiles.",
        kind: .info,
        duration: .seconds(1.1)
      )
    }
  }

  func exportProfile(_ profile: Profile) {
    guard startupState != .shuttingDown else { return }
    startOwnedOperation { [self] _ in
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        // Write the same versioned, array-shaped envelope as profiles.json
        // (VersionedPayload<[Profile]>) so the share file is self-describing
        // (carries schemaVersion for forward-compat) and interchangeable with
        // the persisted format. decodeImportedProfiles accepts this shape.
        let data = try PersistedSchema.encode([profile], using: encoder)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(profile.name).json"
        savePanel.canCreateDirectories = true

        // Anchor to the window hosting the control (the Settings window when it
        // is frontmost), not the mixer window. Settings can be opened from the
        // menu bar with the mixer window closed, leaving NSApp.mainWindow nil.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
          showToast(title: "Export failed", detail: "No window available.", kind: .error)
          return
        }

        let response = await savePanel.beginSheetModal(for: window)
        guard !Task.isCancelled, startupState != .shuttingDown else { return }
        if response == .OK, let url = savePanel.url {
          try data.write(to: url, options: .atomic)
          showToast(
            title: "Profile exported",
            detail: "Saved to \(url.lastPathComponent)",
            kind: .success,
            duration: .seconds(2.0)
          )
        }
      } catch {
        showToast(title: "Export failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func importProfiles() {
    guard startupState != .shuttingDown else { return }
    startOwnedOperation { [self] _ in
      let openPanel = NSOpenPanel()
      openPanel.allowedContentTypes = [.json]
      openPanel.canChooseFiles = true
      openPanel.canChooseDirectories = false
      openPanel.allowsMultipleSelection = false

      // Anchor to the window hosting the control (the Settings window when it is
      // frontmost). Settings can be opened from the menu bar with the mixer
      // window closed, leaving NSApp.mainWindow nil.
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        showToast(title: "Import failed", detail: "No window available.", kind: .error)
        return
      }

      let response = await openPanel.beginSheetModal(for: window)
      guard !Task.isCancelled, startupState != .shuttingDown else { return }
      if response == .OK, let url = openPanel.url {
        do {
          let sizeCap = 10 * 1024 * 1024
          // Reject over-cap files BEFORE reading so a huge selection can't exhaust
          // memory in the Data(contentsOf:) allocation. resourceValues is a cheap
          // stat that doesn't load the file.
          if let reportedSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
             reportedSize > sizeCap {
            showToast(title: "Import failed", detail: "This file is larger than the 10 MB limit.", kind: .error)
            return
          }

          // Re-enforce the cap on the data actually loaded. The pre-read stat above
          // bounds the allocation; this post-read check still rejects a file whose
          // size grew (or a symlink swapped) between the stat and the read.
          let data = try Data(contentsOf: url)
          if data.count > sizeCap {
            showToast(title: "Import failed", detail: "This file is larger than the 10 MB limit.", kind: .error)
            return
          }

          // Accept the app's own profiles.json backup (a VersionedPayload<[Profile]>
          // envelope or a bare [Profile]) as well as a single exported Profile, so
          // restoring a backup doesn't fail with a cryptic generic decode error.
          guard let decoded = Self.decodeImportedProfiles(from: data) else {
            showToast(
              title: "Import failed",
              detail: "Unsupported file — expected a Waves profile or profiles backup.",
              kind: .error
            )
            return
          }

          // Validate and build the entire batch into a local working copy BEFORE
          // touching the observed `profiles` array. Any validation failure returns
          // without having mutated `profiles`, so a multi-profile backup with a
          // single bad entry leaves the live library (and the UI) unchanged —
          // restoring the original atomic behavior for the multi-profile case.
          var working = profiles
          var importedNames: [String] = []
          for profile in decoded {
            // Validate profile structure. Trim first so a whitespace-only name is
            // rejected (isEmpty alone passes "   ") and bound the length to match
            // the editor's 100-character cap.
            let trimmedName = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty {
              showToast(title: "Import failed", detail: "Profile name cannot be empty.", kind: .error)
              return
            }

            if trimmedName.count > 100 {
              showToast(title: "Import failed", detail: "Profile name exceeds 100 characters.", kind: .error)
              return
            }

            if profile.entries.count > 1000 {
              showToast(title: "Import failed", detail: "Profile has too many entries (max 1000).", kind: .error)
              return
            }

            if let existingIndex = working.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
              var imported = profile
              imported.id = working[existingIndex].id
              imported.name = working[existingIndex].name
              imported.createdAt = working[existingIndex].createdAt
              imported.updatedAt = .now
              working[existingIndex] = imported
              // Report the name actually stored (the existing one is kept), not
              // the imported file's name, which may differ only in case.
              importedNames.append(working[existingIndex].name)
            } else {
              // Assign a fresh identity so importing a profile never collides with
              // an existing one's UUID (which breaks SwiftUI list identity).
              var imported = profile
              imported.id = UUID()
              imported.name = trimmedName
              imported.createdAt = .now
              imported.updatedAt = .now
              working.append(imported)
              importedNames.append(trimmedName)
            }
          }

          // Every profile passed — commit the batch atomically and persist once.
          profiles = working
          persistProfiles()
          showToast(
            title: importedNames.count == 1 ? "Profile imported" : "Profiles imported",
            detail: importedNames.count == 1 ? importedNames.first : "\(importedNames.count) profiles restored",
            kind: .success,
            duration: .seconds(2.0)
          )
        } catch {
          showToast(title: "Import failed", detail: error.localizedDescription, kind: .error)
        }
      }
    }
  }

  /// Decodes profiles from any shape Waves itself writes: the versioned
  /// `profiles.json` backup envelope (`VersionedPayload<[Profile]>`), a bare
  /// `[Profile]` array, or a single exported `Profile`. Also reads legacy
  /// `presets.json` backups, whose entries decode straight into level-bearing
  /// profiles. Returns nil when the data matches none of these.
  nonisolated static func decodeImportedProfiles(from data: Data) -> [Profile]? {
    let decoder = JSONDecoder()
    // PersistedSchema.decode handles both the versioned envelope and a legacy
    // bare [Profile] array written before envelopes existed. Distinguish a valid
    // (possibly empty) array from a decode failure so an empty backup is accepted
    // rather than mistaken for a single-Profile file.
    do {
      return try PersistedSchema.decode([Profile].self, from: data, using: decoder)
    } catch {
      if let profile = try? decoder.decode(Profile.self, from: data) {
        return [profile]
      }
      return nil
    }
  }

  func recoverRoutes() {
    guard requireAudioRunning() else { return }
    // Mirror refresh()'s in-flight guard: the toolbar/Settings/Onboarding
    // "Recover managed routes" buttons call this directly, so rapid clicks would
    // otherwise stack overlapping recovery tasks that each reassign session and
    // re-query diagnostics.
    guard !isRecovering else { return }

    isRecovering = true
    startOwnedOperation { [self] _ in
      defer { isRecovering = false }
      do {
        let recovered = try await backend.recoverRoutes()
        guard !Task.isCancelled, startupState == .running else { return }
        session = mergedSession(with: recovered, cached: session)
        let includePreset = preferences.enablePerDeviceVolumePresets
        for appID in session.apps.map(\.logicalID) {
          _ = await restoreConfiguredApp(
            appID: appID,
            defaultReason: .routeRecovery,
            deviceID: currentDeviceID,
            includeDevicePreset: includePreset
          )
        }
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        onboarding.captureAuthorization = await backend.captureAuthorizationResult()
        persistSessionSnapshot()
        syncOnboarding(using: session)
        // backend.recoverRoutes() does not throw when a prerequisite is still
        // unmet (e.g. capture permission denied or no output device): it rebuilds
        // the snapshot, which recomputes isRouteRecoveryHealthy. Branch on the
        // resulting health instead of reporting success on every no-throw return,
        // so the toast can't claim "Routes recovered" while the Setup step stays
        // in its "needs action" state.
        let status = session.backendStatus
        if status.isRouteRecoveryHealthy {
          showToast(
            title: "Routes recovered",
            detail: "Managed routing paths were reattached.",
            kind: .success
          )
        } else {
          let reason: String
          if !status.hasRequiredPermissions {
            reason = "Audio capture isn't granted — allow audio recording in System Settings, then try again."
          } else if session.currentDevice == nil {
            reason = "No output device is available — connect an output device, then try again."
          } else {
            reason = status.lastError ?? "Routes are still not healthy. Check the Advanced tab for details."
          }
          showToast(
            title: "Routes still need attention",
            detail: reason,
            kind: .warning
          )
        }
      } catch {
        guard startupState == .running else { return }
        session = mergedSession(with: await backend.currentSnapshot(), cached: session)
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        onboarding.captureAuthorization = await backend.captureAuthorizationResult()
        persistSessionSnapshot()
        syncOnboarding(using: session)
        showToast(title: "Recovery failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func refreshDiagnostics() {
    guard requireAudioRunning() else { return }
    startOwnedOperation { [self] _ in
      // Rebuild the backend snapshot FIRST so diagnostics are computed from the
      // same freshly-probed state the checklist/session read. diagnosticsReport()
      // re-probes capture authorization, but currentSnapshot() only returns the
      // cached snapshot whose backendStatus.hasRequiredPermissions /
      // isRouteRecoveryHealthy predate that probe. Computing diagnostics before the
      // refresh let the Advanced checks reflect stale backendStatus (e.g. a stale
      // Route-recovery warning) while session/onboarding updated from the fresh
      // snapshot. Refresh, then read diagnostics, then assign — so both share the
      // freshly-probed source. Fall back to the cached snapshot if the rebuild
      // throws, so a transient failure still re-syncs from something current.
      let snapshot: AudioSessionSnapshot
      if let rebuilt = try? await backend.refresh() {
        snapshot = rebuilt
      } else {
        snapshot = await backend.currentSnapshot()
      }
      guard !Task.isCancelled, startupState == .running else { return }
      diagnostics = await backend.diagnosticsReport()
      onboarding.captureAuthorization = await backend.captureAuthorizationResult()
      guard !Task.isCancelled, startupState == .running else { return }
      // The live snapshot owns backend truth; mergedSession reapplies only the
      // store's current transaction/slider projection and preferences-owned tags.
      session = mergedSession(with: snapshot, cached: session)
      invalidateVisibleAppsCache()
      syncOnboarding(using: session)
    }
  }

  /// Resolves the app a global hotkey should act on. Prefers the OS-frontmost
  /// application (the one the user is actually looking at) when Waves manages it,
  /// mirroring checkAutoPauseMusic's frontmost detection. Falls back to the
  /// sort-first active/visible app only when no managed match exists, so an
  /// audible background app no longer steals the hotkey from a silent focused one.
  private func frontmostManagedApp() -> AudioApp? {
    let frontmost = NSWorkspace.shared.frontmostApplication
    // The local hotkey monitor (unlike the global-only one it replaced) can
    // now fire while Waves' own mixer/Settings window is frontmost. There is
    // no single "the app the user is working in" in that case — falling
    // through to the activeApps/visibleApps.first fallback below would
    // silently act on an arbitrary row instead of the one the user actually
    // has in view. Do nothing instead, matching the pre-local-monitor
    // behavior for this specific case.
    guard frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
      return nil
    }
    let bundleID = frontmost?.bundleIdentifier
    let pid = frontmost?.processIdentifier
    if bundleID != nil || pid != nil {
      if let match = visibleApps.first(where: { app in
        (bundleID != nil && app.bundleID == bundleID) || (pid != nil && app.pid == pid)
      }) {
        return match
      }
    }
    return activeApps.first ?? visibleApps.first
  }

  func increaseVolumeForFrontmostApp(step: Float = 0.1) {
    guard requireAudioRunning() else { return }
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = frontmostManagedApp()
    guard let app = frontmostApp else { return }
    // Don't act on (or show a success toast for) an excluded app.
    guard !isExcluded(app) else { return }

    // Validate step parameter bounds
    let clampedStep = max(0.01, min(step, 0.5))
    let newVolume = min(app.desiredVolume + clampedStep, 1.0)
    setDesiredVolume(newVolume, for: app)
    // The complete-intent transaction shows the single confirmation toast
    // ("Managed route active") on success and the error toast on failure, so the
    // handler does not emit its own toast to avoid stacking two.
    commitDesiredVolume(for: app)
  }

  func decreaseVolumeForFrontmostApp(step: Float = 0.1) {
    guard requireAudioRunning() else { return }
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = frontmostManagedApp()
    guard let app = frontmostApp else { return }
    // Don't act on (or show a success toast for) an excluded app.
    guard !isExcluded(app) else { return }

    // Validate step parameter bounds
    let clampedStep = max(0.01, min(step, 0.5))
    let newVolume = max(app.desiredVolume - clampedStep, 0.0)
    setDesiredVolume(newVolume, for: app)
    // The async apply path shows the single confirmation/error toast; the
    // handler stays silent so a keypress produces exactly one toast.
    commitDesiredVolume(for: app)
  }

  func toggleMuteForFrontmostApp() {
    guard requireAudioRunning() else { return }
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = frontmostManagedApp()
    guard let app = frontmostApp else { return }
    // Don't act on (or show a success toast for) an excluded app.
    guard !isExcluded(app) else { return }

    let newMutedState = !app.isMuted
    // setMuted shows the single confirmation toast ("App muted"/"App unmuted")
    // on success and the error toast on failure, so the handler stays silent to
    // avoid stacking two near-identical toasts per keypress.
    setMuted(newMutedState, for: app)
  }

  func persistPreferences() {
    enqueuePreferencesPersistence(preferences)
    invalidateVisibleAppsCache()
  }

  private func persistProfiles() {
    enqueueProfilesPersistence(profiles)
  }

  private func persistDeviceVolumePresets() {
    enqueueDevicePresetsPersistence(deviceVolumePresets)
  }

  private func enqueuePreferencesPersistence(_ snapshot: UserPreferences) {
    guard startupState != .shuttingDown || isFinalizingShutdownPersistence else { return }
    pendingPreferencesPersistence = snapshot
    guard preferencesPersistenceTask == nil else { return }
    preferencesPersistenceTask = Task { @MainActor [weak self] in
      await self?.runPreferencesPersistence()
    }
  }

  private func enqueueProfilesPersistence(_ snapshot: [Profile]) {
    guard startupState != .shuttingDown || isFinalizingShutdownPersistence else { return }
    pendingProfilesPersistence = snapshot
    guard profilesPersistenceTask == nil else { return }
    profilesPersistenceTask = Task { @MainActor [weak self] in
      await self?.runProfilesPersistence()
    }
  }

  private func enqueueSessionPersistence(_ snapshot: AudioSessionSnapshot) {
    guard startupState != .shuttingDown || isFinalizingShutdownPersistence else { return }
    pendingSessionPersistence = snapshot
    guard sessionPersistenceTask == nil else { return }
    sessionPersistenceTask = Task { @MainActor [weak self] in
      await self?.runSessionPersistence()
    }
  }

  private func enqueueDevicePresetsPersistence(_ snapshot: DeviceVolumePresets) {
    guard startupState != .shuttingDown || isFinalizingShutdownPersistence else { return }
    pendingDevicePresetsPersistence = snapshot
    guard devicePresetsPersistenceTask == nil else { return }
    devicePresetsPersistenceTask = Task { @MainActor [weak self] in
      await self?.runDevicePresetsPersistence()
    }
  }

  private func runPreferencesPersistence() async {
    defer { preferencesPersistenceTask = nil }
    while let snapshot = pendingPreferencesPersistence {
      pendingPreferencesPersistence = nil
      do {
        try await preferencesStore.save(snapshot)
        durablySavedPreferences = snapshot
      } catch {
        reportPersistenceFailure(storeName: "settings", error: error)
      }
    }
  }

  private func runProfilesPersistence() async {
    defer { profilesPersistenceTask = nil }
    while let snapshot = pendingProfilesPersistence {
      pendingProfilesPersistence = nil
      do {
        try await profileStore.save(snapshot)
      } catch {
        reportPersistenceFailure(storeName: "profiles", error: error)
      }
    }
  }

  private func runSessionPersistence() async {
    defer { sessionPersistenceTask = nil }
    while let snapshot = pendingSessionPersistence {
      pendingSessionPersistence = nil
      do {
        try await sessionStore.save(snapshot)
      } catch {
        reportPersistenceFailure(storeName: "session cache", error: error)
      }
    }
  }

  private func runDevicePresetsPersistence() async {
    defer { devicePresetsPersistenceTask = nil }
    while let snapshot = pendingDevicePresetsPersistence {
      pendingDevicePresetsPersistence = nil
      do {
        try await deviceVolumePresetsStore.save(snapshot)
        durablySavedDeviceVolumePresets = snapshot
      } catch {
        reportPersistenceFailure(storeName: "device presets", error: error)
      }
    }
  }

  /// Waits for every currently tracked background persistence runner. The loop
  /// also observes runners started while an earlier one is suspended, providing
  /// the drain boundary that the checked shutdown task will await later.
  func drainPersistenceTasks() async {
    while true {
      let tasks = [
        preferencesPersistenceTask,
        profilesPersistenceTask,
        sessionPersistenceTask,
        devicePresetsPersistenceTask,
      ].compactMap { $0 }
      guard !tasks.isEmpty else { return }
      for task in tasks {
        await task.value
      }
    }
  }

  var trackedPersistenceTaskCount: Int {
    [
      preferencesPersistenceTask,
      profilesPersistenceTask,
      sessionPersistenceTask,
      devicePresetsPersistenceTask,
    ].compactMap { $0 }.count
  }

  func drainAppIntentTransactions() async {
    while true {
      let debounceTasks = Array(pendingEqualizerDebounceTasks.values)
      for task in debounceTasks { await task.value }
      let transactionTasks = Array(appIntentTasks.values)
      let profileTasks = Array(profileApplyTasks.values)
      guard debounceTasks.isEmpty && transactionTasks.isEmpty && profileTasks.isEmpty else {
        for task in transactionTasks { _ = await task.value }
        for task in profileTasks { await task.value }
        continue
      }
      return
    }
  }

  var trackedAppIntentTaskCount: Int {
    appIntentTasks.count + pendingEqualizerDebounceTasks.count + profileApplyTasks.count
  }

  /// Explicit durable boundaries for future transaction/profile/privacy work.
  /// Each helper first removes older queued snapshots, then submits an immutable
  /// current snapshot and surfaces any write failure to its caller.
  func savePreferencesDurably() async throws {
    await drainPersistenceTasks()
    let snapshot = preferences
    try await preferencesStore.save(snapshot)
    durablySavedPreferences = snapshot
  }

  func saveProfilesDurably() async throws {
    await drainPersistenceTasks()
    let snapshot = profiles
    try await profileStore.save(snapshot)
  }

  func saveSessionDurably() async throws {
    await drainPersistenceTasks()
    let snapshot = session
    try await sessionStore.save(snapshot)
  }

  func saveDeviceVolumePresetsDurably() async throws {
    await drainPersistenceTasks()
    let snapshot = deviceVolumePresets
    try await deviceVolumePresetsStore.save(snapshot)
    durablySavedDeviceVolumePresets = snapshot
  }

  func drainAndFlushPersistence() async throws {
    await drainPersistenceTasks()
    try await preferencesStore.flush()
    try await profileStore.flush()
    try await sessionStore.flush()
    try await deviceVolumePresetsStore.flush()
  }

  private func reportPersistenceFailure(
    storeName: String,
    error: Error,
    showWarning: Bool = true
  ) {
    let message = "\(storeName): \(error.localizedDescription)"
    logger.error("Persistence failed for \(storeName): \(error.localizedDescription)")
    persistenceFailureCount += 1
    lastPersistenceError = message
    persistenceFailureHistory.append(message)
    guard showWarning else { return }

    let now = Date()
    if let lastPersistenceWarningDate,
       now.timeIntervalSince(lastPersistenceWarningDate) < persistenceWarningDebounceInterval {
      return
    }
    lastPersistenceWarningDate = now
    showToast(
      title: "Changes may not be saved",
      detail: "Waves couldn't save \(storeName). \(error.localizedDescription)",
      kind: .warning
    )
  }

  /// Updates the keyboard-shortcuts preference and notifies the app delegate so
  /// the system-wide key monitor is installed only while shortcuts are enabled
  /// (it otherwise observes every keystroke for no reason).
  func setKeyboardShortcutsEnabled(_ enabled: Bool) {
    preferences.enableKeyboardShortcuts = enabled
    persistPreferences()
    NotificationCenter.default.post(name: .wavesKeyboardShortcutsPreferenceChanged, object: nil)
  }

  private func sortedApps(_ apps: [AudioApp]) -> [AudioApp] {
    switch preferences.sortMode {
    case .name:
      apps.sorted(by: displayNameComparator)
    case .activity:
      apps.sorted { app1, app2 in
        let rank1 = activityRank(for: app1)
        let rank2 = activityRank(for: app2)
        if rank1 != rank2 {
          return rank1 < rank2
        }
        return displayNameComparator(app1, app2)
      }
    case .category:
      apps.sorted {
        if $0.category.rawValue != $1.category.rawValue {
          return $0.category.rawValue < $1.category.rawValue
        }
        return displayNameComparator($0, $1)
      }
    case .manual:
      apps.sorted(by: manualOrderComparator)
    }
  }

  private func activityRank(for app: AudioApp) -> Int {
    if app.routingState == .live {
      return 0
    }

    // Route through the shared isRecentlyLive (which consults the live-level poll
    // plus the linger window), so the Activity sort agrees with Live/Recent
    // membership on one source of truth — otherwise a managed app playing right
    // now would show in Live but sink to the idle tier here, and a just-silenced
    // app would jump down a tier the instant it goes quiet, before its row has
    // even finished lingering in the Live list.
    if isRecentlyLive(app) {
      return 1
    }

    if app.isActive {
      return 2
    }

    if app.routingState == .managed {
      return 3
    }

    return 4
  }

  private func displayNameComparator(_ app1: AudioApp, _ app2: AudioApp) -> Bool {
    app1.displayName.localizedCaseInsensitiveCompare(app2.displayName) == .orderedAscending
  }

  private var manualOrderComparator: (AudioApp, AudioApp) -> Bool {
    let order = preferences.customAppOrder
    let nameComparator = displayNameComparator
    return { app1, app2 in
      let index1 = order.firstIndex(of: app1.logicalID) ?? Int.max
      let index2 = order.firstIndex(of: app2.logicalID) ?? Int.max
      if index1 != index2 {
        return index1 < index2
      }
      return nameComparator(app1, app2)
    }
  }

  func reorderApps(from source: IndexSet, to destination: Int) {
    // Snapshot the order the user actually dragged against BEFORE touching
    // sortMode. visibleApps is a live computed property, so switching to
    // .manual first would re-sort it (empty customAppOrder => displayName
    // ascending) and the move indices would then point at the wrong rows.
    let displayedIDs = visibleApps.map { $0.logicalID }

    // Guard the indices against the snapshot they must index into; if an async
    // session mutation has shrunk the list since SwiftUI computed the drop,
    // bail safely instead of trapping in Array.move.
    guard destination >= 0, destination <= displayedIDs.count,
          source.allSatisfy({ $0 >= 0 && $0 < displayedIDs.count }) else {
      return
    }

    var reorderedVisible = displayedIDs
    // Use the standard collection move so downward drags land on the drop
    // target instead of one row below it (the manual remove/insert was off by
    // one because the removal shifts later indices).
    reorderedVisible.move(fromOffsets: source, toOffset: destination)

    // Splice the reordered visible IDs back into the full saved order rather
    // than replacing it, so apps not currently visible (e.g. system processes
    // hidden by showSystemProcesses=false) keep their saved positions instead
    // of being dropped from customAppOrder and sinking to the bottom later.
    let visibleSet = Set(displayedIDs)
    var merged: [String] = []
    var reorderedIterator = reorderedVisible.makeIterator()
    for id in preferences.customAppOrder {
      if visibleSet.contains(id) {
        // Replace each visible slot, in order, with the next reordered ID.
        if let next = reorderedIterator.next() {
          merged.append(next)
        }
      } else {
        merged.append(id)
      }
    }
    // Append any reordered visible IDs not already represented in the saved
    // order (newly seen apps that weren't in customAppOrder yet).
    while let next = reorderedIterator.next() {
      merged.append(next)
    }

    if preferences.sortMode != .manual {
      preferences.sortMode = .manual
    }
    preferences.customAppOrder = merged
    persistPreferences()
    invalidateVisibleAppsCache()
  }

  private func syncOnboarding(using snapshot: AudioSessionSnapshot) {
    onboarding.hasCompletedPrivacySetup = preferences.hasCompletedPrivacySetup
    onboarding.audioComponentInstalled = snapshot.backendStatus.isAudioComponentInstalled
    switch onboarding.captureAuthorization {
    case .some(.authorized):
      onboarding.permissionsGranted = true
    case .some(.notGranted), .some(.undetermined), .some(.unsupported), .some(.probeFailed):
      onboarding.permissionsGranted = false
    case .none:
      onboarding.permissionsGranted = preferences.hasCompletedPrivacySetup
        && snapshot.backendStatus.hasRequiredPermissions
    }
    onboarding.accessibilityPermissionGranted = AXIsProcessTrusted()
    onboarding.outputDeviceVisible = snapshot.currentDevice != nil
    onboarding.routeHealthReady = preferences.hasCompletedPrivacySetup
      && onboarding.permissionsGranted
      && snapshot.backendStatus.isRouteRecoveryHealthy
    reconcileLoginItemStatus()
  }

  /// Re-reads the system's login-item registration and syncs it into
  /// `preferences.launchAtLoginEnabled` / `onboarding.launchAtLoginEnabled`.
  ///
  /// The in-app toggle only learns about a login-item change made *inside*
  /// Waves (via the `launchAtLoginEnabled` setter) at the moment it happens.
  /// If the user instead flips "Open at Login" from System Settings while
  /// Waves is already running, that goes unnoticed until the next full
  /// `syncOnboarding` pass — so this is also called directly from
  /// `AppDelegate.applicationDidBecomeActive`, which fires every time Waves
  /// regains focus (e.g. right after the user returns from System Settings).
  func reconcileLoginItemStatus() {
    guard startupState != .shuttingDown else { return }
    let status = loginItemService.status
    loginItemStatus = status
    let launchAtLoginIntentEnabled = status.isUserIntentEnabled
    onboarding.launchAtLoginEnabled = status.isEnabled
    onboarding.launchAtLoginRequiresApproval = status.requiresApproval
    // Persist the OS-derived launch-at-login state on every reconcile so a
    // mid-session change reaches disk, not only when Settings happens to be
    // open at quit. Guarded by a change check so the frequent refresh/level
    // callers that invoke syncOnboarding don't rewrite the preferences file
    // when the value is unchanged.
    if preferences.launchAtLoginEnabled != launchAtLoginIntentEnabled {
      preferences.launchAtLoginEnabled = launchAtLoginIntentEnabled
      persistPreferences()
    }
  }

  private static func migrateDurableAppIntents(
    in preferences: inout UserPreferences,
    from session: AudioSessionSnapshot
  ) -> Bool {
    guard preferences.appAudioIntentMigrationVersion == 0 else { return false }

    let defaultEqualizer = EqualizerSettings()

    for app in session.apps where preferences.appAudioIntents[app.logicalID] == nil {
      let equalizer = preferences.appEqualizerSettings[app.logicalID] ?? defaultEqualizer
      let userMuted = app.muteSource == .user && app.isMuted
      let isCustomized = abs(app.desiredVolume - 1) > 0.001
        || userMuted
        || abs(app.volumeBoost - 1) > 0.001
        || app.targetDeviceUID != nil
        || equalizer != defaultEqualizer
      guard isCustomized else { continue }

      preferences.appAudioIntents[app.logicalID] = PersistedAppAudioIntent(
        appID: app.logicalID,
        desiredVolume: app.desiredVolume,
        isMuted: userMuted,
        volumeBoost: app.volumeBoost,
        equalizerSettings: equalizer,
        targetDeviceUID: app.targetDeviceUID
      )
    }

    // EQ was durable before the unified intent model and may belong to an app
    // that is not present in the cached live session.
    for (appID, equalizer) in preferences.appEqualizerSettings
      where preferences.appAudioIntents[appID] == nil && equalizer != defaultEqualizer {
      preferences.appAudioIntents[appID] = PersistedAppAudioIntent(
        appID: appID,
        equalizerSettings: equalizer
      )
    }

    // Keep the legacy map synchronized for one compatibility release so existing
    // EQ call sites and downgrades preserve values during the additive schema-1 rollout.
    for (appID, intent) in preferences.appAudioIntents
      where preferences.appEqualizerSettings[appID] != intent.equalizerSettings {
      preferences.appEqualizerSettings[appID] = intent.equalizerSettings
    }

    preferences.appAudioIntentMigrationVersion = 1
    return true
  }

  private static var emptySession: AudioSessionSnapshot {
    AudioSessionSnapshot(
      apps: [],
      currentDevice: nil,
      recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: false,
        hasRequiredPermissions: false,
        isRouteRecoveryHealthy: false,
        lastError: "No cached session loaded yet."
      ),
      updatedAt: .now
    )
  }

  private func mergedSession(with liveSession: AudioSessionSnapshot, cached: AudioSessionSnapshot) -> AudioSessionSnapshot {
    let cachedByLogicalID = Dictionary(
      cached.apps.map { ($0.logicalID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    confirmedAppsByLogicalID = Dictionary(
      liveSession.apps.map { ($0.logicalID, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var mergedApps = liveSession.apps
    for index in mergedApps.indices {
      let appID = mergedApps[index].logicalID
      mergedApps[index].isPinned = preferences.pinnedAppIDs.contains(appID)

      // The backend owns whether the app is muted. The store owns only the
      // transient explanation for an already-confirmed mute.
      if mergedApps[index].isMuted,
         cachedByLogicalID[appID]?.muteSource == .autoConferencing {
        mergedApps[index].muteSource = .autoConferencing
      }

      if preferences.excludedAppIDs.contains(appID) {
        makeExcludedPresentation(&mergedApps[index])
        continue
      }

      if let projection = optimisticAppIntentProjections[appID],
         currentAppIntentGeneration[appID] == projection.generation {
        mergedApps[index].desiredVolume = projection.intent.desiredVolume
        mergedApps[index].isMuted = projection.intent.isMuted
        mergedApps[index].volumeBoost = projection.intent.volumeBoost
        mergedApps[index].targetDeviceUID = projection.intent.targetDeviceUID
        mergedApps[index].muteSource = projection.muteSource ?? mergedApps[index].muteSource
        if mergedApps[index].routingState == .managed {
          mergedApps[index].appliedVolume = projection.intent.isMuted
            ? 0
            : projection.intent.desiredVolume
        }
      }

      if let pendingVolume = pendingVolumeTargets[appID] {
        mergedApps[index].desiredVolume = pendingVolume
        if mergedApps[index].routingState == .managed {
          mergedApps[index].appliedVolume = mergedApps[index].isMuted ? 0 : pendingVolume
        }
      }
    }

    return AudioSessionSnapshot(
      apps: mergedApps,
      currentDevice: liveSession.currentDevice,
      recentDeviceIDs: liveSession.recentDeviceIDs,
      supportMatrix: liveSession.supportMatrix,
      backendStatus: liveSession.backendStatus,
      updatedAt: liveSession.updatedAt
    )
  }

  private func mergeAppState(from backendSession: AudioSessionSnapshot, appID: String) {
    guard let updatedApp = backendSession.apps.first(matchingAppKey: appID) else {
      session = backendSession
      invalidateVisibleAppsCache()
      return
    }

    if let index = session.apps.firstIndex(matchingAppKey: appID) {
      session.apps[index] = updatedApp
      session.currentDevice = backendSession.currentDevice
      session.recentDeviceIDs = backendSession.recentDeviceIDs
      session.supportMatrix = backendSession.supportMatrix
      session.backendStatus = backendSession.backendStatus
      session.updatedAt = backendSession.updatedAt
      invalidateVisibleAppsCache()
    } else {
      session = backendSession
      invalidateVisibleAppsCache()
    }
  }

  /// Merge a single backend app into the session and immediately re-derive the
  /// onboarding signals from the now-fresh session.backendStatus, so the route
  /// health (and other onboarding checklist steps) never lag a session-changing
  /// action that already updated backendStatus via mergeAppState.
  private func mergeAppStateAndSyncOnboarding(from backendSession: AudioSessionSnapshot, appID: String) {
    mergeAppState(from: backendSession, appID: appID)
    syncOnboarding(using: session)
  }

  private func persistSessionSnapshot() {
    enqueueSessionPersistence(session)
  }

  private func showToast(
    title: String,
    detail: String? = nil,
    kind: AppToast.Kind,
    duration: Duration? = nil
  ) {
    guard startupState != .shuttingDown else { return }
    // Give failures a longer default so they aren't missed; explicit durations
    // still win (e.g. the startup-failure path passes its own 3.2s).
    let fallbackDuration: Duration
    switch kind {
    case .error, .warning:
      fallbackDuration = errorToastDuration
    case .success, .info:
      fallbackDuration = defaultToastDuration
    }
    let toast = AppToast(
      title: title,
      detail: detail,
      kind: kind,
      duration: duration ?? fallbackDuration
    )

    toasts.append(toast)
    trimToasts()

    // VoiceOver does not announce transient banners on its own. Announce here —
    // exactly once per toast — rather than in each banner's onAppear: with both
    // surfaces mounted (main window + menu-bar popover) a per-banner
    // announcement fires twice, and reopening the popover re-announces stale
    // toasts. Errors/warnings get high priority so they are not interrupted by
    // lower-severity toasts that arrive in the same burst.
    var announcement = AttributedString(toast.accessibilityMessage)
    switch kind {
    case .error, .warning:
      announcement.accessibilitySpeechAnnouncementPriority = .high
    case .success, .info:
      break
    }
    AccessibilityNotification.Announcement(announcement).post()

    scheduleDismissal(id: toast.id, after: toast.duration)
  }

  /// (Re)schedules a toast's auto-dismiss after `delay`, replacing any existing
  /// timer. Guards on the toast still existing so a just-removed toast is never
  /// re-armed. The single source of truth for every dismissal timer.
  private func scheduleDismissal(id: UUID, after delay: Duration) {
    guard startupState != .shuttingDown else { return }
    guard toasts.contains(where: { $0.id == id }) else { return }
    toastDismissals[id]?.cancel()
    toastDismissals[id] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
        self?.dismissToast(id: id)
      } catch {
        return
      }
    }
  }

  func dismissToast(id: UUID) {
    toastDismissals[id]?.cancel()
    toastDismissals.removeValue(forKey: id)
    toasts.removeAll { $0.id == id }
  }

  /// Hold a toast open while the pointer is over it. Extends (rather than cancels)
  /// the auto-dismiss to a generous window, so the toast lingers long enough to
  /// read but can NEVER be orphaned if it's displaced out from under a stationary
  /// cursor — a trimToasts eviction shifting it up, or the popover closing —
  /// without a matching onHover(false). The cap still leaves the manual dismiss
  /// button and the full-text tooltip as escape hatches.
  func pauseToastDismissal(id: UUID) {
    scheduleDismissal(id: id, after: .seconds(8))
  }

  /// Re-arm a toast's auto-dismiss with a short grace once the pointer leaves, so
  /// it doesn't vanish the instant the cursor moves away.
  func resumeToastDismissal(id: UUID) {
    scheduleDismissal(id: id, after: .seconds(1.5))
  }

  private func trimToasts() {
    while toasts.count > maxToasts {
      // Prefer evicting the oldest non-error toast so a routine .success/.info
      // burst (volume commits, keyboard nudges) can't displace an unread .error
      // before the user sees it. Only evict an error when every remaining toast
      // is an error (oldest-first among those).
      let evictionIndex = toasts.firstIndex { $0.kind != .error } ?? toasts.startIndex
      let removed = toasts.remove(at: evictionIndex)
      toastDismissals[removed.id]?.cancel()
      toastDismissals.removeValue(forKey: removed.id)
    }
  }
}

private extension Array where Element == AudioApp {
  func firstIndex(matchingAppKey appKey: String) -> Index? {
    firstIndex { $0.id == appKey || $0.logicalID == appKey }
  }

  func first(matchingAppKey appKey: String) -> AudioApp? {
    first { $0.id == appKey || $0.logicalID == appKey }
  }
}

struct OnboardingState {
  var hasCompletedPrivacySetup = false
  var captureAuthorization: CaptureAuthorizationResult?
  var audioComponentInstalled = false
  var permissionsGranted = false
  var accessibilityPermissionGranted = false
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
