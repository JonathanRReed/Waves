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

@Observable
@MainActor
final class AppStore {
  var session: AudioSessionSnapshot
  var profiles: [Profile]
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
  private let preferencesStore: PreferencesStore
  private let profileStore: ProfileStore
  private let sessionStore: SessionStore
  private let loginItemService: LoginItemService
  private let deviceVolumePresetsStore: DeviceVolumePresetsStore
  private let logger = Logger(subsystem: "com.waves.store", category: "AppStore")
  private var isBootstrapped = false
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
  private var pendingVolumeTargets: [String: Float] = [:]
  private var pendingVolumeApplyTasks: [String: Task<Void, Never>] = [:]
  private var pendingEqualizerApplyTasks: [String: Task<Void, Never>] = [:]
  private var volumeApplyToken: [String: Int] = [:]
  private let volumeApplyDelay = Duration.milliseconds(50) // Optimized from 80ms for better responsiveness
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
  private var adaptiveMixTask: Task<Void, Never>?
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
  private let maxPendingTasks = 100
  private var urlSchemeRequestTimes: [Date] = []
  private let maxURLSchemeRequests = 10
  private let urlSchemeRequestWindow: TimeInterval = 60
  // Debounce the "throttled" toast so a flood of dropped commands surfaces at
  // most one toast per window instead of one per dropped command.
  private var lastURLSchemeThrottleToast: Date?
  private let urlSchemeThrottleToastInterval: TimeInterval = 5

  init(
    backend: any AudioControlBackend,
    preferencesStore: PreferencesStore,
    profileStore: ProfileStore,
    sessionStore: SessionStore,
    loginItemService: LoginItemService,
    deviceVolumePresetsStore: DeviceVolumePresetsStore = DeviceVolumePresetsStore()
  ) {
    self.backend = backend
    self.preferencesStore = preferencesStore
    self.profileStore = profileStore
    self.sessionStore = sessionStore
    self.loginItemService = loginItemService
    self.deviceVolumePresetsStore = deviceVolumePresetsStore
    self.preferences = preferencesStore.load()
    self.profiles = profileStore.load(defaults: Profile.defaults)
    self.session = sessionStore.load() ?? Self.emptySession
    self.deviceVolumePresets = deviceVolumePresetsStore.load()
    self.didRecoverCorruptDeviceVolumePresets = deviceVolumePresetsStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptPreferences = preferencesStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptProfiles = profileStore.consumeDidRecoverFromCorruptFile()
    self.didRecoverCorruptSession = sessionStore.consumeDidRecoverFromCorruptFile()
    // Migrate pins recorded only on the persisted session (builds before pin
    // state moved into preferences) into the authoritative set, just once.
    if preferences.pinnedAppIDs.isEmpty {
      let sessionPins = session.apps.filter(\.isPinned).map(\.logicalID)
      if !sessionPins.isEmpty {
        preferences.pinnedAppIDs = Array(Set(sessionPins))
      }
    }
    // Only manual sort depends on a saved order; fall back to name if it is
    // missing. Activity sort needs no stored order and must be preserved across
    // launches.
    if preferences.sortMode == .manual && preferences.customAppOrder.isEmpty {
      preferences.sortMode = .name
    }
    if !preferences.urlSchemeAutomationAcknowledged {
      preferences.enableURLScheme = false
      preferences.urlSchemeAutomationAcknowledged = true
    }
    loginItemStatus = loginItemService.status
    self.preferences.launchAtLoginEnabled = loginItemStatus.isUserIntentEnabled
    self.onboarding = OnboardingState(
      launchAtLoginEnabled: loginItemStatus.isEnabled,
      launchAtLoginRequiresApproval: loginItemStatus.requiresApproval
    )
    persistPreferences()
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
    guard !isBootstrapped else {
      return
    }

    isBootstrapped = true
    isLoading = session.apps.isEmpty
    observeDeviceChanges()
    observeFrontmostAppChanges()
    observeAppTermination()

    Task {
      defer { isLoading = false }

      do {
        let warmSnapshot = session
        if !warmSnapshot.apps.isEmpty {
          session = warmSnapshot
          syncOnboarding(using: session)
        }

        try await backend.start()
        startSessionMaintenance()
        let built = await backend.currentSnapshot()
        session = mergedSession(with: built, cached: warmSnapshot)
        invalidateVisibleAppsCache()
        cleanupStaleEntries()
        await reapplyRestoredAudioState()
        if preferences.adaptiveMixMode.usesSpeechFocus,
           preferences.autoPauseMusicForConferencing {
          preferences.autoPauseMusicForConferencing = false
          persistPreferences()
        }
        restartAdaptiveMixing()
        // The generic session snapshot replays the last persisted device's levels.
        // If the active output device at launch has its own tuned per-device
        // preset, apply it now so that device's saved levels win (and aren't
        // ignored until the user manually switches devices).
        if preferences.enablePerDeviceVolumePresets, preferences.autoRestoreDevice, let deviceID = currentDeviceID {
          await restoreDeviceVolumePresets(for: deviceID)
        }
        diagnostics = await backend.diagnosticsReport()
        availableDevices = await backend.availableOutputDevices()
        persistSessionSnapshot()
        syncOnboarding(using: session)
        checkAutoPauseMusic()
        // One combined toast for every store that had to reset a corrupted
        // file — the originals are preserved beside the replacements, and the
        // user deserves to know both facts (a silent reset reads as data loss
        // with no explanation and no recovery path).
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
        showToast(title: "Waves is ready", detail: "Per-app audio mixer loaded.", kind: .success)
      } catch {
        isBootstrapped = false
        showToast(title: "Startup failed", detail: error.localizedDescription, kind: .error, duration: .seconds(3.2))
      }
    }
  }

