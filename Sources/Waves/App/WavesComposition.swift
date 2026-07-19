import Foundation

@MainActor
struct WavesComposition {
  let makeStore: @MainActor () -> AppStore

  static let live = WavesComposition {
    let environment = ProcessInfo.processInfo.environment
    if let fixedHome = environment["CFFIXED_USER_HOME"], !fixedHome.isEmpty {
      let dataDirectory = URL(fileURLWithPath: fixedHome, isDirectory: true)
        .appendingPathComponent("Library/Application Support/Waves", isDirectory: true)
      return AppStore(
        backend: WorkspaceAudioControlBackend(),
        preferencesStore: PreferencesStore(directory: dataDirectory),
        profileStore: ProfileStore(directory: dataDirectory),
        sessionStore: SessionStore(directory: dataDirectory),
        loginItemService: LoginItemService(),
        deviceVolumePresetsStore: DeviceVolumePresetsStore(directory: dataDirectory)
      )
    }

    return AppStore(
      backend: WorkspaceAudioControlBackend(),
      preferencesStore: PreferencesStore(),
      profileStore: ProfileStore(),
      sessionStore: SessionStore(),
      loginItemService: LoginItemService(),
      deviceVolumePresetsStore: DeviceVolumePresetsStore()
    )
  }
}
