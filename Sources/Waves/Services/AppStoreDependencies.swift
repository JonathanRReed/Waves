import WavesAudioCore

protocol PreferencesPersisting: Sendable {
  func load() -> UserPreferences
  func save(_ preferences: UserPreferences) async throws
  func flush() async throws
  func consumeDidRecoverFromCorruptFile() -> Bool
}

protocol ProfilesPersisting: Sendable {
  func load(defaults: [Profile]) -> [Profile]
  func save(_ profiles: [Profile]) async throws
  func flush() async throws
  func consumeDidRecoverFromCorruptFile() -> Bool
}

protocol SessionPersisting: Sendable {
  func load() -> AudioSessionSnapshot?
  func save(_ snapshot: AudioSessionSnapshot) async throws
  func flush() async throws
  func consumeDidRecoverFromCorruptFile() -> Bool
}

protocol DeviceVolumePresetsPersisting: Sendable {
  func load() -> DeviceVolumePresets
  func save(_ presets: DeviceVolumePresets) async throws
  func flush() async throws
  func consumeDidRecoverFromCorruptFile() -> Bool
}

@MainActor
protocol LoginItemServicing {
  var status: LoginItemStatus { get }
  func setEnabled(_ enabled: Bool) throws
  func openSystemSettingsLoginItems()
}

extension PreferencesStore: PreferencesPersisting {}
extension ProfileStore: ProfilesPersisting {}
extension SessionStore: SessionPersisting {}
extension DeviceVolumePresetsStore: DeviceVolumePresetsPersisting {}
extension LoginItemService: LoginItemServicing {}
