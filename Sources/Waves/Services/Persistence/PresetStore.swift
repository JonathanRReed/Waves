import Foundation
import WavesAudioCore

struct PresetStore {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(fileManager: FileManager = .default) {
    let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    url = directory.appendingPathComponent("presets.json")
  }

  func load(defaults: [Preset]) -> [Preset] {
    guard
      let data = try? Data(contentsOf: url),
      let presets = try? decoder.decode([Preset].self, from: data)
    else {
      save(defaults)
      return defaults
    }

    return presets
  }

  func save(_ presets: [Preset]) {
    guard let data = try? encoder.encode(presets) else { return }
    try? data.write(to: url, options: .atomic)
  }
}
