import AppKit
import Foundation
import Observation
import OSLog
import WavesAudioCore

@Observable
@MainActor
final class AppStore {
  typealias RuntimeProcessProbeProvider = @Sendable (Int32) -> RuntimeProcessProbe?

  var session: AudioSessionSnapshot {
    didSet {
      let previousRuntimeIDs = Set(oldValue.apps.map(\.id))
      let currentRuntimeIDs = Set(session.apps.map(\.id))
      if previousRuntimeIDs != currentRuntimeIDs {
        AppIconCache.prune(from: oldValue, using: session)
      }
    }
  }
  var profiles: [Profile]
  /// The most recent profile result after AppStore generation checks and row-level
  /// reconciliation. Retained so diagnostics/tests can inspect every source row in
  /// its original order instead of reducing a mixed apply to one boolean.
  var lastProfileApplyResult: ProfileApplyResult?
  /// The profile the user last selected, used to highlight it in the UI and —
  /// for membership-only grouping profiles — to scope the main window. Not
  /// persisted; a fresh launch starts with no active profile.
  var activeProfileID: UUID?
  /// The mix as it stood right before the last level-bearing profile apply, so
  /// "Reset Mix" can put every app back when the meeting/game/session ends.
  /// Captured once per apply chain: applying Meeting then Focus keeps the
  /// original pre-Meeting mix, so one reset returns to where the user started.
  /// In-memory only — quitting Waves discards it.
  var mixRestorePoint: MixRestorePoint?
  /// Bumped every time a profile is applied/selected, so the main window can
  /// re-focus that profile even when `activeProfileID` is unchanged (e.g.
  /// re-applying the already-active profile from the menu bar).
  var profileFocusToken = 0
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
  private(set) var settingsPaneRequest: SettingsPane?
  private(set) var settingsPaneToken = 0
  /// The app whose mute shortcut the main window should offer to record. Same
  /// request/token shape as the equalizer focus above, and for the same reason:
  /// the menu-bar panel can raise this while the main window does not yet exist.
  private(set) var muteShortcutRequest: String?
  private(set) var muteShortcutToken = 0
  var onboarding = OnboardingState()
  private(set) var installLocationClassification: InstallLocationClassification
  private(set) var installationAdvisoryAcknowledged = false
  var requestedSetupReplay = false
  private(set) var requestedWhatsNew = false
  var preferences: UserPreferences
  var diagnostics: DiagnosticsReport?
  var isRefreshing = false
  var isRecovering = false
  var isLoading = false
  var toasts: [AppToast] = []
  var loginItemStatus = LoginItemStatus(
    isEnabled: false,
    isUserIntentEnabled: false,
    statusDescription: "Disabled"
  )
  var deviceVolumePresets = DeviceVolumePresets()
  var availableDevices: [AudioDevice] = []
  /// Live per-app output levels for meters, populated only while a UI surface
  /// is visible (kept out of `session` so updates don't trigger re-sorts).
  var liveLevels: [String: AudioLevels] = [:]
  /// The adaptive engine's current temporary gain per app (dB), published so
  /// the UI can show which apps Sidechain Focus is holding back or lifting
  /// right now. Empty whenever Adaptive Mix is off or nothing is being
  /// adjusted. Mirrors what the backend is actually applying.
  var adaptiveGainsDBByAppID: [String: Float] = [:]
  /// The previous launch's checked-shutdown report, read from disk at startup.
  /// Surfaced in Diagnostics so a degraded cleanup is still explainable on the
  /// next run instead of vanishing with the process that produced it.
  var previousShutdownReport: ShutdownReport?
  /// Logical IDs of apps that are audible now OR went quiet within the last
  /// `liveLingerWindow`. A just-silenced app stays in the Live list for a beat so
  /// a brief gap, track change, or pause doesn't make its row flicker out — and so
  /// its controls stay put for a moment in case the user wants to grab them or the
  /// signal returns. Only Live-list *membership* lingers; the metered
  /// `mixedAudioLevel` still follows the real signal, so the header ribbon eases
  /// down to nothing on its own.
  var recentlyLiveIDs: Set<String> = []

