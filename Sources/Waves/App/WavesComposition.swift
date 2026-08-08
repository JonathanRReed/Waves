import Foundation
import WavesAudioCore

@MainActor
struct WavesComposition {
  let makeStore: @MainActor () -> AppStore

  typealias LiveBackendFactory = (
    @escaping WorkspaceAudioControlBackend.VerifiedRouterConflictProvider,
    @escaping WorkspaceAudioControlBackend.VerifiedRouterActivityProvider
  ) -> WorkspaceAudioControlBackend

  static let live = makeLive()

  static func makeLiveBackend(
    serviceFactory: () -> VerifiedRouterConflictService = { VerifiedRouterConflictService() },
    backendFactory: LiveBackendFactory = { conflictProvider, activityProvider in
      WorkspaceAudioControlBackend(
        verifiedRouterConflictProvider: conflictProvider,
        verifiedRouterActivityProvider: activityProvider
      )
    }
  ) -> WorkspaceAudioControlBackend {
    let service = serviceFactory()
    return backendFactory(
      { app in service.conflict(for: app) },
      { service.activitySnapshot() }
    )
  }

  static func makeLive() -> WavesComposition {
    WavesComposition {
      makeStore(environment: ProcessInfo.processInfo.environment)
    }
  }

  static func makeStore(
    environment: [String: String],
    liveBackendFactory: () -> any AudioControlBackend = { makeLiveBackend() }
  ) -> AppStore {
    let backend = configuredBackend(environment: environment, liveBackendFactory: liveBackendFactory)
    if let fixedHome = environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty {
      let dataDirectory = URL(fileURLWithPath: fixedHome, isDirectory: true)
        .appendingPathComponent("Library/Application Support/Waves", isDirectory: true)
      return AppStore(
        backend: backend,
        preferencesStore: PreferencesStore(directory: dataDirectory),
        profileStore: ProfileStore(directory: dataDirectory),
        sessionStore: SessionStore(directory: dataDirectory),
        loginItemService: LoginItemService(),
        deviceVolumePresetsStore: DeviceVolumePresetsStore(directory: dataDirectory)
      )
    }

    return AppStore(
      backend: backend,
      preferencesStore: PreferencesStore(),
      profileStore: ProfileStore(),
      sessionStore: SessionStore(),
      loginItemService: LoginItemService(),
      deviceVolumePresetsStore: DeviceVolumePresetsStore()
    )
  }

  static func configuredBackend(
    environment: [String: String],
    liveBackendFactory: () -> any AudioControlBackend = { makeLiveBackend() }
  ) -> any AudioControlBackend {
    if let snapshot = previewSnapshot(environment: environment) {
      return PreviewAudioControlBackend(snapshot: snapshot)
    }
    return liveBackendFactory()
  }

  nonisolated static func previewSnapshot(environment: [String: String]) -> AudioSessionSnapshot? {
    guard environment["CFFIXED_USER_HOME"]?.isEmpty == false,
      let path = environment["WAVES_PREVIEW_APPS_PATH"], !path.isEmpty
    else {
      return nil
    }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      let fixtures = try JSONDecoder().decode([PreviewControlAppFixture].self, from: data)
      return AudioSessionSnapshot(
        apps: fixtures.map(\.audioApp),
        currentDevice: nil,
        recentDeviceIDs: [],
        supportMatrix: SupportMatrix(entries: []),
        backendStatus: BackendStatus(
          isAudioComponentInstalled: true,
          hasRequiredPermissions: true,
          isRouteRecoveryHealthy: true,
          lastError: nil
        )
      )
    } catch {
      fatalError("Could not load WAVES_PREVIEW_APPS_PATH fixture at \(path): \(error)")
    }
  }
}

private struct PreviewControlAppFixture: Decodable {
  let id: String
  let logicalID: String?
  let bundleID: String?
  let name: String
  let category: AppCategory
  let running: Bool
  let live: Bool
  let managed: Bool
  let volume: Float
  let muted: Bool

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    logicalID = try container.decodeIfPresent(String.self, forKey: .logicalID)
    bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
    name = try container.decode(String.self, forKey: .name)
    category = try container.decodeIfPresent(AppCategory.self, forKey: .category) ?? .media
    running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? true
    live = try container.decodeIfPresent(Bool.self, forKey: .live) ?? true
    managed = try container.decodeIfPresent(Bool.self, forKey: .managed) ?? true
    volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1
    muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case logicalID
    case bundleID
    case name
    case category
    case running
    case live
    case managed
    case volume
    case muted
  }

  var audioApp: AudioApp {
    var app = AudioApp(
      id: id,
      logicalID: logicalID ?? id,
      pid: running ? 4242 : nil,
      bundleID: bundleID ?? logicalID ?? id,
      displayName: name,
      category: category,
      isActive: live,
      peakLevel: live ? 0.35 : 0,
      rmsLevel: live ? 0.22 : 0,
      desiredVolume: volume,
      appliedVolume: managed ? volume : nil,
      isMuted: muted,
      routingState: managed ? .managed : .monitorOnly,
      compatibility: managed ? .supported : .unsupported,
      muteSource: .user
    )
    app.notes = managed ? nil : "preview-monitor-only"
    return app
  }
}
