import Foundation
import Observation
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

  private let backend: any AudioControlBackend
  private let preferencesStore: PreferencesStore
  private let presetStore: PresetStore
  private let sessionStore: SessionStore
  private let loginItemService: LoginItemService
  private var isBootstrapped = false
  private var pendingVolumeTargets: [String: Float] = [:]
  private var pendingVolumeApplyTasks: [String: Task<Void, Never>] = [:]
  private let volumeApplyDelay = Duration.milliseconds(80)
  private var toastDismissals: [UUID: Task<Void, Never>] = [:]
  private let maxToasts = 3
  private let defaultToastDuration = Duration.seconds(2.0)

  init(
    backend: any AudioControlBackend,
    preferencesStore: PreferencesStore,
    presetStore: PresetStore,
    sessionStore: SessionStore,
    loginItemService: LoginItemService
  ) {
    self.backend = backend
    self.preferencesStore = preferencesStore
    self.presetStore = presetStore
    self.sessionStore = sessionStore
    self.loginItemService = loginItemService
    self.preferences = preferencesStore.load()
    self.presets = presetStore.load(defaults: Preset.defaults)
    self.session = sessionStore.load() ?? Self.emptySession
    self.preferences.launchAtLoginEnabled = loginItemService.status.isEnabled
    self.onboarding = OnboardingState(
      launchAtLoginEnabled: loginItemService.status.isEnabled
    )
    persistPreferences()
    syncOnboarding(using: session)
  }

  var visibleApps: [AudioApp] {
    session.apps
      .filter { preferences.showSystemProcesses || $0.category != .system }
      .sorted(using: sortComparator)
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

  var currentDeviceName: String {
    session.currentDevice?.name ?? "No output device"
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
          isLoading = false
        }

        try await backend.start()
        let built = await backend.currentSnapshot()
        session = mergedSession(with: built, cached: warmSnapshot)
        diagnostics = await backend.diagnosticsReport()
        persistSessionSnapshot()
        syncOnboarding(using: session)
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
        persistSessionSnapshot()
        diagnostics = await backend.diagnosticsReport()
        syncOnboarding(using: session)
        showToast(title: "Library refreshed", detail: "\(session.apps.count) app\(session.apps.count == 1 ? "" : "s") detected.", kind: .info)
      } catch {
        showToast(title: "Refresh failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func setDesiredVolume(_ value: Float, for app: AudioApp) {
    guard let index = session.apps.firstIndex(where: { $0.id == app.id }) else {
      let message = BackendError.appNotFound(app.id).localizedDescription
      showToast(title: "Volume change blocked", detail: message, kind: .warning)
      return
    }

    let clampedValue = max(0.0, min(1.0, value))
    session.apps[index].desiredVolume = clampedValue
    pendingVolumeTargets[app.id] = clampedValue
  }

  func commitDesiredVolume(for app: AudioApp) {
    if pendingVolumeTargets[app.id] == nil {
      pendingVolumeTargets[app.id] = app.desiredVolume
    }
    scheduleVolumeApply(forAppID: app.id, immediate: true)
  }

  private func scheduleVolumeApply(forAppID appID: String, immediate: Bool) {
    pendingVolumeApplyTasks[appID]?.cancel()

    pendingVolumeApplyTasks[appID] = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        if !immediate {
          try await Task.sleep(for: volumeApplyDelay)
        }

        guard let target = self.pendingVolumeTargets[appID], !Task.isCancelled else {
          return
        }

        try await self.backend.setDesiredVolume(target, forAppID: appID)
        let backendSession = await self.backend.currentSnapshot()
        self.mergeAppState(from: backendSession, appID: appID)
        self.persistSessionSnapshot()
        let appName = self.session.apps.first(where: { $0.id == appID })?.displayName ?? "App"
        showToast(
          title: "Managed route active",
          detail: "\(appName) set to \(Int(target * 100))%",
          kind: .success,
          duration: .seconds(1.2)
        )
        self.pendingVolumeTargets.removeValue(forKey: appID)
        self.pendingVolumeApplyTasks[appID] = nil
      } catch is CancellationError {
        return
      } catch {
        self.pendingVolumeTargets.removeValue(forKey: appID)
        self.pendingVolumeApplyTasks[appID] = nil
        let message = error.localizedDescription
        self.showToast(
          title: "Volume change failed",
          detail: message,
          kind: .error
        )

        do {
          self.session = try await self.backend.refresh()
        } catch {
          // inner refresh failure is already surfaced by outer toast
        }
      }
    }
  }

  func setMuted(_ isMuted: Bool, for app: AudioApp) {
    let appName = app.displayName
    Task {
      do {
        try await backend.setMuted(isMuted, forAppID: app.id)
        session = await backend.currentSnapshot()
        persistSessionSnapshot()
        showToast(
          title: isMuted ? "App muted" : "App unmuted",
          detail: appName,
          kind: .success,
          duration: .seconds(1.1)
        )
      } catch {
        showToast(title: "Mute toggle failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func togglePinned(_ app: AudioApp) {
    let appName = app.displayName
    let willPin = !app.isPinned
    Task {
      do {
        try await backend.pinApp(willPin, appID: app.id)
        session = await backend.currentSnapshot()
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

  func applyPreset(_ preset: Preset) {
    Task {
      do {
        session = try await backend.applyPreset(preset)
        persistSessionSnapshot()
        showToast(
          title: "Preset applied",
          detail: preset.name,
          kind: .success,
          duration: .seconds(1.4)
        )
      } catch {
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

  func recoverRoutes() {
    Task {
      do {
        session = try await backend.recoverRoutes()
        persistSessionSnapshot()
        syncOnboarding(using: session)
        showToast(
          title: "Routes recovered",
          detail: "Managed routing paths were reattached.",
          kind: .success
        )
      } catch {
        showToast(title: "Recovery failed", detail: error.localizedDescription, kind: .error)
      }
    }
  }

  func refreshDiagnostics() {
    Task {
      diagnostics = await backend.diagnosticsReport()
    }
  }

  func persistPreferences() {
    preferencesStore.save(preferences)
  }

  private var sortComparator: KeyPathComparator<AudioApp> {
    switch preferences.sortMode {
    case .name:
      KeyPathComparator(\.displayName)
    case .activity:
      KeyPathComparator(\.peakLevel, order: .reverse)
    case .category:
      KeyPathComparator(\.category.rawValue)
    }
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
    guard let updatedApp = backendSession.apps.first(where: { $0.id == appID }) else {
      session = backendSession
      return
    }

    if let index = session.apps.firstIndex(where: { $0.id == appID }) {
      session.apps[index] = updatedApp
      session.currentDevice = backendSession.currentDevice
      session.recentDeviceIDs = backendSession.recentDeviceIDs
      session.supportMatrix = backendSession.supportMatrix
      session.backendStatus = backendSession.backendStatus
      session.updatedAt = backendSession.updatedAt
    } else {
      session = backendSession
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