  let backend: any AudioControlBackend
  let loginItemService: any LoginItemServicing
  let runtimeProcessProbe: RuntimeProcessProbeProvider
  let appIntentCoordinator = AppIntentCoordinator()
  let adaptiveMixCoordinator: AdaptiveMixCoordinator
  let guidedMixerTourCoordinator = GuidedMixerTourCoordinator()
  let automationParser = AutomationCommandParser()
  let urlInvocationLimiter = URLInvocationLimiter()
  let persistenceCoordinator: AppStorePersistenceCoordinator
  let deviceChangeSuppression: DeviceChangeSuppressionCoordinator
  let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "AppStore")
  var startupState: AppStartupState
  var privacySetupError: String?
  var isSafeBootstrapComplete = false
  var privacySetupTask: Task<Void, Never>?
  var audioStartupTask: Task<Void, Never>?
  var shutdownTask: Task<AppShutdownResult, Never>?
  var shutdownResult: AppShutdownResult?
  var ownedOperationTasks: [UUID: Task<Void, Never>] = [:]
  var hasStartedAudioBackend = false
  // Captured once at init from DeviceVolumePresetsStore.load(); consumed (and
  // toasted) the first time start() runs so a corrupt-file recovery is
  // surfaced to the user instead of failing silently.
  var didRecoverCorruptDeviceVolumePresets = false
  // Same one-shot recovery capture for the other three stores, so a corrupt
  // profiles/preferences/session file is surfaced to the user (with its
  // .corrupt backup mentioned) instead of resetting silently.
  var didRecoverCorruptPreferences = false
  var didRecoverCorruptProfiles = false
  var didRecoverCorruptSession = false
  /// Trailing debounce for a drag. Short enough that the sound tracks the handle,
  /// long enough that a fast sweep does not submit a transaction per frame —
  /// matching the interval the equalizer already uses.
  static let volumeDragInterval = Duration.milliseconds(80)
  /// Last snapshots whose store writes actually completed. Rollback must use
  /// these, never another transaction's still-provisional in-memory values.
  var durablySavedPreferences: UserPreferences {
    persistenceCoordinator.durablySavedPreferences
  }
  var durablySavedDeviceVolumePresets: DeviceVolumePresets {
    persistenceCoordinator.durablySavedDevicePresets
  }
  var toastDismissals: [UUID: Task<Void, Never>] = [:]
  var deviceChangeObserver: Task<Void, Never>?
  // Reentrancy guard so rapid device flapping (dock/undock, BT connect) can't
  // stack overlapping handleDeviceChange Tasks that each reassign `session`
  // mid-flight (interleaved snapshot reassignments and preset restores would
  // leave the UI on whichever pass happened to land last).
  var isHandlingDeviceChange = false
  // Set when a device-change event arrives while a handler is already in flight.
  // The in-flight handler clears it and runs exactly one more pass, so a coalesced
  // event (rapid dock/undock, Bluetooth reconnect) is never dropped.
  var pendingDeviceChangeRerun = false
  // Set briefly by selectOutputDevice so the Core Audio default-device listener's
  // ensuing handleDeviceChange suppresses its "Output device changed" info toast:
  // a manual switch already shows an "Output switched" success toast, so a second
  // toast for the same switch is just noise.
  var frontmostAppObserver: NSObjectProtocol?
  var appTerminationObserver: NSObjectProtocol?
  var levelPollTask: Task<Void, Never>?
  var sessionMaintenanceTask: Task<Void, Never>?
  /// Last state pushed to subscribers, so only real changes are sent.
  @ObservationIgnored var lastBroadcastControlApps: [String: ControlApp] = [:]

  /// Brings the mixer forward. Set by the app delegate, which owns the scene.
  @ObservationIgnored var onShowMixerRequested: (() -> Void)?

  /// Asks the system whether a chord is free. Set by the app delegate, which
  /// owns the only object that can answer. Nil in tests and before launch
  /// finishes, where every chord is treated as available and the registration
  /// itself remains the backstop.
  @ObservationIgnored var isChordAvailable: ((HotkeyChord) -> Bool)?

  /// Releases and restores Waves's own registrations. Set by the app delegate.
  ///
  /// A recorder must call `setHotkeysSuspended(true)` while it is open. Waves's
  /// hot keys are consumed by the system before any view sees them, so the one
  /// chord a recorder most needs to capture — the one Waves already owns — is
  /// otherwise the one chord it can never capture.
  @ObservationIgnored var onHotkeySuspensionChange: ((Bool) -> Void)?

  /// Re-registers with the system. Set by the app delegate.
  @ObservationIgnored var onHotkeysChanged: (() -> Void)?

  /// The bindings macOS refused at registration, kept so Settings can mark those
  /// rows instead of drawing them identically to working ones.
  ///
  /// Durable state, not just a toast: `AppToastStack` is mounted only in the
  /// mixer window and the menu-bar panel, so turning shortcuts on from Settings
  /// with the mixer closed showed nothing at all — and the row stayed a trap,
  /// since re-recording the same chord takes the "we already own it"
  /// short-circuit in `assignHotkey`, reports success, and is refused again.
  var rejectedHotkeyIDs: Set<UUID> = []

  /// Called when the external-control preference changes, so the socket opens or
  /// closes immediately rather than on the next launch. Set by the app delegate.
  @ObservationIgnored var onExternalControlPreferenceChange: (() -> Void)?

  /// Pushes a state change to subscribed control clients. Set by the app
  /// delegate while the control socket is open, nil otherwise.
  ///
  /// A closure rather than a reference to the server, so the store stays
  /// unaware of sockets and remains testable without one.
  @ObservationIgnored var controlBroadcast: ((ControlResponse) -> Void)?

  var sessionMaintenanceStartCount = 0
  private(set) var persistenceFailureCount = 0
  private(set) var lastPersistenceError: String?
  var liveLevelsRefcount = 0
  /// False while no Waves window is on screen (all closed, minimized, on an
  /// inactive Space, or fully occluded). The level poll feeds nothing but
  /// meters and the waveform, so polling the backend three times a second for
  /// a surface nobody can see is pure waste — and through 1.3.0 it ran for
  /// days, driving the render loops that tripped the macOS CPU limit. The
  /// view-side `beginLiveLevels` refcount cannot cover this on its own:
  /// `onDisappear` does not fire for a `Window` scene that is merely occluded
  /// or behind another app.
  var isUISurfaceVisible = true
  /// Interval the running poll task was started with, so a cadence change can
  /// be detected without restarting the task on every visibility flicker.
  var activeLevelPollInterval: Duration?
  var isRunningSessionMaintenance = false
  // Per-app one-shot tasks that drop an app out of the lingering-live set once it
  // has been quiet for `liveLingerWindow`. Cancelled (and the app kept) the moment
  // it becomes audible again.
  var lingerRemovalTasks: [String: Task<Void, Never>] = [:]
  var liveLingerWindow: Duration { preferences.liveListLinger.duration }
  let sessionMaintenanceInterval = Duration.seconds(8)
  let adaptiveMixInterval = Duration.milliseconds(100)
  /// Cadence while nothing is routed through Waves. With no managed route there
  /// is nothing to balance or duck, so the 100 ms pass has no work to do — but
  /// it still woke the coordinator, hopped to the backend actor, and asked for
  /// an analysis ten times a second for as long as Adaptive Mix was enabled.
  /// Dropping to a one-second heartbeat keeps the loop self-healing (it notices
  /// a new route within a second no matter how that route appeared) without
  /// relying on every route-creating path remembering to restart it.
  let adaptiveMixIdleInterval = Duration.seconds(1)
  /// Gains identical to the last write are skipped. This bounds how long that
  /// can go on, so a route rebuilt underneath us cannot strand its controller at
  /// unity gain waiting for a value that never changes. 20 passes ≈ 2 s.
  /// The mode a boolean "Adaptive Mix" toggle restores when switched back on.
  /// Seeded from the persisted mode at launch so the choice survives a restart.
  var lastActiveAdaptiveMixMode: AdaptiveMixMode = .both
  /// The last gain map actually handed to the backend, so unchanged values are
  /// not rewritten on every pass.
  private let maxToasts = 3
  private let defaultToastDuration = Duration.seconds(2.0)
  // Failures need longer on screen than routine successes: 2.0s is too short to
  // read a full error string, so .error/.warning toasts that don't pass an
  // explicit duration default to a longer lifetime.
  private let errorToastDuration = Duration.seconds(4.5)
  var previousFrontmostApp: String?
  // Reentrancy guard mirroring isHandlingDeviceChange: rapid frontmost-app
  // switches (activate Zoom, cmd-tab away within ~100ms) must not stack
  // overlapping pause/resume passes that each read mute state captured before
  // the other's backend writes landed — media could end up auto-muted with no
  // call app frontmost and nothing to resume it until the next app switch.
  var isRunningAutoPausePass = false
  // Set when checkAutoPauseMusic fires while a pass is in flight. The runner
  // clears it and runs exactly one more pass, which re-reads the *current*
  // frontmost app — so the latest app switch always wins and none are dropped.
  var pendingAutoPausePassRerun = false
  private var waveLinkSettingsGeneration: UInt64 = 0
  private var pendingWaveLinkRouteRecovery = false
  private let accessibilityAnnouncementPoster: AccessibilityAnnouncementPoster

  init(
    backend: any AudioControlBackend,
    preferencesStore: any PreferencesPersisting,
    profileStore: any ProfilesPersisting,
    sessionStore: any SessionPersisting,
    loginItemService: any LoginItemServicing,
    deviceVolumePresetsStore: any DeviceVolumePresetsPersisting,
    initialStartupState: AppStartupState = .idle,
    deviceChangeSuppressionInterval: Duration = .seconds(5),
    runtimeProcessProbe: @escaping RuntimeProcessProbeProvider = RuntimeProcessIdentity.probe,
    deviceChangeSuppressionSleep: @escaping DeviceChangeSuppressionCoordinator.Sleep = {
      duration in try await Task.sleep(for: duration)
    },
    adaptiveMixSleep: @escaping AdaptiveMixCoordinator.Sleep = {
      duration in try await Task.sleep(for: duration)
    },
    accessibilityAnnouncementPoster: AccessibilityAnnouncementPoster = .live,
    installLocation: InstallLocationClassification = .applications
  ) {
    self.backend = backend
    self.loginItemService = loginItemService
    self.runtimeProcessProbe = runtimeProcessProbe
    self.adaptiveMixCoordinator = AdaptiveMixCoordinator(sleep: adaptiveMixSleep)
    self.startupState = initialStartupState
    self.hasStartedAudioBackend = initialStartupState == .running
    self.accessibilityAnnouncementPoster = accessibilityAnnouncementPoster
    self.installLocationClassification = installLocation
    let loadedPreferences = preferencesStore.load()
    let loadedDeviceVolumePresets = deviceVolumePresetsStore.load()
    self.persistenceCoordinator = AppStorePersistenceCoordinator(
      preferencesStore: preferencesStore,
      profileStore: profileStore,
      sessionStore: sessionStore,
      devicePresetsStore: deviceVolumePresetsStore,
      initialPreferences: loadedPreferences,
      initialDevicePresets: loadedDeviceVolumePresets
    )
    self.deviceChangeSuppression = DeviceChangeSuppressionCoordinator(
      interval: deviceChangeSuppressionInterval,
      sleep: deviceChangeSuppressionSleep
    )
    self.preferences = loadedPreferences
    // So a boolean toggle restores the mode the user actually chose, even across
    // a relaunch. `.off` carries no choice, so keep the default in that case.
    if loadedPreferences.adaptiveMixMode != .off {
      self.lastActiveAdaptiveMixMode = loadedPreferences.adaptiveMixMode
    }
    self.profiles = profileStore.load(defaults: Profile.defaults)
    self.session = sessionStore.load() ?? Self.emptySession
    self.deviceVolumePresets = loadedDeviceVolumePresets
    self.didRecoverCorruptDeviceVolumePresets = deviceVolumePresetsStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptPreferences = preferencesStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptProfiles = profileStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptSession = sessionStore.consumeDidRecoverFromCorruptFile()
    var shouldPersistPreferences = false
    // Migrate pins recorded only on the persisted session (builds before pin
    // state moved into preferences) into the authoritative set exactly once.
    // Advancing the explicit marker even for an empty legacy cache prevents a
    // later stale session from resurrecting pins the user intentionally cleared.
    if preferences.pinMigrationVersion == 0 {
      if preferences.pinnedAppIDs.isEmpty {
        var seen = Set<String>()
        preferences.pinnedAppIDs = session.apps.compactMap { app in
          guard app.isPinned, seen.insert(app.logicalID).inserted else { return nil }
          return app.logicalID
        }
      }
      preferences.pinMigrationVersion = 1
      shouldPersistPreferences = true
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
    var confirmedEqualizers = preferences.appAudioIntents.mapValues(\.equalizerSettings)
    for (appID, equalizer) in preferences.appEqualizerSettings
    where confirmedEqualizers[appID] == nil {
      confirmedEqualizers[appID] = equalizer
    }
    appIntentCoordinator.seedConfirmedState(
      apps: session.apps,
      equalizers: confirmedEqualizers
    )
    loginItemStatus = loginItemService.status
    if preferences.launchAtLoginEnabled != loginItemStatus.isUserIntentEnabled {
      preferences.launchAtLoginEnabled = loginItemStatus.isUserIntentEnabled
      shouldPersistPreferences = true
    }
    self.onboarding = OnboardingState(
      launchAtLoginEnabled: loginItemStatus.isEnabled,
      launchAtLoginRequiresApproval: loginItemStatus.requiresApproval
    )
    self.persistenceCoordinator.onFailure = { [weak self] failure in
      self?.publishPersistenceFailure(failure)
    }
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
      let contribution = measured > 0.001 ? measured : 0.12  // floor for unmetered live apps
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
    let managedEQActive = preferences.managedAudioEqualizer.isEnabled
    var components: [WaveComponent] = []
    for app in visibleApps where !app.isMuted && isLive(app) {
      let measured = liveLevels[app.logicalID].map { Double(max($0.rms, $0.peak * 0.8)) } ?? 0
      // A slightly higher nominal floor than mixedAudioLevel's: an audible
      // but unmetered app should still ripple visibly in the showcase band.
      let level = measured > 0.001 ? measured : 0.18
      // EQ shaping and adaptive gain only act on streams Waves actually
      // processes, so both indicators require a managed route.
      let isManaged = app.routingState == .managed
      let isEqualized =
        isManaged
        && (managedEQActive || equalizerSettings(for: app).isEnabled)
      let adaptiveGainDB =
        isManaged
        ? Double(adaptiveGainsDBByAppID[app.logicalID] ?? 0)
        : 0
      components.append(
        WaveComponent(
          id: app.logicalID,
          level: min(1, pow(level, 0.5)),
          isEqualized: isEqualized,
          adaptiveGainDB: adaptiveGainDB
        ))
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

  /// The four sidebar counts, from a single `visibleApps` evaluation.
  ///
  /// Asking each scope for its own count made the sidebar re-derive (and
  /// re-sort) the whole app list four times per body pass — and `pinnedApps`,
  /// `liveApps`, and `recentApps` each re-derive it again internally, so one
  /// redraw cost roughly seven sorts. At the level poll's cadence that is
  /// several sorts a second for a number that changes rarely.
  struct SourceCounts: Equatable {
    var running = 0
    var pinned = 0
    var live = 0
    var recent = 0
  }

  var sourceCounts: SourceCounts {
    let visible = visibleApps
    let liveIDs = Set(visible.filter(isRecentlyLive).map(\.logicalID))
    return SourceCounts(
      running: visible.count,
      pinned: visible.count(where: \.isPinned),
      live: liveIDs.count,
      recent: preferences.showRecentApps
        ? visible.count { !$0.isPinned && !liveIDs.contains($0.logicalID) }
        : 0
    )
  }

  var currentDeviceName: String {
    session.currentDevice?.name ?? "No output device"
  }

  /// The single definition of what the menu bar is reporting.
  ///
  /// The glyph, its VoiceOver label, and the panel header used to compute this
  /// independently, and the glyph's version checked "anything muted?" before
  /// "anything playing?". Mute one app while another plays and the icon showed a
  /// slashed speaker and announced "Waves, muted" directly above a panel reading
  /// "1 app playing". Playing wins: mute is only the headline when nothing is
  /// audible, which is what the panel already did.
  enum MenuBarStatus {
    case setup
    case playing
    case muted
    case idle
  }

  var menuBarStatus: MenuBarStatus {
    guard isAudioRunning else { return .setup }
    // What's playing *now*, not the lingering Live list — the glyph must drop
    // back to idle the moment audio actually stops.
    let apps = visibleApps
    if apps.contains(where: isLive) { return .playing }
    if apps.contains(where: \.isMuted) { return .muted }
    return .idle
  }

  var menuBarIconName: String {
    switch menuBarStatus {
    case .setup: "lock.shield.fill"
    case .playing: "speaker.wave.3.fill"
    case .muted: "speaker.slash.fill"
    case .idle: "speaker.wave.2.fill"
    }
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

  var guidedSetupFacts: GuidedSetupFacts {
    GuidedSetupFacts(
      hasAcceptedPrivacy: preferences.hasCompletedPrivacySetup,
      captureAuthorization: onboarding.captureAuthorization,
      audioComponentInstalled: onboarding.audioComponentInstalled,
      outputDeviceVisible: onboarding.outputDeviceVisible,
      routeHealthReady: onboarding.routeHealthReady,
      isAudioRunning: isAudioRunning
    )
  }

  var onboardingLaunchDecision: OnboardingLaunchDecision {
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: installLocationClassification,
        installationAdvisoryAcknowledged: installationAdvisoryAcknowledged,
        requestedSetupReplay: requestedSetupReplay,
        hasEligibleTourApp: session.apps.contains { app in
          app.routingState == .managed
            && isLive(app)
            && !preferences.excludedAppIDs.contains(app.logicalID)
        }
      )
    )
  }

  var guidedMixerTourTargetApp: AudioApp? {
    guard case let .active(_, appID) = guidedMixerTourCoordinator.state else { return nil }
    return session.apps.first { $0.logicalID == appID }
  }

  var guidedMixerTourPresentation: GuidedMixerTourPresentation? {
    guard case let .active(moment, _) = guidedMixerTourCoordinator.state else {
      return nil
    }
    let target = guidedMixerTourTargetApp
    return GuidedMixerTourPresentation(
      moment: moment,
      appName: target?.displayName ?? guidedMixerTourCoordinator.targetDisplayName ?? "This app",
      isTargetAvailable: target != nil
    )
  }

  var shouldShowWhatsNew: Bool {
    if requestedWhatsNew { return true }
    guard case let .mixer(showWhatsNew, _) = onboardingLaunchDecision else {
      return false
    }
    return showWhatsNew
  }

  func continueFromInstallationAdvisory() {
    installationAdvisoryAcknowledged = true
  }

  func runRequiredSetupReplay() {
    requestedSetupReplay = true
    onShowMixerRequested?()
  }

  func cancelRequiredSetupReplay() {
    requestedSetupReplay = false
  }

  func showWhatsNew() {
    requestedWhatsNew = true
    onShowMixerRequested?()
  }

  func startGuidedMixerTour() {
    requestedWhatsNew = false
    focusSource(.running)
    onShowMixerRequested?()
    preferences.whatsNewDismissedVersion = max(
      preferences.whatsNewDismissedVersion,
      OnboardingExperience.currentVersion
    )

    guard let app = eligibleGuidedTourApp else {
      preferences.deferredTourVersion = OnboardingExperience.currentVersion
      persistPreferences()
      showToast(
        title: "Tour ready when an app is playing",
        detail: "Start compatible audio and Waves will offer Show Me How in the mixer.",
        kind: .info
      )
      return
    }

    preferences.deferredTourVersion = 0
    persistPreferences()
    guidedMixerTourCoordinator.start(
      appID: app.logicalID,
      displayName: app.displayName,
      originalVolume: app.desiredVolume,
      originalMuted: app.isMuted
    )
  }

  func advanceGuidedMixerTour() {
    if case let .active(moment, _) = guidedMixerTourCoordinator.state,
      moment.requiresAcceptedMixerIntent,
      guidedMixerTourTargetApp != nil
    {
      return
    }
    guard guidedMixerTourCoordinator.advance() == .completed else { return }
    preferences.guidedTourCompletedVersion = max(
      preferences.guidedTourCompletedVersion,
      OnboardingExperience.currentVersion
    )
    preferences.deferredTourVersion = 0
    persistPreferences()
    showToast(
      title: "Tour complete",
      detail: "Replay it any time from Setup & Repair or Help.",
      kind: .success
    )
  }

  func backGuidedMixerTour() {
    guidedMixerTourCoordinator.back()
  }

  func endGuidedMixerTour(reason: GuidedMixerTourEndReason) {
    guard guidedMixerTourCoordinator.end(reason: reason) else { return }
    preferences.guidedTourDismissedVersion = max(
      preferences.guidedTourDismissedVersion,
      OnboardingExperience.currentVersion
    )
    preferences.deferredTourVersion = 0
    persistPreferences()
  }

  func dismissGuidedTourTip() {
    preferences.guidedTourDismissedVersion = max(
      preferences.guidedTourDismissedVersion,
      OnboardingExperience.currentVersion
    )
    preferences.deferredTourVersion = 0
    persistPreferences()
  }

  func dismissWhatsNew() {
    requestedWhatsNew = false
    preferences.whatsNewDismissedVersion = max(
      preferences.whatsNewDismissedVersion,
      OnboardingExperience.currentVersion
    )
    persistPreferences()
  }

  private var eligibleGuidedTourApp: AudioApp? {
    visibleApps.first { app in
      app.routingState == .managed
        && isLive(app)
        && !preferences.excludedAppIDs.contains(app.logicalID)
        && MixerRouteControlPolicy(app: app).allowsAudioControl
    }
  }

  /// Whether the mixer can be shown immediately, before audio startup finishes.
  ///
  /// True only for a returning user: setup is complete and a previous session was
  /// restored from disk, so there are real rows to draw. Startup then proceeds
  /// underneath and the rows fill in, rather than the window showing a splash and
  /// reflowing when it completes.
  ///
  /// Deliberately narrow. A first launch, a pending privacy prompt, an incomplete
  /// guided setup, or a failed start all still get the surface that explains
  /// itself — showing an empty mixer in those cases would be worse than a splash,
  /// because it would look like Waves found nothing.
  var showsWarmStartMixer: Bool {
    guard preferences.hasCompletedPrivacySetup, preferences.hasCompletedGuidedSetup else {
      return false
    }
    guard !session.apps.isEmpty else { return false }
    switch startupState {
    case .idle, .startingAudio, .running:
      return true
    case .awaitingPrivacy, .savingPrivacyConsent, .shuttingDown, .failed:
      return false
    }
  }

  /// True while the mixer is on screen but not yet able to act — the warm-start
  /// window. Controls read as unavailable rather than firing a "Finish setup"
  /// toast on a click that was reasonable to make.
  var isWarmingUp: Bool {
    showsWarmStartMixer && startupState != .running
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

    appIntentCoordinator.clearPendingVolume(for: appID)
    appIntentCoordinator.cancelVolumeDebounce(for: appID)
    appIntentCoordinator.clearPendingEqualizer(for: appID)
    appIntentCoordinator.cancelEqualizerDebounce(for: appID)
    supersedeAppIntentWork(forAppID: appID)
    appIntentCoordinator.releaseAutomaticMute(for: appID)

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
      let overrides =
        effectiveRestorationOverrides(
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
      shutdownResult: shutdownResult,
      previousShutdown: previousShutdownReport
    )
  }

  var lifecycleSnapshot: AppStoreLifecycleSnapshot {
    AppStoreLifecycleSnapshot(
      intent: appIntentCoordinator.lifecycleSnapshot,
      persistence: persistenceCoordinator.lifecycleSnapshot,
      adaptive: adaptiveMixCoordinator.lifecycleSnapshot,
      deviceSuppression: deviceChangeSuppression.lifecycleSnapshot,
      startupTaskCount: [privacySetupTask, audioStartupTask].compactMap { $0 }.count,
      ownedOperationCount: ownedOperationTasks.count,
      hasLevelPoll: levelPollTask != nil,
      hasSessionMaintenance: sessionMaintenanceTask != nil,
      toastDismissalCount: toastDismissals.count,
      lingerTaskCount: lingerRemovalTasks.count,
      observerCount: [frontmostAppObserver, appTerminationObserver].compactMap { $0 }.count
        + (deviceChangeObserver == nil ? 0 : 1),
      backendStarted: hasStartedAudioBackend
    )
  }

  var automationParserInvocationCount: Int {
    automationParser.invocationCount
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
    deviceChangeSuppression.begin(deviceID: device.id)
    startOwnedOperation { store in
      do {
        try await store.backend.setDefaultOutputDevice(uid: device.id)
        let devices = await store.backend.availableOutputDevices()
        guard !Task.isCancelled, store.startupState == .running else { return }
        store.availableDevices = devices
        store.showToast(title: "Output switched", detail: device.name, kind: .success, duration: .seconds(1.4))
      } catch {
        guard store.startupState == .running else { return }
        store.deviceChangeSuppression.clear(ifMatching: device.id)
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
        // Record the downgrade as the mode to restore, so switching Adaptive
        // Mix off and on again brings back Loudness Balance — what the user was
        // last actually shown — rather than resurrecting Both, which would turn
        // straight around and clear this auto-pause setting again.
        lastActiveAdaptiveMixMode = .loudnessBalance
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

  func setPerAppAudioController(_ controller: PerAppAudioController) {
    guard startupState != .shuttingDown else { return }
    guard preferences.perAppAudioController != controller else { return }
    preferences.perAppAudioController = controller
    persistPreferences()
    applyWaveLinkSettingsAndRecoverRoutes()
  }

  func setWaveLinkCompatibilityEnabled(_ isEnabled: Bool) {
    guard startupState != .shuttingDown else { return }
    guard preferences.waveLinkCompatibilityEnabled != isEnabled else { return }
    preferences.waveLinkCompatibilityEnabled = isEnabled
    persistPreferences()
    applyWaveLinkSettingsAndRecoverRoutes()
  }

  private func applyWaveLinkSettingsAndRecoverRoutes() {
    waveLinkSettingsGeneration &+= 1
    let generation = waveLinkSettingsGeneration
    let compatibilityEnabled = preferences.waveLinkCompatibilityEnabled
    let controller = preferences.perAppAudioController
    startOwnedOperation { store in
      await store.backend.setWaveLinkCompatibilityEnabled(compatibilityEnabled)
      await store.backend.setPerAppAudioController(controller)
      guard !Task.isCancelled else { return }
      guard generation == store.waveLinkSettingsGeneration else {
        await store.backend.setWaveLinkCompatibilityEnabled(
          store.preferences.waveLinkCompatibilityEnabled
        )
        await store.backend.setPerAppAudioController(store.preferences.perAppAudioController)
        return
      }
      if store.startupState == .running {
        store.pendingWaveLinkRouteRecovery = true
        store.requestWaveLinkRouteRecoveryIfNeeded()
      } else if store.startupState == .startingAudio
        || store.startupState == .savingPrivacyConsent
      {
        store.pendingWaveLinkRouteRecovery = true
      }
    }
  }

  func requestWaveLinkRouteRecoveryIfNeeded() {
    guard pendingWaveLinkRouteRecovery, startupState == .running else { return }
    guard !isRecovering else { return }
    pendingWaveLinkRouteRecovery = false
    recoverRoutes()
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
          appIntentCoordinator.isCurrent(result.generation, for: app.logicalID)
        else {
          logger.error(
            "Auto-pause did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
          )
          continue
        }
        if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[index].muteSource = .autoConferencing
        }
        guard
          appIntentCoordinator.claimAutomaticMute(
            for: app.logicalID,
            generation: result.generation
          )
        else { continue }
        pausedNames.append(app.displayName)
        logger.info("Auto-paused music app: \(app.displayName, privacy: .public)")
      }
    } else {
      let resumable = visibleApps.filter {
        $0.isMuted
          && $0.muteSource == .autoConferencing
          && appIntentCoordinator.ownsAutomaticMute(for: $0.logicalID)
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
          appIntentCoordinator.isCurrent(result.generation, for: app.logicalID)
        else {
          logger.error(
            "Auto-resume did not commit for \(app.displayName, privacy: .public): \(String(describing: result.outcome), privacy: .public)"
          )
          continue
        }
        if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[index].muteSource = .user
        }
        appIntentCoordinator.releaseAutomaticMute(for: app.logicalID)
        resumedNames.append(app.displayName)
        logger.info("Auto-resumed music app: \(app.displayName, privacy: .public)")
      }
    }

    guard !pausedNames.isEmpty || !resumedNames.isEmpty else { return }
    persistSessionSnapshot()
    syncOnboarding(using: session)

    if !pausedNames.isEmpty {
      let detail =
        pausedNames.count == 1
        ? "\(pausedNames[0]) muted for your call."
        : "\(pausedNames.count) apps muted for your call."
      showToast(
        title: "Auto-paused media",
        detail: detail,
        kind: .info,
        duration: .seconds(2.4)
      )
    } else {
      let detail =
        resumedNames.count == 1
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

  func requestMuteShortcutAssignment(for app: AudioApp) {
    muteShortcutRequest = app.logicalID
    muteShortcutToken &+= 1
  }

  func consumeMuteShortcutRequest() -> String? {
    defer { muteShortcutRequest = nil }
    return muteShortcutRequest
  }

  /// Asks the Settings scene to open on a specific pane. Same request/token
  /// shape as the equalizer and source focus requests, for the same reason: the
  /// Settings window may not exist yet when the request is made, so the token
  /// covers the already-open case and the request survives for a fresh view's
  /// `onAppear`.
  func requestSettingsPane(_ pane: SettingsPane) {
    settingsPaneRequest = pane
    settingsPaneToken &+= 1
  }

  func consumeSettingsPaneRequest() -> SettingsPane? {
    defer { settingsPaneRequest = nil }
    return settingsPaneRequest
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

  func recoverRoutes() {
    guard requireAudioRunning() else { return }
    // Mirror refresh()'s in-flight guard: the toolbar/Settings/Onboarding
    // "Recover managed routes" buttons call this directly, so rapid clicks would
    // otherwise stack overlapping recovery tasks that each reassign session and
    // re-query diagnostics.
    guard !isRecovering else { return }

    isRecovering = true
    startOwnedOperation { store in
      defer {
        store.isRecovering = false
        store.requestWaveLinkRouteRecoveryIfNeeded()
      }
      do {
        let recovered = try await store.backend.recoverRoutes()
        guard !Task.isCancelled, store.startupState == .running else { return }
        store.session = store.mergedSession(with: recovered, cached: store.session)
        let includePreset = store.preferences.enablePerDeviceVolumePresets
        for appID in store.session.apps.map(\.logicalID) {
          _ = await store.restoreConfiguredApp(
            appID: appID,
            defaultReason: .routeRecovery,
            deviceID: store.currentDeviceID,
            includeDevicePreset: includePreset
          )
        }
        store.diagnostics = await store.backend.diagnosticsReport()
        store.onboarding.captureAuthorization = await store.backend.captureAuthorizationResult()
        store.persistSessionSnapshot()
        store.syncOnboarding(using: store.session)
        // backend.recoverRoutes() does not throw when a prerequisite is still
        // unmet (e.g. capture permission denied or no output device): it rebuilds
        // the snapshot, which recomputes isRouteRecoveryHealthy. Branch on the
        // resulting health instead of reporting success on every no-throw return,
        // so the toast can't claim "Routes recovered" while the Setup step stays
        // in its "needs action" state.
        let status = store.session.backendStatus
        if status.isRouteRecoveryHealthy {
          store.showToast(
            title: "Routes recovered",
            detail: "Managed routing paths were reattached.",
            kind: .success
          )
        } else {
          let reason: String
          if !status.hasRequiredPermissions {
            reason = "Audio capture isn't granted. Allow audio recording in System Settings, then try again."
          } else if store.session.currentDevice == nil {
            reason = "No output device is available. Connect an output device, then try again."
          } else {
            reason = status.lastError ?? "Routes are still not healthy. Check Diagnostics for details."
          }
          store.showToast(
            title: "Routes still need attention",
            detail: reason,
            kind: .warning
          )
        }
      } catch {
        guard store.startupState == .running else { return }
        store.session = store.mergedSession(with: await store.backend.currentSnapshot(), cached: store.session)
        store.diagnostics = await store.backend.diagnosticsReport()
        store.onboarding.captureAuthorization = await store.backend.captureAuthorizationResult()
        store.persistSessionSnapshot()
        store.syncOnboarding(using: store.session)
        store.showToast(title: "Recovery failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func postAccessibilityAnnouncement(_ message: String) {
    accessibilityAnnouncementPoster.post(AttributedString(message))
  }

  func refreshDiagnostics() {
    guard requireAudioRunning() else { return }
    startOwnedOperation { store in
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
      if let rebuilt = try? await store.backend.refresh() {
        snapshot = rebuilt
      } else {
        snapshot = await store.backend.currentSnapshot()
      }
      guard !Task.isCancelled, store.startupState == .running else { return }
      store.diagnostics = await store.backend.diagnosticsReport()
      store.onboarding.captureAuthorization = await store.backend.captureAuthorizationResult()
      guard !Task.isCancelled, store.startupState == .running else { return }
      // The live snapshot owns backend truth; mergedSession reapplies only the
      // store's current transaction/slider projection and preferences-owned tags.
      store.session = store.mergedSession(with: snapshot, cached: store.session)
      store.syncOnboarding(using: store.session)
    }
  }

  /// Resolves the app a global hotkey should act on. Prefers the OS-frontmost
  /// application (the one the user is actually looking at) when Waves manages it,
  /// mirroring checkAutoPauseMusic's frontmost detection. Falls back to the
  /// sort-first active/visible app only when no managed match exists, so an
  /// audible background app no longer steals the hotkey from a silent focused one.
  private func frontmostManagedApp() -> AudioApp? {
    let frontmost = NSWorkspace.shared.frontmostApplication
    // A hot key fires even while Waves' own mixer/Settings window is frontmost.
    // There is no single "the app the user is working in" in that case —
    // falling through to the activeApps/visibleApps.first fallback below would
    // silently act on an arbitrary row instead of the one the user actually has
    // in view. Do nothing instead.
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

  /// Sidechain focus must represent the actual foreground application. Unlike
  /// keyboard shortcuts, it must not fall back to an arbitrary active row when
  /// the foreground process is unmanaged or Waves itself.
  func frontmostManagedAppIDForAdaptiveMix(in apps: [AudioApp]) -> String? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else {
      return nil
    }
    let bundleID = frontmost.bundleIdentifier
    let pid = frontmost.processIdentifier
    return apps.first(where: { app in
      (bundleID != nil && app.bundleID == bundleID) || app.pid == pid
    })?.logicalID
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
  }

  func persistProfiles() {
    enqueueProfilesPersistence(profiles)
  }

  func persistDeviceVolumePresets() {
    enqueueDevicePresetsPersistence(deviceVolumePresets)
  }

  func enqueuePreferencesPersistence(_ snapshot: UserPreferences) {
    persistenceCoordinator.enqueuePreferences(snapshot)
  }

  func enqueueProfilesPersistence(_ snapshot: [Profile]) {
    persistenceCoordinator.enqueueProfiles(snapshot)
  }

  func enqueueSessionPersistence(_ snapshot: AudioSessionSnapshot) {
    persistenceCoordinator.enqueueSession(snapshot)
  }

  func enqueueDevicePresetsPersistence(_ snapshot: DeviceVolumePresets) {
    persistenceCoordinator.enqueueDevicePresets(snapshot)
  }

  /// Waits for every currently tracked background persistence runner. The loop
  /// also observes runners started while an earlier one is suspended, providing
  /// the drain boundary that the checked shutdown task will await later.
  func drainPersistenceTasks() async {
    await persistenceCoordinator.drain()
  }

  var trackedPersistenceTaskCount: Int {
    persistenceCoordinator.trackedTaskCount
  }

  func drainAppIntentTransactions() async {
    await appIntentCoordinator.drain()
  }

  var trackedAppIntentTaskCount: Int {
    appIntentCoordinator.lifecycleSnapshot.trackedTaskCount
  }

  /// Explicit durable boundaries for future transaction/profile/privacy work.
  /// Each helper first removes older queued snapshots, then submits an immutable
  /// current snapshot and surfaces any write failure to its caller.
  func savePreferencesDurably() async throws {
    try await persistenceCoordinator.savePreferencesDurably(preferences)
  }

  func saveProfilesDurably() async throws {
    try await persistenceCoordinator.saveProfilesDurably(profiles)
  }

  func saveSessionDurably() async throws {
    try await persistenceCoordinator.saveSessionDurably(session)
  }

  func saveDeviceVolumePresetsDurably() async throws {
    try await persistenceCoordinator.saveDevicePresetsDurably(deviceVolumePresets)
  }

  /// Flushes every store, independently.
  ///
  /// This runs on the quit path, where partial persistence is the worst
  /// outcome: a `try` chain meant the first store to fail cancelled the other
  /// three, so one bad settings write could silently discard the session,
  /// profiles, and device presets — and the single error it threw named "saved
  /// data flush" rather than the store that actually failed. Each store now gets
  /// its own attempt and its own attributed report.
  func drainAndFlushPersistence() async {
    await persistenceCoordinator.flush()
  }

  func reportPersistenceFailure(
    store: PersistenceStoreIdentifier,
    error: Error,
    showWarning: Bool = true
  ) {
    persistenceCoordinator.recordFailure(
      store: store,
      error: error,
      showWarning: showWarning
    )
  }

  private func publishPersistenceFailure(_ failure: AppStorePersistenceFailure) {
    logger.error("Persistence failed for \(failure.message, privacy: .public)")
    persistenceFailureCount += 1
    lastPersistenceError = failure.message
    guard failure.shouldWarn else { return }
    showToast(
      title: "Changes may not be saved",
      detail: "Waves couldn't save \(failure.store.displayName). \(failure.errorDescription)",
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

  /// Uses the folded key derived once from each app's immutable display name.
  private func sortedByFoldedDisplayName(_ apps: [AudioApp]) -> [AudioApp] {
    apps.sorted { lhs, rhs in
      if lhs.displayNameSortKey != rhs.displayNameSortKey {
        return lhs.displayNameSortKey < rhs.displayNameSortKey
      }
      return lhs.logicalID < rhs.logicalID
    }
  }

  private func sortedApps(_ apps: [AudioApp]) -> [AudioApp] {
    func byName(_ app1: AudioApp, _ app2: AudioApp) -> Bool {
      if app1.displayNameSortKey != app2.displayNameSortKey {
        return app1.displayNameSortKey < app2.displayNameSortKey
      }
      return app1.logicalID < app2.logicalID
    }

    switch preferences.sortMode {
    case .name:
      return sortedByFoldedDisplayName(apps)
    case .activity:
      // Rank once per app rather than once per comparison: activityRank consults
      // the live-level poll and the linger window, so it is not free either.
      let ranks = Dictionary(
        apps.map { ($0.logicalID, activityRank(for: $0)) },
        uniquingKeysWith: { first, _ in first }
      )
      return apps.sorted { app1, app2 in
        let rank1 = ranks[app1.logicalID] ?? 0
        let rank2 = ranks[app2.logicalID] ?? 0
        if rank1 != rank2 { return rank1 < rank2 }
        return byName(app1, app2)
      }
    case .category:
      return apps.sorted {
        if $0.category.rawValue != $1.category.rawValue {
          return $0.category.rawValue < $1.category.rawValue
        }
        return byName($0, $1)
      }
    case .manual:
      // A position map, not `firstIndex(of:)` — that was a linear scan of the
      // custom order inside the comparator, so manual sort was quadratic in the
      // number of remembered apps.
      let positions = Dictionary(
        preferences.customAppOrder.enumerated().map { ($1, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      return apps.sorted { app1, app2 in
        let index1 = positions[app1.logicalID] ?? Int.max
        let index2 = positions[app2.logicalID] ?? Int.max
        if index1 != index2 { return index1 < index2 }
        return byName(app1, app2)
      }
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
      source.allSatisfy({ $0 >= 0 && $0 < displayedIDs.count })
    else {
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
  }

  func syncOnboarding(using snapshot: AudioSessionSnapshot) {
    var next = onboarding
    next.hasCompletedPrivacySetup = preferences.hasCompletedPrivacySetup
    next.audioComponentInstalled = snapshot.backendStatus.isAudioComponentInstalled
    switch next.captureAuthorization {
    case .some(.authorized):
      next.permissionsGranted = true
    case .some(.notGranted), .some(.undetermined), .some(.unsupported), .some(.probeFailed):
      next.permissionsGranted = false
    case .none:
      next.permissionsGranted =
        preferences.hasCompletedPrivacySetup
        && snapshot.backendStatus.hasRequiredPermissions
    }
    next.outputDeviceVisible = snapshot.currentDevice != nil
    next.routeHealthReady =
      preferences.hasCompletedPrivacySetup
      && next.permissionsGranted
      && snapshot.backendStatus.isRouteRecoveryHealthy
    if onboarding != next {
      onboarding = next
    }
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
    if loginItemStatus != status {
      loginItemStatus = status
    }
    let launchAtLoginIntentEnabled = status.isUserIntentEnabled
    if onboarding.launchAtLoginEnabled != status.isEnabled
      || onboarding.launchAtLoginRequiresApproval != status.requiresApproval
    {
      onboarding.launchAtLoginEnabled = status.isEnabled
      onboarding.launchAtLoginRequiresApproval = status.requiresApproval
    }
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
      let isCustomized =
        abs(app.desiredVolume - 1) > 0.001
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

  func mergedSession(with liveSession: AudioSessionSnapshot, cached: AudioSessionSnapshot) -> AudioSessionSnapshot {
    let cachedByLogicalID = Dictionary(
      cached.apps.map { ($0.logicalID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    appIntentCoordinator.replaceConfirmedApps(liveSession.apps)

    var mergedApps = liveSession.apps
    for index in mergedApps.indices {
      let appID = mergedApps[index].logicalID
      mergedApps[index].isPinned = preferences.pinnedAppIDs.contains(appID)

      // The backend owns whether the app is muted. The store owns only the
      // transient explanation for an already-confirmed mute.
      if mergedApps[index].isMuted,
        cachedByLogicalID[appID]?.muteSource == .autoConferencing
      {
        mergedApps[index].muteSource = .autoConferencing
      }

      if preferences.excludedAppIDs.contains(appID) {
        makeExcludedPresentation(&mergedApps[index])
        continue
      }

      if let projection = appIntentCoordinator.currentProjection(for: appID) {
        mergedApps[index].desiredVolume = projection.intent.desiredVolume
        mergedApps[index].isMuted = projection.intent.isMuted
        mergedApps[index].volumeBoost = projection.intent.volumeBoost
        mergedApps[index].targetDeviceUID = projection.intent.targetDeviceUID
        mergedApps[index].muteSource = projection.muteSource ?? mergedApps[index].muteSource
        if mergedApps[index].routingState == .managed {
          mergedApps[index].appliedVolume =
            projection.intent.isMuted
            ? 0
            : projection.intent.desiredVolume
        }
      }

      if let pendingVolume = appIntentCoordinator.pendingVolume(for: appID) {
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

  func persistSessionSnapshot() {
    if preferences.hasCompletedPrivacySetup {
      enqueueSessionPersistence(session)
    }
  }

  func showToast(
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
    accessibilityAnnouncementPoster.post(announcement)

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

extension Array where Element == AudioApp {
  func firstIndex(matchingAppKey appKey: String) -> Index? {
    firstIndex { $0.id == appKey || $0.logicalID == appKey }
  }

  func first(matchingAppKey appKey: String) -> AudioApp? {
    first { $0.id == appKey || $0.logicalID == appKey }
  }
}
