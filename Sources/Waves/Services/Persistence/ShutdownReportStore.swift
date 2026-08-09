import Foundation
import OSLog
import WavesAudioCore

/// One checked-cleanup row, flattened for persistence.
struct PersistedCleanupRow: Codable, Hashable, Sendable {
  var stage: String
  var appID: String?
  var nativeStatus: Int32?
  var detail: String?

  init(_ degradation: CleanupDegradation) {
    stage = degradation.stage.name
    appID = degradation.appID
    nativeStatus = degradation.nativeStatus
    detail = degradation.detail
  }
}

/// What happened the last time Waves shut down.
///
/// Why this exists: the 1.3.0 incident ended with
/// `backend status … degraded` in the log and nothing else. The individual
/// `CleanupDegradation` rows — which stage failed, with which OSStatus, for
/// which app — existed only in memory and died with the process, and the
/// unified-log entries that might have hinted at them had aged out of the
/// searchable store by the time anyone looked. A degraded shutdown that cannot
/// say *what* was degraded is not actionable.
///
/// Deliberately small and bounded: this is written on the termination path, so
/// it must never be the reason a quit hangs.
struct ShutdownReport: Codable, Hashable, Sendable {
  /// Caps the file so a pathological session cannot write an unbounded report
  /// while the app is trying to exit.
  static let maxCleanupRows = 32
  static let maxPersistenceIssues = 16

  var date: Date
  var appVersion: String
  var appBuild: String
  var sourceRevision: String?
  var osVersion: String
  /// `clean`, `degraded`, `timedOut` — the app-level completion.
  var completion: String
  /// `clean`, `degraded`, `timedOut`, `unverified`, or nil for a backend that
  /// never reported.
  var backendCompletion: String?
  var persistenceIssues: [String]
  var cleanupRows: [PersistedCleanupRow]
  /// Set when rows were dropped to stay inside the caps, so a truncated report
  /// never reads as a complete one.
  var droppedCleanupRows: Int
  var droppedPersistenceIssues: Int

  private enum CodingKeys: String, CodingKey {
    case date
    case appVersion
    case appBuild
    case sourceRevision
    case osVersion
    case completion
    case backendCompletion
    case persistenceIssues
    case cleanupRows
    case droppedCleanupRows
    case droppedPersistenceIssues
  }

  init(
    date: Date,
    appVersion: String,
    appBuild: String,
    sourceRevision: String?,
    osVersion: String,
    completion: String,
    backendCompletion: String?,
    persistenceIssues: [String],
    cleanupRows: [CleanupDegradation]
  ) {
    self.date = date
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.sourceRevision = sourceRevision
    self.osVersion = osVersion
    self.completion = completion
    self.backendCompletion = backendCompletion

    let boundedIssues = persistenceIssues.prefix(Self.maxPersistenceIssues)
    self.persistenceIssues = boundedIssues.map { String($0.prefix(500)) }
    self.droppedPersistenceIssues = max(0, persistenceIssues.count - boundedIssues.count)

    let boundedRows = cleanupRows.prefix(Self.maxCleanupRows)
    self.cleanupRows = boundedRows.map(PersistedCleanupRow.init)
    self.droppedCleanupRows = max(0, cleanupRows.count - boundedRows.count)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    date = try container.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
    appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? "unknown"
    appBuild = try container.decodeIfPresent(String.self, forKey: .appBuild) ?? "unknown"
    sourceRevision = try container.decodeIfPresent(String.self, forKey: .sourceRevision)
    osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion) ?? "unknown"
    completion = try container.decodeIfPresent(String.self, forKey: .completion) ?? "degraded"
    backendCompletion = try container.decodeIfPresent(String.self, forKey: .backendCompletion)
    persistenceIssues = try container.decodeIfPresent([String].self, forKey: .persistenceIssues) ?? []
    cleanupRows = try container.decodeIfPresent([PersistedCleanupRow].self, forKey: .cleanupRows) ?? []
    droppedCleanupRows = try container.decodeIfPresent(Int.self, forKey: .droppedCleanupRows) ?? 0
    droppedPersistenceIssues =
      try container.decodeIfPresent(Int.self, forKey: .droppedPersistenceIssues) ?? 0
  }

  var isClean: Bool { completion == "clean" }

  /// A one-line summary for the Diagnostics screen and exported reports.
  var summary: String {
    switch completion {
    case "clean":
      return "Last shutdown completed cleanly."
    case "timedOut":
      return "Last shutdown exceeded its bounded cleanup wait and the app exited anyway."
    default:
      let stages = cleanupRows.map(\.stage)
      let stageList = stages.isEmpty ? "no stage detail recorded" : stages.joined(separator: ", ")
      return "Last shutdown was degraded (\(stageList))."
    }
  }
}

