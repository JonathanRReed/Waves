import Foundation

@MainActor
struct WavesComposition {
  let makeStore: @MainActor () -> AppStore

  typealias LiveBackendFactory = (
    @escaping WorkspaceAudioControlBackend.VerifiedRouterConflictProvider
  ) -> WorkspaceAudioControlBackend

  static let live = makeLive()

  static func makeLiveBackend(
    serviceFactory: () -> VerifiedRouterConflictService = { VerifiedRouterConflictService() },
    backendFactory: LiveBackendFactory = { provider in
      WorkspaceAudioControlBackend(verifiedRouterConflictProvider: provider)
    }
  ) -> WorkspaceAudioControlBackend {
    let service = serviceFactory()
    return backendFactory { app in
      service.conflict(for: app)
    }
  }

  static func makeLive() -> WavesComposition {
    WavesComposition {
      let environment = ProcessInfo.processInfo.environment
      let backend = makeLiveBackend()
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
  }
}