  func refresh(announce: Bool = true) {
    guard !isRefreshing else {
      return
    }

    isRefreshing = true
    isLoading = session.apps.isEmpty
    Task {
      defer {
        isRefreshing = false
        isLoading = false
      }

      do {
        // Snapshot the apps already present so we can detect ones that launched
        // since the last refresh and apply their saved per-device preset (an app
        // that appears after a device switch otherwise never gets its device-B
        // levels — only apps running at switch time are restored).
        let knownAppIDs = Set(session.apps.map { $0.logicalID })
        // Merge cached-only fields (like the .autoConferencing muteSource tag,
        // which the backend never knows about) instead of reassigning wholesale
        // — a bare reassignment resets muteSource to .user, so auto-paused
        // media could never auto-resume after a manual refresh.
        session = mergedSession(with: try await backend.refresh(), cached: session)
        invalidateVisibleAppsCache()
        cleanupStaleEntries()
        if preferences.enablePerDeviceVolumePresets, preferences.autoRestoreDevice, let deviceID = currentDeviceID {
          await restoreDeviceVolumePresets(for: deviceID, limitedTo: { !knownAppIDs.contains($0) })
        }
        persistSessionSnapshot()
        diagnostics = await backend.diagnosticsReport()
        syncOnboarding(using: session)
        checkAutoPauseMusic()
        // Callers that drive a silent re-sync (e.g. onboarding's onAppear /
        // scenePhase hooks) pass announce: false to suppress the success toast
        // while still performing the snapshot/diagnostics/onboarding refresh.
        if announce {
          let visibleCount = visibleApps.count
          showToast(title: "Library refreshed", detail: "\(visibleCount) app\(visibleCount == 1 ? "" : "s") detected.", kind: .info)
        }
      } catch {
        showToast(title: "Refresh failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  private func startSessionMaintenance() {
    guard sessionMaintenanceTask == nil else { return }
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
    guard !isRefreshing,
          !isRecovering,
          !isLoading,
          !isRunningSessionMaintenance,
          pendingVolumeTargets.isEmpty else {
      return
    }

    isRunningSessionMaintenance = true
    defer { isRunningSessionMaintenance = false }

    do {
      let rebuilt = try await backend.refresh()
      session = mergedSession(with: rebuilt, cached: session)
      invalidateVisibleAppsCache()
      cleanupStaleEntries()
      persistSessionSnapshot()
      diagnostics = await backend.diagnosticsReport()
      availableDevices = await backend.availableOutputDevices()
      syncOnboarding(using: session)
      checkAutoPauseMusic()
    } catch {
      logger.debug("Silent session refresh failed: \(error.localizedDescription)")
    }
  }

  func handleURLScheme(_ url: URL) {
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

  func setDesiredVolume(_ value: Float, for app: AudioApp) {
    guard !isExcluded(app) else { return }
    let appKey = app.logicalID
    guard let index = session.apps.firstIndex(matchingAppKey: appKey) else {
      let message = BackendError.appNotFound(app.id).localizedDescription
      showToast(title: "Volume change blocked", detail: message, kind: .warning)
      return
    }

    let clampedValue = max(0.0, min(1.0, value))
    session.apps[index].desiredVolume = clampedValue
    session.apps[index].appliedVolume = session.apps[index].isMuted ? 0 : clampedValue
    pendingVolumeTargets[appKey] = clampedValue
    invalidateVisibleAppsCache()

    if preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID {
      let currentApp = session.apps[index]
      let settings = AppVolumeSettings(
        desiredVolume: clampedValue,
        isMuted: currentApp.isMuted,
        volumeBoost: currentApp.volumeBoost
      )
      // Update the in-memory preset on every change, but defer the disk write
      // to commit so a slider drag doesn't encode and rewrite the file per tick.
      deviceVolumePresets.saveVolumeSettings(for: appKey, deviceID: deviceID, settings: settings)
    }
  }

  func commitDesiredVolume(for app: AudioApp) {
    // Mirror the early-return in setDesiredVolume: an excluded app must never be
    // re-tapped. Without this guard, pendingVolumeTargets[appKey]==nil falls
    // through to scheduleVolumeApply -> backend.setDesiredVolume, re-engaging a
    // managed tap and firing a false "Managed route active" success toast.
    guard !isExcluded(app) else { return }
    let appKey = app.logicalID
    if pendingVolumeTargets[appKey] == nil {
      pendingVolumeTargets[appKey] = app.desiredVolume
    }
    if preferences.enablePerDeviceVolumePresets {
      deviceVolumePresetsStore.save(deviceVolumePresets)
    }
    scheduleVolumeApply(forAppID: appKey, immediate: true)
  }

  private func scheduleVolumeApply(forAppID appID: String, immediate: Bool) {
    pendingVolumeApplyTasks[appID]?.cancel()

    // Clean up completed tasks if we're approaching the limit
    if pendingVolumeApplyTasks.count >= maxPendingTasks {
      cleanupCompletedTasks()
    }

    // Tag this scheduling so a superseded (cancelled) task cannot clear the
    // bookkeeping or newer target that now belongs to its replacement.
    let token = (volumeApplyToken[appID] ?? 0) &+ 1
    volumeApplyToken[appID] = token

    pendingVolumeApplyTasks[appID] = Task { @MainActor [weak self] in
      guard let self else { return }

      let finishIfCurrent: @MainActor () -> Void = {
        guard self.volumeApplyToken[appID] == token else { return }
        self.pendingVolumeTargets.removeValue(forKey: appID)
        self.pendingVolumeApplyTasks.removeValue(forKey: appID)
      }

      do {
        if !immediate {
          try await Task.sleep(for: volumeApplyDelay)
        }

        guard let target = self.pendingVolumeTargets[appID], !Task.isCancelled else {
          return
        }

        try await self.ensureBackendHasApp(appID)
        try await self.backend.setDesiredVolume(target, forAppID: appID)
        let backendSession = await self.backend.currentSnapshot()
        self.mergeAppStateAndSyncOnboarding(from: backendSession, appID: appID)
        self.diagnostics = await self.backend.diagnosticsReport()
        self.persistSessionSnapshot()
        let mergedApp = self.session.apps.first(matchingAppKey: appID)
        // Only claim "Managed route active" when the post-merge state is actually
        // .managed. On macOS <14.2 the backend setter succeeds monitor-only (no
        // route built) and returns without throwing, so the row is .monitorOnly —
        // a "Managed route active" toast there is factually wrong. Stay silent
        // for the monitor-only outcome (the row chip already reflects it).
        if mergedApp?.routingState == .managed {
          let appName = mergedApp?.displayName ?? "App"
          showToast(
            title: "Managed route active",
            detail: "\(appName) set to \(Int(target * 100))%",
            kind: .success,
            duration: .seconds(1.2)
          )
        }
        finishIfCurrent()
      } catch is CancellationError {
        // A newer task now owns this app's bookkeeping; leave it intact.
        return
      } catch {
        finishIfCurrent()
        let message = error.localizedDescription
        self.showToast(
          title: "Volume change failed",
          detail: message,
          kind: .error
        )

        // Use currentSnapshot()+mergeAppState (mirroring setMuted/setVolumeBoost)
        // instead of a full refresh(): refresh's buildSnapshot merge would reset
        // this no-controller app back to .monitorOnly/notes=nil, wiping the
        // .error chip + reason the backend just set. mergeAppState copies the
        // single backend app verbatim, preserving the persistent Error chip.
        let backendSession = await self.backend.currentSnapshot()
        self.mergeAppState(from: backendSession, appID: appID)
        self.diagnostics = await self.backend.diagnosticsReport()
        self.persistSessionSnapshot()
      }
    }
  }

  private func cleanupCompletedTasks() {
    let completedTasks = pendingVolumeApplyTasks.filter { _, task in task.isCancelled }
    for appID in completedTasks.keys {
      pendingVolumeApplyTasks.removeValue(forKey: appID)
      pendingVolumeTargets.removeValue(forKey: appID)
    }
  }

  private func cleanupStaleEntries() {
    let currentAppIDs = Set(session.apps.map { $0.logicalID })

    // Remove pending volume targets for apps no longer in session
    pendingVolumeTargets = pendingVolumeTargets.filter { currentAppIDs.contains($0.key) }

    // Remove paused music apps no longer in session
    pausedMusicApps = pausedMusicApps.filter { currentAppIDs.contains($0) }
  }

  private func ensureBackendHasApp(_ appID: String) async throws {
    let currentBackendSession = await backend.currentSnapshot()
    if currentBackendSession.apps.contains(where: { $0.id == appID || $0.logicalID == appID }) {
      return
    }

    _ = try await backend.refresh()
  }

  func setMuted(_ isMuted: Bool, for app: AudioApp) {
    guard !isExcluded(app) else { return }
    let appName = app.displayName
    let appKey = app.logicalID

    let liveIndex = session.apps.firstIndex(matchingAppKey: appKey)
    if let index = liveIndex {
      session.apps[index].isMuted = isMuted
      session.apps[index].appliedVolume = isMuted ? 0 : session.apps[index].desiredVolume
      // A direct user mute/unmute is always user-sourced, so auto-resume won't
      // later override it.
      session.apps[index].muteSource = .user
      invalidateVisibleAppsCache()
    }
    // If the user unmutes an app Waves auto-paused, forget it so auto-resume
    // doesn't double-act.
    if !isMuted { pausedMusicApps.remove(appKey) }

    // Build the per-device preset from the freshly mutated live row (mirroring
    // setDesiredVolume) so unchanged fields aren't captured from a stale `app`
    // snapshot that the caller's binding may have grabbed one edit behind.
    if preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID, let index = liveIndex {
      let currentApp = session.apps[index]
      let settings = AppVolumeSettings(
        desiredVolume: currentApp.desiredVolume,
        isMuted: currentApp.isMuted,
        volumeBoost: currentApp.volumeBoost
      )
      deviceVolumePresets.saveVolumeSettings(for: appKey, deviceID: deviceID, settings: settings)
      // Save asynchronously to avoid blocking UI thread
      Task {
        deviceVolumePresetsStore.save(deviceVolumePresets)
      }
    }

    Task {
      do {
        try await backend.setMuted(isMuted, forAppID: app.logicalID)
        let backendSession = await backend.currentSnapshot()
        mergeAppStateAndSyncOnboarding(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        // Same gate as the volume apply path: on macOS <14.2 setMuted succeeds
        // monitor-only (no route exists), so a "muted/unmuted" success toast would
        // overstate what happened. Only confirm when the post-merge row is
        // .managed; stay silent for the monitor-only outcome.
        if session.apps.first(matchingAppKey: appKey)?.routingState == .managed {
          showToast(
            title: isMuted ? "App muted" : "App unmuted",
            detail: appName,
            kind: .success,
            duration: .seconds(1.1)
          )
        }
      } catch {
        let backendSession = await backend.currentSnapshot()
        mergeAppState(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(title: "Mute toggle failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func setVolumeBoost(_ boost: Float, for app: AudioApp) {
    guard !isExcluded(app) else { return }
    let appName = app.displayName
    let appKey = app.logicalID
    let clampedBoost = max(1.0, min(4.0, boost))

    let liveIndex = session.apps.firstIndex(matchingAppKey: appKey)
    if let index = liveIndex {
      session.apps[index].volumeBoost = clampedBoost
      invalidateVisibleAppsCache()
    }

    // Build the per-device preset from the freshly mutated live row (mirroring
    // setDesiredVolume) so unchanged fields aren't captured from a stale `app`
    // snapshot that the caller's binding may have grabbed one edit behind.
    if preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID, let index = liveIndex {
      let currentApp = session.apps[index]
      let settings = AppVolumeSettings(
        desiredVolume: currentApp.desiredVolume,
        isMuted: currentApp.isMuted,
        volumeBoost: currentApp.volumeBoost
      )
      deviceVolumePresets.saveVolumeSettings(for: appKey, deviceID: deviceID, settings: settings)
      Task {
        deviceVolumePresetsStore.save(deviceVolumePresets)
      }
    }

    Task {
      do {
        try await backend.setVolumeBoost(clampedBoost, forAppID: appKey)
        let backendSession = await backend.currentSnapshot()
        mergeAppStateAndSyncOnboarding(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        // Only confirm success when a managed route actually carries the boost.
        // On an unsupported OS the app stays monitor-only and the boost cannot
        // affect audio, so suppress the misleading toast (mirrors volume/mute).
        if let idx = session.apps.firstIndex(matchingAppKey: appKey),
          session.apps[idx].routingState == .managed {
          showToast(
            title: "Boost updated",
            detail: "\(appName): \(Int(clampedBoost))x",
            kind: .success,
            duration: .seconds(1.1)
          )
        }
      } catch {
        let backendSession = await backend.currentSnapshot()
        mergeAppState(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(title: "Boost update failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  // MARK: - Per-app equalizer and adaptive mixing

  func equalizerSettings(for app: AudioApp) -> EqualizerSettings {
    preferences.appEqualizerSettings[app.logicalID] ?? EqualizerSettings()
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
    guard !isExcluded(app) else { return }
    var settings = equalizerSettings(for: app)
    mutation(&settings)
    preferences.appEqualizerSettings[app.logicalID] = settings
    persistPreferences()
    scheduleEqualizerApply(settings, for: app)
  }

  private func scheduleEqualizerApply(_ settings: EqualizerSettings, for app: AudioApp) {
    let appID = app.logicalID
    let appName = app.displayName
    pendingEqualizerApplyTasks[appID]?.cancel()
    pendingEqualizerApplyTasks[appID] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(80))
      guard let self, !Task.isCancelled else { return }
      defer { self.pendingEqualizerApplyTasks.removeValue(forKey: appID) }

      do {
        try await self.backend.setEqualizer(settings, forAppID: appID)
        let backendSession = await self.backend.currentSnapshot()
        self.mergeAppStateAndSyncOnboarding(from: backendSession, appID: appID)
        self.persistSessionSnapshot()
      } catch {
        let backendSession = await self.backend.currentSnapshot()
        self.mergeAppStateAndSyncOnboarding(from: backendSession, appID: appID)
        self.persistSessionSnapshot()
        let routingState = self.session.apps.first(matchingAppKey: appID)?.routingState
        if routingState == .monitorOnly {
          self.showToast(
            title: "EQ saved, not active",
            detail: "Start playback in \(appName), then try again.",
            kind: .info,
            duration: .seconds(2.0)
          )
        } else {
          self.showToast(title: "EQ not active", detail: error.localizedDescription, kind: .error)
        }
      }
    }
  }

  private func restartAdaptiveMixing() {
    adaptiveMixTask?.cancel()
    adaptiveMixTask = nil

    guard preferences.adaptiveMixMode != .off else {
      speechDetectionStates.removeAll()
      speechDuckingStates.removeAll()
      loudnessTrimStates.removeAll()
      Task { await backend.setAdaptiveGains([:]) }
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

    guard !Task.isCancelled, preferences.adaptiveMixMode == mode else { return }
    await backend.setAdaptiveGains(gainsDB)
  }

  func togglePinned(_ app: AudioApp) {
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
    Task {
      try? await backend.pinApp(willPin, appID: appKey)
      persistSessionSnapshot()
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
    liveLevelsRefcount += 1
    guard levelPollTask == nil else { return }
    levelPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(300))
        guard let self, !Task.isCancelled else { return }
        let levels = await self.backend.audioLevels()
        // Re-check after the await (the poll may have been cancelled while
        // suspended). Skip the no-op level assignment to avoid needless redraws,
        // but always reconcile the lingering-live set so a just-silenced app is
        // scheduled to drop out — and a returning one is kept — every tick.
        guard !Task.isCancelled else { return }
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
  /// default. Persists the choice and rebuilds the route if the app is managed.
  func setOutputDevice(_ device: AudioDevice?, for app: AudioApp) {
    guard !isExcluded(app) else { return }
    let appKey = app.logicalID
    if let index = session.apps.firstIndex(matchingAppKey: appKey) {
      session.apps[index].targetDeviceUID = device?.id
      invalidateVisibleAppsCache()
    }
    Task {
      do {
        try await backend.setOutputDevice(uid: device?.id, forAppID: appKey)
        let backendSession = await backend.currentSnapshot()
        mergeAppState(from: backendSession, appID: appKey)
        persistSessionSnapshot()
        // For a monitor-only app the backend records the target device but builds
        // no route, so audio keeps playing to the system default until the app is
        // later enrolled. Don't claim "Output set" in that case — show an
        // informational toast that the choice is saved for when it engages.
        let routedNow = session.apps.first(matchingAppKey: appKey)?.routingState
        if routedNow == .monitorOnly {
          showToast(
            title: "Output saved",
            detail: "\(app.displayName) → \(device?.name ?? "System default"), applies when adjusted",
            kind: .info,
            duration: .seconds(1.8)
          )
        } else {
          showToast(
            title: "Output set",
            detail: "\(app.displayName) → \(device?.name ?? "System default")",
            kind: .success,
            duration: .seconds(1.4)
          )
        }
      } catch {
        let backendSession = await backend.currentSnapshot()
        mergeAppState(from: backendSession, appID: appKey)
        showToast(title: "Couldn't route \(app.displayName)", detail: error.localizedDescription, kind: .error)
      }
    }
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
    var ids = Set(preferences.excludedAppIDs)
    if excluded {
      ids.insert(app.logicalID)
    } else {
      ids.remove(app.logicalID)
    }
    preferences.excludedAppIDs = Array(ids).sorted()
    persistPreferences()

    if excluded {
      // Tear down any active route so Waves stops touching this app's audio.
      // Once untapped, the app plays at its own (unmuted) level again, so the
      // row should no longer show Waves-applied mute/volume state.
      let bundleID = app.bundleID
      let pid = app.pid ?? -1
      // Exclusion: clear the backend's mute state too, so a later whole-session
      // rebuild doesn't resurrect a mute the user dropped by excluding the app.
      Task { await backend.releaseControllers(forBundleID: bundleID, pid: pid, clearMuteState: true) }
      if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
        session.apps[index].routingState = .monitorOnly
        session.apps[index].appliedVolume = nil
        session.apps[index].isMuted = false
        session.apps[index].muteSource = .user
      }
      pendingVolumeApplyTasks[app.logicalID]?.cancel()
      pendingVolumeTargets.removeValue(forKey: app.logicalID)
      pendingEqualizerApplyTasks[app.logicalID]?.cancel()
      pendingEqualizerApplyTasks.removeValue(forKey: app.logicalID)
      speechDetectionStates.removeValue(forKey: app.logicalID)
      speechDuckingStates.removeValue(forKey: app.logicalID)
      loudnessTrimStates.removeValue(forKey: app.logicalID)
      pausedMusicApps.remove(app.logicalID)
    }
    invalidateVisibleAppsCache()
    if showToast {
      self.showToast(
        title: excluded ? "Excluded from Waves" : "Managed by Waves",
        detail: app.displayName,
        kind: .info,
        duration: .seconds(1.4)
      )
    }
  }

  /// Excludes every app in `apps` that does not expose a manageable audio stream
  /// (see `AudioApp.hasNoAudioCapability`) in one action, instead of requiring
  /// a right-click per row. Scoped to the apps passed in (the caller's current
  /// visible list) rather than the whole session.
  func excludeUnroutableApps(_ apps: [AudioApp]) {
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

  /// Capture-permission label for the diagnostics header, drawn from the same
  /// "Audio capture permission" check the Checks section prints so the two never
  /// contradict (the old `hasRequiredPermissions` boolean collapsed
  /// undetermined/unsupported to a flat "not granted"). Falls back to the
  /// boolean only when diagnostics haven't been loaded yet.
  private var capturePermissionSummary: String {
    guard let check = diagnostics?.checks.first(where: { $0.title == "Audio capture permission" }) else {
      return session.backendStatus.hasRequiredPermissions ? "granted" : "not granted"
    }
    switch check.status {
    case .passed:
      return "granted"
    case .failed:
      return "not granted"
    case .warning, .informational:
      // .warning covers both "not yet known" and "needs macOS 14.2"; defer to
      // the Checks section's nuanced detail rather than asserting either here.
      return "see Checks below"
    }
  }

  /// A plain-text snapshot of route health and per-app state, suitable for
  /// pasting into a bug report. Contains no audio and no sensitive content
  /// beyond app names already visible in the mixer.
  var diagnosticsExportText: String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let status = session.backendStatus
    var lines: [String] = []
    lines.append("Waves diagnostics")
    lines.append("macOS: \(os)")
    lines.append("Output device: \(currentDeviceName)")
    lines.append("Audio component installed: \(status.isAudioComponentInstalled)")
    lines.append("Audio capture permission: \(capturePermissionSummary)")
    lines.append("Route recovery healthy: \(status.isRouteRecoveryHealthy)")
    if let error = status.lastError { lines.append("Last error: \(error)") }
    lines.append("")
    lines.append("Apps (\(visibleApps.count)):")
    for app in visibleApps {
      let muted = app.isMuted ? ", muted" : ""
      // Use %g so a fractional boost (e.g. 2.5x, reachable via imported presets)
      // isn't truncated to "2x" by Int().
      let boost = app.volumeBoost > 1 ? ", boost \(String(format: "%g", app.volumeBoost))x" : ""
      lines.append("  • \(app.displayName) — \(app.routingState.displayName), \(Int(app.desiredVolume * 100))%\(muted)\(boost)")
    }
    if let diagnostics {
      lines.append("")
      lines.append("Checks:")
      for check in diagnostics.checks {
        lines.append("  • [\(check.status.rawValue)] \(check.title): \(check.detail)")
      }
    }
    return lines.joined(separator: "\n")
  }

  func refreshOutputDevices() {
    Task {
      availableDevices = await backend.availableOutputDevices()
    }
  }

  func selectOutputDevice(_ device: AudioDevice) {
    guard device.id != currentDeviceID else { return }
    // Mark this switch as self-initiated so the device-change listener's
    // handleDeviceChange skips its duplicate "Output device changed" info toast.
    pendingSelfInitiatedDeviceID = device.id
    Task {
      do {
        try await backend.setDefaultOutputDevice(uid: device.id)
        // The device-change event refreshes the session; refresh the list so
        // the current-device checkmark updates immediately.
        availableDevices = await backend.availableOutputDevices()
        showToast(title: "Output switched", detail: device.name, kind: .success, duration: .seconds(1.4))
      } catch {
        // The switch never happened, so no device-change event will consume the
        // flag. Left set, it would suppress the "Output device changed" toast
        // for a later *external* auto-switch to this same device.
        pendingSelfInitiatedDeviceID = nil
        showToast(title: "Couldn't switch output", detail: error.localizedDescription, kind: .error)
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
    Task {
      defer { isHandlingDeviceChange = false }
      repeat {
        // Clear the pending flag before each pass; any event arriving during this
        // pass re-sets it and earns exactly one more iteration.
        pendingDeviceChangeRerun = false
        await performDeviceChangePass()
      } while pendingDeviceChangeRerun
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
      session = mergedSession(with: await backend.currentSnapshot(), cached: session)
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

  private func reapplyRestoredAudioState() async {
    // After a relaunch the merged session shows the user's saved volumes, mutes,
    // and boosts, but the freshly started backend has not applied them yet.
    // Re-apply the customized apps so audible output matches the restored UI.
    // Collect the IDs of pinned apps whose route re-establishment failed; merge
    // the backend's resulting .error state for them AFTER the loop, from a
    // single post-loop snapshot fetch.
    // An auto-pause (.autoConferencing) mute is a transient, call-time state, not
    // durable user intent. Persisting and re-applying it on relaunch audibly
    // re-mutes media hours after a call, and with the auto-pause toggle off it
    // never auto-resumes (checkAutoPauseMusic bails), leaving it stuck. Treat
    // these as session-only: clear them here BEFORE reapply so the restored row
    // is un-muted, then checkAutoPauseMusic() (called by start() after this) will
    // re-pause only if a conferencing app is genuinely frontmost right now and
    // the toggle is on.
    for index in session.apps.indices where session.apps[index].muteSource == .autoConferencing {
      if session.apps[index].isMuted {
        session.apps[index].isMuted = false
        session.apps[index].appliedVolume = session.apps[index].desiredVolume
      }
      session.apps[index].muteSource = .user
    }
    pausedMusicApps.removeAll()

    var failedPinnedAppIDs: [String] = []
    // Iterate a value snapshot, never a live index: the backend awaits below
    // suspend the actor, and a concurrent session reassignment (silent refresh,
    // device change, profile apply) can shrink session.apps mid-loop — a
    // pre-await index would then trap. Writes re-resolve the row by logicalID.
    for app in session.apps {
      guard !isExcluded(app) else { continue }
      let equalizer = equalizerSettings(for: app)
      // A pinned output device is also "customized" — re-establish its route so
      // it plays to the chosen device immediately, even at default volume.
      let isCustomized = app.isMuted || app.volumeBoost > 1.0
        || abs(app.desiredVolume - 1.0) > 0.001 || app.targetDeviceUID != nil
        || equalizer.isEnabled || equalizer.adaptiveRole != .auto
      guard isCustomized else { continue }
      // Only a pinned route can surface as a user-visible .error chip; a plain
      // volume/mute re-apply that fails just means the app isn't running.
      let isPinnedRoute = app.targetDeviceUID != nil
      do {
        // Re-establish a saved per-app output route in the audio engine. The
        // freshly started backend carries targetDeviceUID==nil for every app, so
        // without this the app routes to the system default while the UI claims
        // it is pinned/Managed. Set the device before the volume/mute re-apply.
        if let targetDeviceUID = app.targetDeviceUID {
          try await backend.setOutputDevice(uid: targetDeviceUID, forAppID: app.logicalID)
        }
        try await backend.setEqualizer(equalizer, forAppID: app.logicalID)
        try await backend.setVolumeBoost(app.volumeBoost, forAppID: app.logicalID)
        try await backend.setMuted(app.isMuted, forAppID: app.logicalID)
        try await backend.setDesiredVolume(app.desiredVolume, forAppID: app.logicalID)
        if let liveIndex = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[liveIndex].appliedVolume = app.isMuted ? 0 : app.desiredVolume
          session.apps[liveIndex].routingState = .managed
        }
      } catch {
        logger.debug("Skipped restoring audio state for \(app.displayName): \(error.localizedDescription)")
        // Re-pinning a saved route failed (saved device gone, or the backend
        // threw managedRouteUnavailable). Plain volume/mute failures (app not
        // running) are left untouched as before.
        if isPinnedRoute {
          failedPinnedAppIDs.append(app.logicalID)
        }
      }
    }

    // The backend set its own snapshot entry to .error inside each failing call;
    // merge that state back so the store reflects the real failure (a visible
    // .error chip with the actionable note) instead of keeping the stale
    // restored .managed state.
    if !failedPinnedAppIDs.isEmpty {
      let backendSession = await backend.currentSnapshot()
      for appID in failedPinnedAppIDs {
        mergeAppState(from: backendSession, appID: appID)
      }
    }

    invalidateVisibleAppsCache()
    // Surface a single aggregated toast so a relaunch re-pin failure is
    // discoverable rather than silent.
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

  /// Re-apply saved per-device volume presets for the given device.
  ///
  /// `limitedTo`, when supplied, restricts restoration to apps whose logicalID
  /// passes the predicate — used by `refresh()` to apply presets only to apps
  /// that launched since the device switch, without re-disturbing apps the user
  /// may have tweaked in the meantime.
  private func restoreDeviceVolumePresets(
    for deviceID: String,
    limitedTo shouldRestore: ((String) -> Bool)? = nil
  ) async {
    var failedRestoreIDs: [String] = []
    // Iterate a value snapshot, never a live index: the backend awaits below
    // suspend the actor, and a concurrent session reassignment (silent refresh,
    // device change, profile apply) can shrink session.apps mid-loop — a
    // pre-await index would then trap. Each row is re-resolved by logicalID.
    for app in session.apps {
      // Never re-tap an excluded app, even if it has saved per-device presets
      // from before it was excluded (mirrors reapplyRestoredAudioState).
      guard !isExcluded(app) else { continue }
      if let shouldRestore, !shouldRestore(app.logicalID) { continue }
      if let settings = deviceVolumePresets.getVolumeSettings(for: app.logicalID, deviceID: deviceID) {
        // Skip rows that vanished while an earlier iteration was suspended.
        guard let index = session.apps.firstIndex(matchingAppKey: app.logicalID) else { continue }
        session.apps[index].desiredVolume = settings.desiredVolume
        session.apps[index].isMuted = settings.isMuted
        session.apps[index].volumeBoost = settings.volumeBoost
        // Optimistically keep the visible row consistent with the re-applied
        // state (matching reapplyRestoredAudioState). If the backend re-tap
        // below fails, the post-loop reconciliation re-merges the backend's
        // real state so a failed/monitor-only app never renders a false .managed.
        session.apps[index].appliedVolume = settings.isMuted ? 0 : settings.desiredVolume
        session.apps[index].routingState = .managed

        do {
          try await backend.setDesiredVolume(settings.desiredVolume, forAppID: app.logicalID)
          try await backend.setMuted(settings.isMuted, forAppID: app.logicalID)
          try await backend.setVolumeBoost(settings.volumeBoost, forAppID: app.logicalID)
        } catch {
          logger.error("Failed to restore volume preset for \(app.displayName): \(error)")
          failedRestoreIDs.append(app.logicalID)
        }
      }
    }
    // Surface the backend's true state (monitor-only / error) for any app whose
    // re-tap failed, so the optimistic .managed above is corrected rather than
    // left lying. Done by app id after the loop to stay index-safe.
    if !failedRestoreIDs.isEmpty {
      let snapshot = await backend.currentSnapshot()
      for id in failedRestoreIDs {
        mergeAppState(from: snapshot, appID: id)
      }
    }
    invalidateVisibleAppsCache()
    persistSessionSnapshot()
  }

  func shutdown() {
    deviceChangeObserver?.cancel()
    deviceChangeObserver = nil
    sessionMaintenanceTask?.cancel()
    sessionMaintenanceTask = nil
    adaptiveMixTask?.cancel()
    adaptiveMixTask = nil
    levelPollTask?.cancel()
    levelPollTask = nil
    for task in pendingEqualizerApplyTasks.values { task.cancel() }
    pendingEqualizerApplyTasks.removeAll()
    for task in lingerRemovalTasks.values { task.cancel() }
    lingerRemovalTasks.removeAll()
    if let frontmostAppObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
      self.frontmostAppObserver = nil
    }
    if let appTerminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
      self.appTerminationObserver = nil
    }
    // Drain the stores' serial write queues before the process exits, so a
    // change made in the same instant as ⌘Q/logout still lands on disk.
    preferencesStore.flush()
    profileStore.flush()
    sessionStore.flush()
    deviceVolumePresetsStore.flush()
    let backend = backend
    Task {
      await backend.setAdaptiveGains([:])
      await backend.stop()
    }
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
    // Release the quit app's tap/aggregate device promptly instead of waiting
    // for the next refresh. Termination must NOT clear the user's saved mute.
    Task { await backend.releaseControllers(forBundleID: bundleID, pid: pid, clearMuteState: false) }

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
      pendingEqualizerApplyTasks[id]?.cancel()
      pendingEqualizerApplyTasks.removeValue(forKey: id)
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
    preferences.autoRestoreDevice = enabled
    persistPreferences()
  }

  /// Updates how long a just-quiet app stays in Live. Existing pending removals
  /// are rebuilt with the new timing so the control takes effect immediately.
  func setLiveListLinger(_ linger: LiveListLinger) {
    guard preferences.liveListLinger != linger else { return }
    preferences.liveListLinger = linger
    persistPreferences()
    for task in lingerRemovalTasks.values { task.cancel() }
    lingerRemovalTasks.removeAll()
    refreshLiveLinger()
  }

  func checkAutoPauseMusic() {
    // Coalesce overlapping passes (mirroring handleDeviceChange) so two never
    // run at once. Frontmost detection happens inside each pass, so the
    // coalesced rerun reads the *then-current* frontmost app — the latest app
    // switch always wins and none are dropped.
    guard !isRunningAutoPausePass else {
      pendingAutoPausePassRerun = true
      return
    }
    isRunningAutoPausePass = true
    Task {
      defer { isRunningAutoPausePass = false }
      repeat {
        // Clear the pending flag before each pass; any call arriving during
        // this pass re-sets it and earns exactly one more iteration.
        pendingAutoPausePassRerun = false
        await performAutoPausePass()
      } while pendingAutoPausePassRerun
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

    var muteChanges: [String: (muted: Bool, source: MuteSource)] = [:]
    // Track names of apps actually paused/resumed so an automatic, otherwise
    // invisible mutation surfaces a confirmation toast (a silently muted row is
    // indistinguishable from an unexpected mute / bug).
    var pausedNames: [String] = []
    var resumedNames: [String] = []
    if isConferencingAppActive {
      // Pause currently-unmuted music apps and tag the mute as automatic.
      let musicApps = visibleApps.filter { $0.category == .media && !$0.isMuted && !isExcluded($0) }
      for app in musicApps {
        do {
          try await backend.setMuted(true, forAppID: app.logicalID)
          pausedMusicApps.insert(app.logicalID)
          muteChanges[app.logicalID] = (true, .autoConferencing)
          pausedNames.append(app.displayName)
          logger.info("Auto-paused music app: \(app.displayName)")
        } catch {
          logger.error("Failed to pause music app \(app.displayName): \(error)")
        }
      }
    } else {
      // Resume ONLY apps Waves auto-paused that the user hasn't since touched
      // (muteSource still .autoConferencing). Never override a user's mute.
      let resumable = visibleApps.filter { $0.isMuted && $0.muteSource == .autoConferencing && !isExcluded($0) }
      for app in resumable {
        do {
          try await backend.setMuted(false, forAppID: app.logicalID)
          muteChanges[app.logicalID] = (false, .user)
          resumedNames.append(app.displayName)
          logger.info("Auto-resumed music app: \(app.displayName)")
        } catch {
          logger.error("Failed to resume music app \(app.displayName): \(error)")
        }
      }
      pausedMusicApps.removeAll()
    }

    // Apply only the affected apps' mute state in place. Replacing the whole
    // session here would wipe state restored/merged during launch.
    guard !muteChanges.isEmpty else { return }
    for (appID, change) in muteChanges {
      if let index = session.apps.firstIndex(matchingAppKey: appID) {
        session.apps[index].isMuted = change.muted
        session.apps[index].muteSource = change.source
        session.apps[index].appliedVolume = change.muted ? 0 : session.apps[index].desiredVolume
      }
    }
    invalidateVisibleAppsCache()
    persistSessionSnapshot()

    // Tell the user Waves did this automatically — without this the silenced
    // app looks like a bug. Aggregate so N apps yield one toast.
    if !pausedNames.isEmpty {
      let detail = pausedNames.count == 1
        ? "\(pausedNames[0]) muted for your call."
        : "\(pausedNames.count) apps muted for your call."
      showToast(title: "Auto-paused media", detail: detail, kind: .info, duration: .seconds(2.4))
    } else if !resumedNames.isEmpty {
      let detail = resumedNames.count == 1
        ? "\(resumedNames[0]) resumed."
        : "\(resumedNames.count) apps resumed."
      showToast(title: "Resumed media", detail: detail, kind: .info, duration: .seconds(2.0))
    }
  }

  func applyProfile(_ profile: Profile) {
    // Never let a profile re-tap an excluded app — strip excluded entries first.
    var profile = profile
    let excluded = Set(preferences.excludedAppIDs)
    if !excluded.isEmpty {
      profile.entries = profile.entries.filter { !excluded.contains($0.appID) }
    }
    // A membership-only profile (a pure grouping) carries no levels to apply.
    // Switch the main window to that group instead of running an audio no-op,
    // so "switch to Work" still does something visible.
    guard profile.carriesLevels else {
      focusProfile(profile.id)
      showToast(
        title: "Profile selected",
        detail: "\(profile.name) — \(profile.entries.count) \(profile.entries.count == 1 ? "app" : "apps")",
        kind: .info,
        duration: .seconds(1.4)
      )
      return
    }
    Task {
      do {
        // A profile apply replaces route state wholesale, but an auto-paused
        // app must keep its .autoConferencing tag or it can never
        // auto-resume. `cached: session` is deliberately read inline — Swift
        // evaluates arguments left to right, so it picks up the session AFTER
        // the await resumes, including tags an auto-pause pass applied while
        // the apply was in flight. Only entries that explicitly set a mute
        // override the tag: the backend skips membership-only entries and
        // carries the existing mute forward for mute-less level entries, so
        // neither expresses user intent about the mute.
        session = preservingAutoPauseTags(
          in: try await backend.applyProfile(profile),
          cached: session,
          except: Set(profile.entries.filter { $0.isMuted != nil }.map(\.appID))
        )
        focusProfile(profile.id)
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        // Keep onboarding route health / checklist in step with the session this
        // profile just installed (mirrors the per-app mute/boost/volume paths).
        syncOnboarding(using: session)
        mirrorAppliedProfileIntoDevicePresets()
        persistSessionSnapshot()
        checkAutoPauseMusic()
        showToast(
          title: "Profile applied",
          detail: profile.name,
          kind: .success,
          duration: .seconds(1.4)
        )
      } catch {
        session = await backend.currentSnapshot()
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        // Re-sync onboarding on the failure path too (mirroring the success
        // path): a failed apply is exactly where route health most likely just
        // degraded, so routeHealthReady must track this session, not go stale.
        syncOnboarding(using: session)
        persistSessionSnapshot()
        showToast(title: "Profile apply failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  /// After a profile's levels land, mirror each app's resulting volume/mute/boost
  /// into the per-device volume store for the current device. Without this the
  /// per-device store keeps the pre-profile values and the next device switch
  /// (restoreDeviceVolumePresets) silently reverts the just-applied profile.
  private func mirrorAppliedProfileIntoDevicePresets() {
    guard preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID else { return }
    for app in session.apps {
      // Never record per-device entries for excluded apps — mirrors the
      // exclusion guard in setDesiredVolume/setMuted/setVolumeBoost and
      // restoreDeviceVolumePresets, so an excluded app accrues no stale entry
      // that would otherwise grow the store for an app Waves must not touch.
      guard !isExcluded(app) else { continue }
      let settings = AppVolumeSettings(
        desiredVolume: app.desiredVolume,
        isMuted: app.isMuted,
        volumeBoost: app.volumeBoost
      )
      deviceVolumePresets.saveVolumeSettings(for: app.logicalID, deviceID: deviceID, settings: settings)
    }
    deviceVolumePresetsStore.save(deviceVolumePresets)
  }

  /// Discards every saved per-device volume/mute/boost preset — the escape
  /// hatch for Settings > Audio's "Clear All Saved Levels", for a user who
  /// wants to start over rather than have Waves keep re-applying old levels
  /// per device. Does not touch the `enablePerDeviceVolumePresets` preference
  /// itself, only the accumulated data.
  func clearDeviceVolumePresets() {
    deviceVolumePresets = DeviceVolumePresets()
    deviceVolumePresetsStore.save(deviceVolumePresets)
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
    profileStore.save(profiles)
    showToast(
      title: "Profile saved",
      detail: trimmedName,
      kind: .success,
      duration: .seconds(1.6)
    )
  }

  func deleteProfiles(at offsets: IndexSet) {
    let removedIDs = offsets.map { profiles[$0].id }
    profiles.remove(atOffsets: offsets)
    if let active = activeProfileID, removedIDs.contains(active) {
      activeProfileID = nil
    }
    profileStore.save(profiles)
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
    Task {
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
    Task {
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
          profileStore.save(profiles)
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
    // Mirror refresh()'s in-flight guard: the toolbar/Settings/Onboarding
    // "Recover managed routes" buttons call this directly, so rapid clicks would
    // otherwise stack overlapping recovery tasks that each reassign session and
    // re-query diagnostics.
    guard !isRecovering else { return }

    isRecovering = true
    Task {
      defer { isRecovering = false }
      do {
        // Route recovery reattaches taps; it expresses no new intent about
        // mutes, so auto-paused apps keep their .autoConferencing tags.
        // `cached: session` is read inline (after the await resumes, per
        // left-to-right argument evaluation) so tags applied while recovery
        // was in flight survive too.
        session = preservingAutoPauseTags(in: try await backend.recoverRoutes(), cached: session)
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
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
        session = await backend.currentSnapshot()
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(title: "Recovery failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func refreshDiagnostics() {
    Task {
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
      diagnostics = await backend.diagnosticsReport()
      // A diagnostics surface (Settings/Onboarding) can appear while a mixer
      // slider drag is still debouncing, so the snapshot's per-app values are the
      // backend's not-yet-applied ones. Wholesale-reassigning `session` there would
      // snap the optimistic slider back. When edits are in flight, merge only the
      // snapshot-level health fields the diagnostics/checklist surfaces actually
      // read and leave the live `session.apps` untouched.
      if pendingVolumeTargets.isEmpty {
        session = snapshot
      } else {
        session.currentDevice = snapshot.currentDevice
        session.recentDeviceIDs = snapshot.recentDeviceIDs
        session.supportMatrix = snapshot.supportMatrix
        session.backendStatus = snapshot.backendStatus
        session.updatedAt = snapshot.updatedAt
      }
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
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = frontmostManagedApp()
    guard let app = frontmostApp else { return }
    // Don't act on (or show a success toast for) an excluded app.
    guard !isExcluded(app) else { return }

    // Validate step parameter bounds
    let clampedStep = max(0.01, min(step, 0.5))
    let newVolume = min(app.desiredVolume + clampedStep, 1.0)
    setDesiredVolume(newVolume, for: app)
    // The async apply path (scheduleVolumeApply) shows the single confirmation
    // toast ("Managed route active") on success and the error toast on failure,
    // so the handler does not emit its own toast to avoid stacking two.
    commitDesiredVolume(for: app)
  }

  func decreaseVolumeForFrontmostApp(step: Float = 0.1) {
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
    preferencesStore.save(preferences)
    invalidateVisibleAppsCache()
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
    onboarding.audioComponentInstalled = snapshot.backendStatus.isAudioComponentInstalled
    onboarding.permissionsGranted = snapshot.backendStatus.hasRequiredPermissions
    onboarding.accessibilityPermissionGranted = AXIsProcessTrusted()
    onboarding.outputDeviceVisible = snapshot.currentDevice != nil
    onboarding.routeHealthReady = snapshot.backendStatus.isRouteRecoveryHealthy
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

  /// Re-tags apps that were auto-paused before a wholesale snapshot
  /// replacement and are still muted in the new snapshot, so the auto-resume
  /// pass can still find them. Unlike `mergedSession` this deliberately
  /// preserves ONLY the tag: the new snapshot's volumes and mutes are
  /// authoritative (a profile apply or route recovery just installed them) —
  /// we only must not forget *why* an already-muted app is muted. Apps in
  /// `excludedIDs` (apps whose just-applied profile entry explicitly set a
  /// mute) keep the new snapshot's `.user` attribution, since an explicit
  /// profile mute overrides the auto-pause claim on that app.
  private func preservingAutoPauseTags(
    in liveSession: AudioSessionSnapshot,
    cached: AudioSessionSnapshot,
    except excludedIDs: Set<String> = []
  ) -> AudioSessionSnapshot {
    var result = liveSession
    for index in result.apps.indices {
      let id = result.apps[index].logicalID
      guard !excludedIDs.contains(id),
            result.apps[index].isMuted,
            let cachedApp = cached.apps.first(where: { $0.logicalID == id }),
            cachedApp.muteSource == .autoConferencing
      else { continue }
      result.apps[index].muteSource = .autoConferencing
    }
    return result
  }

  private func mergedSession(with liveSession: AudioSessionSnapshot, cached: AudioSessionSnapshot) -> AudioSessionSnapshot {
    guard !cached.apps.isEmpty else { return liveSession }

    let cachedByLogicalID = cached.apps.reduce(into: [String: AudioApp]()) { result, app in
      result[app.logicalID] = app
    }

    var mergedApps = liveSession.apps
    for index in mergedApps.indices {
      let app = mergedApps[index]
      guard let cachedApp = cachedByLogicalID[app.logicalID] else {
        continue
      }

      mergedApps[index].desiredVolume = cachedApp.desiredVolume
      mergedApps[index].appliedVolume = cachedApp.appliedVolume ?? app.appliedVolume
      mergedApps[index].isMuted = cachedApp.isMuted
      mergedApps[index].isPinned = cachedApp.isPinned
      mergedApps[index].compatibility = cachedApp.compatibility
      mergedApps[index].volumeBoost = cachedApp.volumeBoost
      mergedApps[index].muteSource = cachedApp.muteSource
      mergedApps[index].targetDeviceUID = cachedApp.targetDeviceUID
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
    sessionStore.save(session)
  }

  private func showToast(
    title: String,
    detail: String? = nil,
    kind: AppToast.Kind,
    duration: Duration? = nil
  ) {
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