extension ShutdownReport {
  /// Builds a report from a termination outcome, stamping the identity a bug
  /// report needs to be actionable: which binary this was, and which OS.
  init(
    outcome: AppTerminationOutcome,
    metadata: DiagnosticsMetadata = .current,
    sourceRevision: String? = BuildIdentity.sourceRevision,
    date: Date = Date()
  ) {
    let completion: String
    let result: AppShutdownResult?
    switch outcome {
    case .clean(let value):
      completion = "clean"
      result = value
    case .degraded(let value):
      completion = "degraded"
      result = value
    case .timedOut:
      completion = "timedOut"
      result = nil
    }

    self.init(
      date: date,
      appVersion: metadata.shortVersion,
      appBuild: metadata.buildVersion,
      sourceRevision: sourceRevision,
      osVersion: metadata.operatingSystemVersion,
      completion: completion,
      backendCompletion: result?.backendResult.map { String(describing: $0.completion) },
      persistenceIssues: result?.persistenceDegradations ?? [],
      cleanupRows: result?.backendResult?.degradations ?? []
    )
  }
}

/// The source revision baked in at package time, so a diagnostic can name the
/// exact commit a binary came from. `nil` for a plain `swift run` build.
///
/// WAV-004's lesson: version and build alone were not enough to tell two
/// binaries apart when a rebuild reused `1.3.0 (6)`.
enum BuildIdentity {
  static var sourceRevision: String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "WavesSourceRevision") as? String
    else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
  }
}

/// Persists the last shutdown's checked-cleanup detail so the next launch — and
/// any bug report — can say exactly which stage failed and with what status.
///
/// Unlike the other stores this one writes **synchronously**. It runs on the
/// termination path, after cleanup has produced its result and before the app
/// replies to `applicationShouldTerminate`; handing the write to a background
/// queue would race the process teardown that is about to happen, which is the
/// exact way the 1.3.0 detail was lost.
final class ShutdownReportStore: @unchecked Sendable {
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Persistence")
  private let engine: JSONPersistenceEngine<ShutdownReport>

  convenience init(fileManager: FileManager = .default) {
    self.init(
      directory: PersistenceLocation.applicationSupportDirectory(fileManager: fileManager)
        .appendingPathComponent("Diagnostics", isDirectory: true),
      fileManager: fileManager,
      writeData: PrivateAtomicPersistenceFile.write
    )
  }

  /// Test-only entry point: keeps the file inside `directory` instead of the
  /// real Application Support location.
  init(
    directory: URL,
    writeData: @escaping PersistenceDataWrite = PrivateAtomicPersistenceFile.write
  ) {
    self.engine = Self.makeEngine(
      directory: directory,
      fileManager: .default,
      writeData: writeData
    )
  }

  private init(
    directory: URL,
    fileManager: FileManager,
    writeData: @escaping PersistenceDataWrite
  ) {
    self.engine = Self.makeEngine(
      directory: directory,
      fileManager: fileManager,
      writeData: writeData
    )
  }

  /// Writes the report, replacing any previous one. Never throws: a failure to
  /// record diagnostics must not block or delay a quit.
  func save(_ report: ShutdownReport) {
    do {
      try engine.writeSynchronously(report)
    } catch {
      logger.error("Failed to persist shutdown report: \(error.localizedDescription)")
    }
  }

  /// Reads the previous shutdown's report, or nil on first launch or if the file
  /// is missing, oversized, or unreadable. A damaged report is discarded rather
  /// than surfaced — it is diagnostics, and must never block startup.
  func load() -> ShutdownReport? {
    guard case .loaded(let report) = engine.load() else { return nil }
    return report
  }

  /// Removes the stored report. Used once its contents have been surfaced, so a
  /// stale degraded shutdown does not keep reappearing after a clean one.
  func clear() {
    engine.clear()
  }

  private static func makeEngine(
    directory: URL,
    fileManager: FileManager,
    writeData: @escaping PersistenceDataWrite
  ) -> JSONPersistenceEngine<ShutdownReport> {
    JSONPersistenceEngine(
      url: directory.appendingPathComponent("last-shutdown.json"),
      queueLabel: "com.waves.shutdown-report.store",
      displayName: "shutdown report",
      maximumFileSize: 256 * 1024,
      fileManager: fileManager,
      writeData: writeData,
      codec: JSONPersistenceCodec(
        encode: { report in
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          encoder.dateEncodingStrategy = .iso8601
          return try PersistedSchema.encode(report, using: encoder)
        },
        decode: { data in
          let decoder = JSONDecoder()
          decoder.dateDecodingStrategy = .iso8601
          return try PersistedSchema.decode(
            ShutdownReport.self,
            from: data,
            using: decoder
          )
        }
      )
    )
  }
}
