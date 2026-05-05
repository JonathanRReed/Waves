import AppKit
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
  private let volumeApplyDelay = Duration.milliseconds(50) // Optimized from 80ms for better responsiveness
  private var toastDismissals: [UUID: Task<Void, Never>] = [:]
  private let maxToasts = 3
  private let defaultToastDuration = Duration.seconds(2.0)
  private var cachedVisibleApps: [AudioApp] = []
  private var needsVisibleAppsCacheUpdate = true
  private var previousFrontmostApp: String?
  private var pausedMusicApps: Set<String> = []
  private let maxPendingTasks = 100

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
      cachedVisibleApps = preferences.sortMode == .manual
        ? filtered.sorted(by: manualOrderComparator)
        : filtered.sorted(using: sortComparator)
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

  var recentApps: [AudioApp] {
    guard preferences.showRecentApps else { return [] }
    return visibleApps.filter { !$0.isActive }
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
    let hasMutedApps = visibleApps.contains(where: \.isMuted)
    if hasMutedApps {
      return "speaker.slash.fill"
    }

    let averageVolume = visibleApps.isEmpty ? 0 : visibleApps.reduce(0) { $0 + $1.desiredVolume } / Float(visibleApps.count)
    if averageVolume < 0.3 {
      return "speaker.wave.1.fill"
    } else if averageVolume > 0.7 {
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
        diagnostics = await backend.diagnosticsReport()
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

  func setDesiredVolume(_ value: Float, for app: AudioApp) {
    let appKey = app.logicalID
    guard let index = session.apps.firstIndex(matchingAppKey: appKey) else {
      let message = BackendError.appNotFound(app.id).localizedDescription
      showToast(title: "Volume change blocked", detail: message, kind: .warning)
      return
    }

    let clampedValue = max(0.0, min(1.0, value))
    session.apps[index].desiredVolume = clampedValue
    pendingVolumeTargets[appKey] = clampedValue

    if preferences.enablePerDeviceVolumePresets, let deviceID = currentDeviceID {
      let currentApp = session.apps[index]
      let settings = AppVolumeSettings(
        desiredVolume: clampedValue,
        isMuted: currentApp.isMuted,
        volumeBoost: currentApp.volumeBoost
      )
      deviceVolumePresets.saveVolumeSettings(for: appKey, deviceID: deviceID, settings: settings)
      // Save asynchronously to avoid blocking UI thread
      Task {
        deviceVolumePresetsStore.save(deviceVolumePresets)
      }
    }
  }

  func commitDesiredVolume(for app: AudioApp) {
    let appKey = app.logicalID
    if pendingVolumeTargets[appKey] == nil {
      pendingVolumeTargets[appKey] = app.desiredVolume
    }
    scheduleVolumeApply(forAppID: appKey, immediate: true)
  }

  private func scheduleVolumeApply(forAppID appID: String, immediate: Bool) {
    pendingVolumeApplyTasks[appID]?.cancel()

    // Clean up completed tasks if we're approaching the limit
    if pendingVolumeApplyTasks.count >= maxPendingTasks {
      cleanupCompletedTasks()
    }

    pendingVolumeApplyTasks[appID] = Task { @MainActor [weak self] in
      guard let self else { return }

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
        let appName = self.session.apps.first(where: { $0.id == appID })?.displayName ?? "App"
        showToast(
          title: "Managed route active",
          detail: "\(appName) set to \(Int(target * 100))%",
          kind: .success,
          duration: .seconds(1.2)
        )
        self.pendingVolumeTargets.removeValue(forKey: appID)
        self.pendingVolumeApplyTasks.removeValue(forKey: appID)
      } catch is CancellationError {
        self.pendingVolumeApplyTasks.removeValue(forKey: appID)
        return
      } catch {
        self.pendingVolumeTargets.removeValue(forKey: appID)
        self.pendingVolumeApplyTasks.removeValue(forKey: appID)
        let message = error.localizedDescription
        self.showToast(
          title: "Volume change failed",
          detail: message,
          kind: .error
        )

        do {
          self.session = try await self.backend.refresh()
          self.diagnostics = await self.backend.diagnosticsReport()
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
    let appName = app.displayName
    let appKey = app.logicalID

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
        session = await backend.currentSnapshot()
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(
          title: isMuted ? "App muted" : "App unmuted",
          detail: appName,
          kind: .success,
          duration: .seconds(1.1)
        )
      } catch {
        session = await backend.currentSnapshot()
        invalidateVisibleAppsCache()
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        showToast(title: "Mute toggle failed", detail: error.localizedDescription, kind: .error)
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
          title: willPin ? "Pinned in sidebar" : "Removed from sidebar",
          detail: appName,
          kind: .info,
          duration: .seconds(1.2)
        )
      } catch {
        showToast(title: "Pinning failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func setVolumeControlMode(_ mode: VolumeControlMode) {
    guard let deviceID = session.currentDevice?.id else { return }
    Task {
      do {
        try await backend.setVolumeControlMode(mode, forDeviceID: deviceID)
        session = await backend.currentSnapshot()
        persistSessionSnapshot()
        showToast(
          title: "Volume control mode changed",
          detail: mode.displayName,
          kind: .info,
          duration: .seconds(1.2)
        )
      } catch {
        showToast(title: "Failed to change volume mode", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func handleDeviceChange() {
    guard preferences.autoRestoreDevice else { return }

    Task {
      do {
        let previousDeviceID = currentDeviceID
        session = try await backend.autoRestoreDevice()
        invalidateVisibleAppsCache()
        persistSessionSnapshot()

        if preferences.enablePerDeviceVolumePresets, let newDeviceID = currentDeviceID, previousDeviceID != newDeviceID {
          await restoreDeviceVolumePresets(for: newDeviceID)
        }

        showToast(
          title: "Device restored",
          detail: "Audio routes re-established",
          kind: .success,
          duration: .seconds(1.5)
        )
      } catch {
        logger.error("Device auto-restore failed: \(error)")
      }
    }
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

  func checkAutoPauseMusic() {
    guard preferences.autoPauseMusicForConferencing else { return }

    let currentFrontmostApp = activeApps.first?.logicalID
    let isConferencingAppActive = activeApps.contains(where: { $0.category == .conferencing && $0.isActive })

    Task {
      if isConferencingAppActive {
        // Pause music apps
        let musicApps = visibleApps.filter { $0.category == .media && !$0.isMuted }
        for app in musicApps {
          if !pausedMusicApps.contains(app.logicalID) {
            do {
              try await backend.setMuted(true, forAppID: app.logicalID)
              pausedMusicApps.insert(app.logicalID)
              logger.info("Auto-paused music app: \(app.displayName)")
            } catch {
              logger.error("Failed to pause music app \(app.displayName): \(error)")
            }
          }
        }
      } else {
        // Resume previously paused music apps
        for appID in pausedMusicApps {
          if let app = visibleApps.first(where: { $0.logicalID == appID }) {
            do {
              try await backend.setMuted(false, forAppID: appID)
              logger.info("Auto-resumed music app: \(app.displayName)")
            } catch {
              logger.error("Failed to resume music app \(app.displayName): \(error)")
            }
          }
        }
        pausedMusicApps.removeAll()
      }

      session = await backend.currentSnapshot()
      invalidateVisibleAppsCache()
      persistSessionSnapshot()
    }

    previousFrontmostApp = currentFrontmostApp
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
          try data.write(to: url)
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
            presets.append(preset)
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

  private var sortComparator: KeyPathComparator<AudioApp> {
    switch preferences.sortMode {
    case .name:
      KeyPathComparator(\.displayName)
    case .activity:
      KeyPathComparator(\.peakLevel, order: .reverse)
    case .category:
      KeyPathComparator(\.category.rawValue)
    case .manual:
      KeyPathComparator(\.displayName)
    }
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

    for index in source {
      if index < apps.count {
        let movedItem = apps.remove(at: index)
        let insertIndex = min(destination, apps.count)
        apps.insert(movedItem, at: insertIndex)
      }
    }

    preferences.customAppOrder = apps
    persistPreferences()
    invalidateVisibleAppsCache()
  }

  private func syncOnboarding(using snapshot: AudioSessionSnapshot) {
    onboarding.audioComponentInstalled = snapshot.backendStatus.isAudioComponentInstalled
    onboarding.permissionsGranted = snapshot.backendStatus.hasRequiredPermissions
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
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: false,
        lastError: "No cached session loaded yet."
      ),
      updatedAt: .now
    )
  }

  private func mergedSession(with liveSession: AudioSessionSnapshot, cached: AudioSessionSnapshot) -> AudioSessionSnapshot {
    guard !cached.apps.isEmpty else { return liveSession }

    let cachedByLogicalID = Dictionary(uniqueKeysWithValues: cached.apps.map { ($0.logicalID, $0) })

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
  var permissionsGranted = true
  var outputDeviceVisible = true
  var routeHealthReady = false
  var launchAtLoginEnabled = false

  var isReadyForEverydayUse: Bool {
    permissionsGranted && outputDeviceVisible
  }
}
