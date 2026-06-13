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
}

@Observable
@MainActor
final class AppStore {
  var session: AudioSessionSnapshot
  var presets: [Preset]
  var onboarding = OnboardingState()
  var preferences: UserPreferences
  var diagnostics: DiagnosticsReport?
  var isRefreshing = false
  var isLoading = false
  var toasts: [AppToast] = []
  var deviceVolumePresets = DeviceVolumePresets()
  var availableDevices: [AudioDevice] = []

  private let backend: any AudioControlBackend
  private let preferencesStore: PreferencesStore
  private let presetStore: PresetStore
  private let sessionStore: SessionStore
  private let loginItemService: LoginItemService
  private let deviceVolumePresetsStore: DeviceVolumePresetsStore
  private let logger = Logger(subsystem: "com.waves.store", category: "AppStore")
  private var isBootstrapped = false
  private var pendingVolumeTargets: [String: Float] = [:]
  private var pendingVolumeApplyTasks: [String: Task<Void, Never>] = [:]
  private var volumeApplyToken: [String: Int] = [:]
  private let volumeApplyDelay = Duration.milliseconds(50) // Optimized from 80ms for better responsiveness
  private var toastDismissals: [UUID: Task<Void, Never>] = [:]
  private var deviceChangeObserver: Task<Void, Never>?
  private var frontmostAppObserver: NSObjectProtocol?
  private var appTerminationObserver: NSObjectProtocol?
  private let maxToasts = 3
  private let defaultToastDuration = Duration.seconds(2.0)
  private var cachedVisibleApps: [AudioApp] = []
  private var needsVisibleAppsCacheUpdate = true
  private var previousFrontmostApp: String?
  private var pausedMusicApps: Set<String> = []
  private let maxPendingTasks = 100
  private var urlSchemeRequestTimes: [Date] = []
  private let maxURLSchemeRequests = 10
  private let urlSchemeRequestWindow: TimeInterval = 60

  init(
    backend: any AudioControlBackend,
    preferencesStore: PreferencesStore,
    presetStore: PresetStore,
    sessionStore: SessionStore,
    loginItemService: LoginItemService,
    deviceVolumePresetsStore: DeviceVolumePresetsStore = DeviceVolumePresetsStore()
  ) {
    self.backend = backend
    self.preferencesStore = preferencesStore
    self.presetStore = presetStore
    self.sessionStore = sessionStore
    self.loginItemService = loginItemService
    self.deviceVolumePresetsStore = deviceVolumePresetsStore
    self.preferences = preferencesStore.load()
    self.presets = presetStore.load(defaults: Preset.defaults)
    self.session = sessionStore.load() ?? Self.emptySession
    self.deviceVolumePresets = deviceVolumePresetsStore.load()
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
    self.preferences.launchAtLoginEnabled = loginItemService.status.isEnabled
    self.onboarding = OnboardingState(
      launchAtLoginEnabled: loginItemService.status.isEnabled
    )
    persistPreferences()
    syncOnboarding(using: session)
  }

  var visibleApps: [AudioApp] {
    if needsVisibleAppsCacheUpdate {
      let filtered = session.apps
        .filter { preferences.showSystemProcesses || $0.category != .system }
      cachedVisibleApps = sortedApps(filtered)
      needsVisibleAppsCacheUpdate = false
    }
    return cachedVisibleApps
  }

  var pinnedApps: [AudioApp] {
    visibleApps.filter(\.isPinned)
  }

  var activeApps: [AudioApp] {
    visibleApps.filter(\.isActive)
  }

  var liveApps: [AudioApp] {
    visibleApps.filter { app in
      app.routingState == .live
        || (app.routingState == .managed && !app.isMuted && max(app.peakLevel, app.rmsLevel) > 0.001)
    }
  }

  var recentApps: [AudioApp] {
    guard preferences.showRecentApps else { return [] }
    let liveIDs = Set(liveApps.map(\.logicalID))
    return visibleApps.filter { !liveIDs.contains($0.logicalID) }
  }

  var currentDeviceID: String? {
    session.currentDevice?.id
  }

