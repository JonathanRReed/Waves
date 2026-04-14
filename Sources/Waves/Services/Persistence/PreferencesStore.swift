import Foundation

struct PreferencesStore {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(fileManager: FileManager = .default) {
    let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("preferences.json")
  }

  func load() -> UserPreferences {
    guard
      let data = try? Data(contentsOf: url),
      let preferences = try? decoder.decode(UserPreferences.self, from: data)
    else {
      let defaults = UserPreferences()
      save(defaults)
      return defaults
    }

    return preferences
  }

  func save(_ preferences: UserPreferences) {
    guard let data = try? encoder.encode(preferences) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
