import Foundation
import OSLog

enum JSONPersistenceLoadResult<Value> {
  case missing
  case loaded(Value)
  case recoveredFromCorruption
}

struct JSONPersistenceCodec<Value>: @unchecked Sendable {
  let encode: (Value) throws -> Data
  let decode: (Data) throws -> Value
}

/// Shared bounded JSON persistence mechanics for every Waves state payload.
/// Store wrappers retain their existing public protocols and supply only the
/// payload-specific codec and first-launch default behavior.
final class JSONPersistenceEngine<Value: Sendable>: @unchecked Sendable {
  static var standardMaximumFileSize: Int64 { 10 * 1024 * 1024 }

  let url: URL

  private let fileManager: FileManager
  private let maximumFileSize: Int64
  private let displayName: String
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let queue: DispatchQueue
  private let codec: JSONPersistenceCodec<Value>
  private let writeData: PersistenceDataWrite
  private let writer: CoalescingPersistenceWriter<Value>
  private var recoveredFromCorruption = false

  init(
    url: URL,
    queueLabel: String,
    displayName: String,
    maximumFileSize: Int64 = JSONPersistenceEngine.standardMaximumFileSize,
    fileManager: FileManager = .default,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write,
    codec: JSONPersistenceCodec<Value>
  ) {
    self.url = url
    self.fileManager = fileManager
    self.maximumFileSize = maximumFileSize
    self.displayName = displayName
    self.codec = codec
    self.writeData = writeData
    let queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    self.queue = queue
    self.writer = CoalescingPersistenceWriter(queue: queue) { value in
      try writeData(codec.encode(value), url)
    }

    do {
      try PersistenceSecurity.preparePrivateDirectory(
        url.deletingLastPathComponent(),
        fileManager: fileManager
      )
    } catch {
      logger.error("Failed to prepare private \(displayName) directory: \(error.localizedDescription)")
    }
  }

  func load() -> JSONPersistenceLoadResult<Value> {
    load(from: url)
  }

  func load(from fileURL: URL) -> JSONPersistenceLoadResult<Value> {
    queue.sync {
      guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }
      PersistenceSecurity.secureExistingFile(at: fileURL, fileManager: fileManager)
      do {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize <= maximumFileSize else {
          throw JSONPersistenceEngineError.fileTooLarge(
            actual: fileSize,
            maximum: maximumFileSize
          )
        }
        return .loaded(try codec.decode(Data(contentsOf: fileURL)))
      } catch {
        logger.warning(
          "Failed to load \(self.displayName): \(error.localizedDescription). Preserving file and using defaults."
        )
        preserveCorruptFile(at: fileURL)
        recoveredFromCorruption = true
        return .recoveredFromCorruption
      }
    }
  }

  func save(_ value: Value) async throws {
    do {
      try await writer.save(value)
    } catch {
      logger.error("Failed to save \(self.displayName): \(error.localizedDescription)")
      throw error
    }
  }

  func flush() async throws {
    do {
      try await writer.flush()
    } catch {
      logger.error("Failed to flush \(self.displayName): \(error.localizedDescription)")
      throw error
    }
  }

  func writeSynchronously(_ value: Value) throws {
    try queue.sync {
      try writeData(codec.encode(value), url)
    }
  }

  func consumeDidRecoverFromCorruptFile() -> Bool {
    queue.sync {
      defer { recoveredFromCorruption = false }
      return recoveredFromCorruption
    }
  }

  func clear() {
    queue.sync {
      try? fileManager.removeItem(at: url)
    }
  }

  private func preserveCorruptFile(at fileURL: URL) {
    let backupURL = fileURL.appendingPathExtension("corrupt")
    try? fileManager.removeItem(at: backupURL)
    do {
      try fileManager.moveItem(at: fileURL, to: backupURL)
      try PersistenceSecurity.setPrivateFilePermissions(backupURL, fileManager: fileManager)
      logger.warning("Moved unreadable \(self.displayName) file to \(backupURL.lastPathComponent)")
    } catch {
      logger.error("Failed to preserve unreadable \(self.displayName) file: \(error.localizedDescription)")
    }
  }
}

private enum JSONPersistenceEngineError: LocalizedError {
  case fileTooLarge(actual: Int64, maximum: Int64)

  var errorDescription: String? {
    switch self {
    case .fileTooLarge(let actual, let maximum):
      "Persistence file is \(actual) bytes, exceeding the \(maximum)-byte limit."
    }
  }
}

enum PersistenceLocation {
  static func applicationSupportDirectory(fileManager: FileManager) -> URL {
    if let supportDirectory = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first {
      return supportDirectory.appendingPathComponent("Waves", isDirectory: true)
    }
    return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".Waves", isDirectory: true)
  }
}