  private func invalidateVisibleAppsCache() {
    needsVisibleAppsCacheUpdate = true
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
    if !liveApps.isEmpty {
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
        preferences.launchAtLoginEnabled = status.isEnabled
        onboarding.launchAtLoginEnabled = status.isEnabled
        persistPreferences()
        if status.isEnabled != newValue {
          showToast(
            title: "Login item needs approval",
            detail: status.statusDescription,
            kind: .warning,
            duration: .seconds(2.4)
          )
        }
      } catch {
        let status = loginItemService.status
        preferences.launchAtLoginEnabled = status.isEnabled
        onboarding.launchAtLoginEnabled = status.isEnabled
        persistPreferences()
        showToast(title: "Login item update failed", detail: error.localizedDescription, kind: .error)
      }
    }
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
        let built = await backend.currentSnapshot()
        session = mergedSession(with: built, cached: warmSnapshot)
        invalidateVisibleAppsCache()
        cleanupStaleEntries()
        await reapplyRestoredAudioState()
        diagnostics = await backend.diagnosticsReport()
        availableDevices = await backend.availableOutputDevices()
        persistSessionSnapshot()
        syncOnboarding(using: session)
        checkAutoPauseMusic()
        showToast(title: "Waves is ready", detail: "Per-app audio mixer loaded.", kind: .success)
      } catch {
        isBootstrapped = false
        showToast(title: "Startup failed", detail: error.localizedDescription, kind: .error, duration: .seconds(3.2))
      }
    }
  }

  func refresh() {
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
        session = try await backend.refresh()
        invalidateVisibleAppsCache()
        cleanupStaleEntries()
        persistSessionSnapshot()
        diagnostics = await backend.diagnosticsReport()
        syncOnboarding(using: session)
        checkAutoPauseMusic()
        showToast(title: "Library refreshed", detail: "\(session.apps.count) app\(session.apps.count == 1 ? "" : "s") detected.", kind: .info)
      } catch {
        showToast(title: "Refresh failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func handleURLScheme(_ url: URL) {
    guard preferences.enableURLScheme else {
      logger.warning("URL scheme invocation rejected because URL schemes are disabled")
      return
    }

    guard url.scheme == "waves",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let host = components.host else {
      return
    }

    // Charge the rate limit only against well-formed waves:// commands so a
    // flood of malformed URLs cannot exhaust the quota for legitimate ones.
    guard checkURLSchemeRateLimit() else {
      logger.warning("URL scheme invocation rejected because the rate limit was exceeded")
      return
    }

    logger.info("URL scheme invoked: \(host, privacy: .public)")

    switch host {
    case "set-volume":
      handleURLSetVolume(components)
    case "mute":
      handleURLMute(components)
    case "apply-preset":
      handleURLApplyPreset(components)
    case "refresh":
      refresh()
    default:
      logger.warning("URL scheme invoked with unknown host: \(host, privacy: .public)")
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

    setMuted(shouldMute, for: app)
  }

  private func handleURLApplyPreset(_ components: URLComponents) {
    guard let presetName = components.queryItems?.first(where: { $0.name == "name" })?.value,
          presetName.count <= 256 else {
      showToast(title: "URL command blocked", detail: "Preset command was invalid.", kind: .warning)
      return
    }

    guard let preset = presets.first(where: { $0.name.localizedCaseInsensitiveCompare(presetName) == .orderedSame }) else {
      showToast(title: "URL command blocked", detail: "Preset not found: \(String(presetName.prefix(64)))", kind: .warning)
      return
    }

    applyPreset(preset)
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
        self.mergeAppState(from: backendSession, appID: appID)
        self.diagnostics = await self.backend.diagnosticsReport()
        self.persistSessionSnapshot()
        let appName = self.session.apps.first(matchingAppKey: appID)?.displayName ?? "App"
        showToast(
          title: "Managed route active",
          detail: "\(appName) set to \(Int(target * 100))%",
          kind: .success,
          duration: .seconds(1.2)
        )
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

        do {
          self.session = try await self.backend.refresh()
          self.invalidateVisibleAppsCache()
          self.diagnostics = await self.backend.diagnosticsReport()
          self.persistSessionSnapshot()
        } catch {
          // inner refresh failure is already surfaced by outer toast
        }
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

    if let index = session.apps.firstIndex(matchingAppKey: appKey) {
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

    if preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID {
      let settings = AppVolumeSettings(
        desiredVolume: app.desiredVolume,
        isMuted: isMuted,
        volumeBoost: app.volumeBoost
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
        mergeAppState(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(
          title: isMuted ? "App muted" : "App unmuted",
          detail: appName,
          kind: .success,
          duration: .seconds(1.1)
        )
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

    if let index = session.apps.firstIndex(matchingAppKey: appKey) {
      session.apps[index].volumeBoost = clampedBoost
      invalidateVisibleAppsCache()
    }

    if preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID {
      let settings = AppVolumeSettings(
        desiredVolume: app.desiredVolume,
        isMuted: app.isMuted,
        volumeBoost: clampedBoost
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
        mergeAppState(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(
          title: "Boost updated",
          detail: "\(appName): \(Int(clampedBoost))x",
          kind: .success,
          duration: .seconds(1.1)
        )
      } catch {
        let backendSession = await backend.currentSnapshot()
        mergeAppState(from: backendSession, appID: appKey)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(title: "Boost update failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func togglePinned(_ app: AudioApp) {
    let appName = app.displayName
    let willPin = !app.isPinned
    Task {
      do {
        try await backend.pinApp(willPin, appID: app.logicalID)
        session = await backend.currentSnapshot()
        invalidateVisibleAppsCache()
        persistSessionSnapshot()
        showToast(
          title: willPin ? "Pinned" : "Unpinned",
          detail: appName,
          kind: .info,
          duration: .seconds(1.2)
        )
      } catch {
        showToast(title: "Pinning failed", detail: error.localizedDescription, kind: .error)
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
  func setExcluded(_ excluded: Bool, for app: AudioApp) {
    var ids = Set(preferences.excludedAppIDs)
    if excluded {
      ids.insert(app.logicalID)
    } else {
      ids.remove(app.logicalID)
    }
    preferences.excludedAppIDs = Array(ids).sorted()
    persistPreferences()

    if excluded {
      // Tear down any active route so Waves stops touching this app's audio,
      // and reflect the excluded state in the row.
      let bundleID = app.bundleID
      let pid = app.pid ?? -1
      Task { await backend.releaseControllers(forBundleID: bundleID, pid: pid) }
      if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
        session.apps[index].routingState = .monitorOnly
        session.apps[index].appliedVolume = nil
        session.apps[index].notes = "Excluded from Waves"
      }
      pendingVolumeApplyTasks[app.logicalID]?.cancel()
      pendingVolumeTargets.removeValue(forKey: app.logicalID)
    } else if let index = session.apps.firstIndex(matchingAppKey: app.logicalID) {
      session.apps[index].notes = nil
    }
    invalidateVisibleAppsCache()
    showToast(
      title: excluded ? "Excluded from Waves" : "Managed by Waves",
      detail: app.displayName,
      kind: .info,
      duration: .seconds(1.4)
    )
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
    lines.append("Audio capture permission: \(status.hasRequiredPermissions ? "granted" : "not granted")")
    lines.append("Route recovery healthy: \(status.isRouteRecoveryHealthy)")
    if let error = status.lastError { lines.append("Last error: \(error)") }
    lines.append("")
    lines.append("Apps (\(visibleApps.count)):")
    for app in visibleApps {
      let muted = app.isMuted ? ", muted" : ""
      let boost = app.volumeBoost > 1 ? ", boost \(Int(app.volumeBoost))x" : ""
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
    Task {
      do {
        try await backend.setDefaultOutputDevice(uid: device.id)
        // The device-change event refreshes the session; refresh the list so
        // the current-device checkmark updates immediately.
        availableDevices = await backend.availableOutputDevices()
        showToast(title: "Output switched", detail: device.name, kind: .success, duration: .seconds(1.4))
      } catch {
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
    guard preferences.autoRestoreDevice else { return }

    Task {
      // The backend has already re-established managed routes before emitting
      // the event, so read the current snapshot rather than restoring again.
      let previousDeviceID = currentDeviceID
      session = await backend.currentSnapshot()
      invalidateVisibleAppsCache()

      if preferences.enablePerDeviceVolumePresets, let newDeviceID = currentDeviceID, previousDeviceID != newDeviceID {
        await restoreDeviceVolumePresets(for: newDeviceID)
      }

      persistSessionSnapshot()
      diagnostics = await backend.diagnosticsReport()
      availableDevices = await backend.availableOutputDevices()
      syncOnboarding(using: session)

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
    for index in session.apps.indices {
      let app = session.apps[index]
      guard !isExcluded(app) else { continue }
      let isCustomized = app.isMuted || app.volumeBoost > 1.0 || abs(app.desiredVolume - 1.0) > 0.001
      guard isCustomized else { continue }
      do {
        try await backend.setVolumeBoost(app.volumeBoost, forAppID: app.logicalID)
        try await backend.setMuted(app.isMuted, forAppID: app.logicalID)
        try await backend.setDesiredVolume(app.desiredVolume, forAppID: app.logicalID)
        if let liveIndex = session.apps.firstIndex(matchingAppKey: app.logicalID) {
          session.apps[liveIndex].appliedVolume = app.isMuted ? 0 : app.desiredVolume
          session.apps[liveIndex].routingState = .managed
        }
      } catch {
        // App may not be running this session; leave its saved state untouched.
        logger.debug("Skipped restoring audio state for \(app.displayName): \(error.localizedDescription)")
      }
    }
    invalidateVisibleAppsCache()
  }

  private func restoreDeviceVolumePresets(for deviceID: String) async {
    for index in session.apps.indices {
      let app = session.apps[index]
      if let settings = deviceVolumePresets.getVolumeSettings(for: app.logicalID, deviceID: deviceID) {
        session.apps[index].desiredVolume = settings.desiredVolume
        session.apps[index].isMuted = settings.isMuted
        session.apps[index].volumeBoost = settings.volumeBoost

        do {
          try await backend.setDesiredVolume(settings.desiredVolume, forAppID: app.logicalID)
          try await backend.setMuted(settings.isMuted, forAppID: app.logicalID)
          try await backend.setVolumeBoost(settings.volumeBoost, forAppID: app.logicalID)
        } catch {
          logger.error("Failed to restore volume preset for \(app.displayName): \(error)")
        }
      }
    }
    invalidateVisibleAppsCache()
    persistSessionSnapshot()
  }

  func shutdown() {
    deviceChangeObserver?.cancel()
    deviceChangeObserver = nil
    if let frontmostAppObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
      self.frontmostAppObserver = nil
    }
    if let appTerminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
      self.appTerminationObserver = nil
    }
    let backend = backend
    Task { await backend.stop() }
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
    // for the next refresh.
    Task { await backend.releaseControllers(forBundleID: bundleID, pid: pid) }

    // Reflect the termination in the UI immediately.
    var changed = false
    for index in session.apps.indices {
      let app = session.apps[index]
      guard (bundleID != nil && app.bundleID == bundleID) || app.pid == pid else { continue }
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
    if changed { invalidateVisibleAppsCache() }
  }

  func checkAutoPauseMusic() {
    guard preferences.autoPauseMusicForConferencing else { return }

    // Detect conferencing from the live frontmost application rather than the
    // session snapshot, whose `isActive` flags are only refreshed periodically.
    let frontmost = NSWorkspace.shared.frontmostApplication
    let currentFrontmostApp = frontmost?.bundleIdentifier
    guard currentFrontmostApp != previousFrontmostApp else { return }
    previousFrontmostApp = currentFrontmostApp

    let frontmostCategory = frontmost.map {
      AppDiscoveryPolicy.inferCategory(bundleID: $0.bundleIdentifier, displayName: $0.localizedName ?? "")
    }
    let isConferencingAppActive = frontmostCategory == .conferencing

    Task {
      var muteChanges: [String: (muted: Bool, source: MuteSource)] = [:]
      if isConferencingAppActive {
        // Pause currently-unmuted music apps and tag the mute as automatic.
        let musicApps = visibleApps.filter { $0.category == .media && !$0.isMuted && !isExcluded($0) }
        for app in musicApps {
          do {
            try await backend.setMuted(true, forAppID: app.logicalID)
            pausedMusicApps.insert(app.logicalID)
            muteChanges[app.logicalID] = (true, .autoConferencing)
            logger.info("Auto-paused music app: \(app.displayName)")
          } catch {
            logger.error("Failed to pause music app \(app.displayName): \(error)")
          }
        }
      } else {
        // Resume ONLY apps Waves auto-paused that the user hasn't since touched
        // (muteSource still .autoConferencing). Never override a user's mute.
        let resumable = visibleApps.filter { $0.isMuted && $0.muteSource == .autoConferencing }
        for app in resumable {
          do {
            try await backend.setMuted(false, forAppID: app.logicalID)
            muteChanges[app.logicalID] = (false, .user)
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
    }
  }

  func applyPreset(_ preset: Preset) {
    Task {
      do {
        session = try await backend.applyPreset(preset)
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        checkAutoPauseMusic()
        showToast(
          title: "Preset applied",
          detail: preset.name,
          kind: .success,
          duration: .seconds(1.4)
        )
      } catch {
        session = await backend.currentSnapshot()
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(title: "Preset apply failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func savePreset(named name: String) {
    Task {
      do {
        let preset = try await backend.saveCurrentPreset(named: name)
        let trimmedName = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingIndex = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame })
        {
          var replacement = preset
          replacement.id = presets[existingIndex].id
          replacement.name = presets[existingIndex].name
          replacement.createdAt = presets[existingIndex].createdAt
          replacement.updatedAt = .now
          presets[existingIndex] = replacement
        } else {
          presets.append(preset)
        }
        presetStore.save(presets)
        showToast(
          title: "Preset saved",
          detail: name,
          kind: .success,
          duration: .seconds(1.6)
        )
      } catch {
        showToast(title: "Save failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func deletePresets(at offsets: IndexSet) {
    presets.remove(atOffsets: offsets)
    presetStore.save(presets)
    if !offsets.isEmpty {
      showToast(
        title: "Preset removed",
        detail: "Removed from library.",
        kind: .info,
        duration: .seconds(1.1)
      )
    }
  }

  func exportPreset(_ preset: Preset) {
    Task {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(preset)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(preset.name).json"
        savePanel.canCreateDirectories = true

        guard let window = NSApp.mainWindow else {
          showToast(title: "Export failed", detail: "No main window available", kind: .error)
          return
        }

        let response = await savePanel.beginSheetModal(for: window)
        if response == .OK, let url = savePanel.url {
          try data.write(to: url, options: .atomic)
          showToast(
            title: "Preset exported",
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

  func importPreset() {
    Task {
      let openPanel = NSOpenPanel()
      openPanel.allowedContentTypes = [.json]
      openPanel.canChooseFiles = true
      openPanel.canChooseDirectories = false
      openPanel.allowsMultipleSelection = false

      guard let window = NSApp.mainWindow else {
        showToast(title: "Import failed", detail: "No main window available", kind: .error)
        return
      }

      let response = await openPanel.beginSheetModal(for: window)
      if response == .OK, let url = openPanel.url {
        do {
          // Validate file size before loading
          let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
          if let fileSize = attributes[.size] as? Int64, fileSize > 10 * 1024 * 1024 {
            showToast(title: "Import failed", detail: "File exceeds 10MB limit", kind: .error)
            return
          }

          let data = try Data(contentsOf: url)
          let decoder = JSONDecoder()
          let preset = try decoder.decode(Preset.self, from: data)

          // Validate preset structure
          if preset.name.isEmpty {
            showToast(title: "Import failed", detail: "Preset name cannot be empty", kind: .error)
            return
          }

          if preset.entries.count > 1000 {
            showToast(title: "Import failed", detail: "Preset has too many entries (max 1000)", kind: .error)
            return
          }

          if let existingIndex = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }) {
            var imported = preset
            imported.id = presets[existingIndex].id
            imported.name = presets[existingIndex].name
            imported.createdAt = presets[existingIndex].createdAt
            imported.updatedAt = .now
            presets[existingIndex] = imported
          } else {
            // Assign a fresh identity so importing a preset never collides with
            // an existing one's UUID (which breaks SwiftUI list identity).
            var imported = preset
            imported.id = UUID()
            imported.createdAt = .now
            imported.updatedAt = .now
            presets.append(imported)
          }

          presetStore.save(presets)
          showToast(
            title: "Preset imported",
            detail: preset.name,
            kind: .success,
            duration: .seconds(2.0)
          )
        } catch {
          showToast(title: "Import failed", detail: error.localizedDescription, kind: .error)
        }
      }
    }
  }

  func recoverRoutes() {
    Task {
      do {
        session = try await backend.recoverRoutes()
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        syncOnboarding(using: session)
        showToast(
          title: "Routes recovered",
          detail: "Managed routing paths were reattached.",
          kind: .success
        )
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
      diagnostics = await backend.diagnosticsReport()
    }
  }

  func increaseVolumeForFrontmostApp(step: Float = 0.1) {
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = activeApps.first ?? visibleApps.first
    guard let app = frontmostApp else { return }

    // Validate step parameter bounds
    let clampedStep = max(0.01, min(step, 0.5))
    let newVolume = min(app.desiredVolume + clampedStep, 1.0)
    setDesiredVolume(newVolume, for: app)
    commitDesiredVolume(for: app)

    showToast(
      title: "Volume increased",
      detail: "\(app.displayName): \(Int(newVolume * 100))%",
      kind: .info,
      duration: .seconds(1.0)
    )
  }

  func decreaseVolumeForFrontmostApp(step: Float = 0.1) {
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = activeApps.first ?? visibleApps.first
    guard let app = frontmostApp else { return }

    // Validate step parameter bounds
    let clampedStep = max(0.01, min(step, 0.5))
    let newVolume = max(app.desiredVolume - clampedStep, 0.0)
    setDesiredVolume(newVolume, for: app)
    commitDesiredVolume(for: app)

    showToast(
      title: "Volume decreased",
      detail: "\(app.displayName): \(Int(newVolume * 100))%",
      kind: .info,
      duration: .seconds(1.0)
    )
  }

  func toggleMuteForFrontmostApp() {
    guard preferences.enableKeyboardShortcuts else { return }
    let frontmostApp = activeApps.first ?? visibleApps.first
    guard let app = frontmostApp else { return }

    let newMutedState = !app.isMuted
    setMuted(newMutedState, for: app)

    showToast(
      title: newMutedState ? "Muted" : "Unmuted",
      detail: app.displayName,
      kind: .info,
      duration: .seconds(1.0)
    )
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

    if app.routingState == .managed && !app.isMuted && max(app.peakLevel, app.rmsLevel) > 0.001 {
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
    return { app1, app2 in
      let index1 = order.firstIndex(of: app1.logicalID) ?? Int.max
      let index2 = order.firstIndex(of: app2.logicalID) ?? Int.max
      if index1 != index2 {
        return index1 < index2
      }
      return app1.displayName < app2.displayName
    }
  }

  func reorderApps(from source: IndexSet, to destination: Int) {
    if preferences.sortMode != .manual {
      preferences.sortMode = .manual
      persistPreferences()
    }

    var apps = visibleApps.map { $0.logicalID }
    // Use the standard collection move so downward drags land on the drop
    // target instead of one row below it (the manual remove/insert was off by
    // one because the removal shifts later indices).
    apps.move(fromOffsets: source, toOffset: destination)

    preferences.customAppOrder = apps
    persistPreferences()
    invalidateVisibleAppsCache()
  }

  private func syncOnboarding(using snapshot: AudioSessionSnapshot) {
    onboarding.audioComponentInstalled = snapshot.backendStatus.isAudioComponentInstalled
    onboarding.permissionsGranted = snapshot.backendStatus.hasRequiredPermissions
    onboarding.accessibilityPermissionGranted = AXIsProcessTrusted()
    onboarding.outputDeviceVisible = snapshot.currentDevice != nil
    onboarding.routeHealthReady = snapshot.backendStatus.isRouteRecoveryHealthy
    let launchAtLoginEnabled = loginItemService.status.isEnabled
    onboarding.launchAtLoginEnabled = launchAtLoginEnabled
    preferences.launchAtLoginEnabled = launchAtLoginEnabled
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

  private func persistSessionSnapshot() {
    sessionStore.save(session)
  }

  private func showToast(
    title: String,
    detail: String? = nil,
    kind: AppToast.Kind,
    duration: Duration? = nil
  ) {
    let toast = AppToast(
      title: title,
      detail: detail,
      kind: kind,
      duration: duration ?? defaultToastDuration
    )

    toasts.append(toast)
    trimToasts()

    toastDismissals[toast.id]?.cancel()
    toastDismissals[toast.id] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: toast.duration)
        self?.dismissToast(id: toast.id)
      } catch is CancellationError {
        return
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

  private func trimToasts() {
    while toasts.count > maxToasts {
      let removed = toasts.removeFirst()
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
  var outputDeviceVisible = true
  var routeHealthReady = false
  var launchAtLoginEnabled = false

  var isReadyForEverydayUse: Bool {
    permissionsGranted && outputDeviceVisible && routeHealthReady
  }
}

extension Notification.Name {
  /// Posted when the user toggles keyboard shortcuts so the app delegate can
  /// install or remove the system-wide key monitor.
  static let wavesKeyboardShortcutsPreferenceChanged = Notification.Name("WavesKeyboardShortcutsPreferenceChanged")
}
