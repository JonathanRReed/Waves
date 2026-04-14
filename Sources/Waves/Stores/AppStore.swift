import Foundation
import Observation
import WavesAudioCore

@Observable
@MainActor
final class AppStore {
  var session: AudioSessionSnapshot
  var presets: [Preset]
  var onboarding = OnboardingState()
  var preferences: UserPreferences
  var diagnostics: DiagnosticsReport?
  var isRefreshing = false
  var errorMessage: String?

  private let backend: any AudioControlBackend
  private let preferencesStore: PreferencesStore
  private let presetStore: PresetStore
  private let loginItemService: LoginItemService

  init(
    backend: any AudioControlBackend,
    preferencesStore: PreferencesStore,
    presetStore: PresetStore,
    loginItemService: LoginItemService
  ) {
    self.backend = backend
    self.preferencesStore = preferencesStore
    self.presetStore = presetStore
    self.loginItemService = loginItemService
    self.preferences = preferencesStore.load()
    self.presets = presetStore.load(defaults: Preset.defaults)
    self.session = .preview
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
      preferences.launchAtLoginEnabled = newValue
      persistPreferences()
      do {
        try loginItemService.setEnabled(newValue)
        onboarding.launchAtLoginEnabled = newValue
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func start() {
    Task {
      do {
        try await backend.start()
        session = await backend.currentSnapshot()
        diagnostics = await backend.diagnosticsReport()
        syncOnboarding(using: session)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func refresh() {
    Task {
      isRefreshing = true
      defer { isRefreshing = false }

      do {
        session = try await backend.refresh()
        diagnostics = await backend.diagnosticsReport()
        syncOnboarding(using: session)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setDesiredVolume(_ value: Float, for app: AudioApp) {
    Task {
      do {
        try await backend.setDesiredVolume(value, forAppID: app.id)
        session = try await backend.refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func setMuted(_ isMuted: Bool, for app: AudioApp) {
    Task {
      do {
        try await backend.setMuted(isMuted, forAppID: app.id)
        session = try await backend.refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func togglePinned(_ app: AudioApp) {
    Task {
      do {
        try await backend.pinApp(!app.isPinned, appID: app.id)
        session = try await backend.refresh()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func applyPreset(_ preset: Preset) {
    Task {
      do {
        session = try await backend.applyPreset(preset)
      } catch {
        errorMessage = error.localizedDescription
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
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func deletePresets(at offsets: IndexSet) {
    presets.remove(atOffsets: offsets)
    presetStore.save(presets)
  }

  func recoverRoutes() {
    Task {
      do {
        session = try await backend.recoverRoutes()
        syncOnboarding(using: session)
      } catch {
        errorMessage = error.localizedDescription
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
