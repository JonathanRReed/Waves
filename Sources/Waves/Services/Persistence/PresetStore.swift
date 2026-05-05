import Foundation
import OSLog
import WavesAudioCore

final class PresetStore: @unchecked Sendable {
  private let url: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let logger = Logger(subsystem: "com.waves.presets", category: "Persistence")
  private let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB
  private let queue = DispatchQueue(label: "com.waves.presets.store", qos: .userInitiated)

  init(fileManager: FileManager = .default) {
    guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      logger.error("Failed to get application support directory")
      let fallbackURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves")
      url = fallbackURL.appendingPathComponent("presets.json")
      return
    }
    let directory = supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      logger.error("Failed to create presets directory: \(error.localizedDescription)")
    }
    url = directory.appendingPathComponent("presets.json")
  }

  func load(defaults: [Preset]) -> [Preset] {
    return queue.sync {
      do {
        // Check file size before loading
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attributes[.size] as? Int64, fileSize > maxFileSize {
          logger.error("Presets file exceeds size limit: \(fileSize) bytes")
          save(defaults)
          return defaults
        }

        let data = try Data(contentsOf: url)
        let presets = try decoder.decode([Preset].self, from: data)
        return presets
      } catch {
        logger.warning("Failed to load presets: \(error.localizedDescription). Using defaults.")
        save(defaults)
        return defaults
      }
    }
  }

  func save(_ presets: [Preset]) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let data = try self.encoder.encode(presets)
        try data.write(to: self.url, options: .atomic)
      } catch {
        self.logger.error("Failed to save presets: \(error.localizedDescription)")
      }
    }
  }
}
