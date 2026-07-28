import Foundation
import Testing
import WavesAudioCore

@testable import Waves

// Regression coverage for WAV-003 / WAV-007. The 1.3.0 incident ended with
// "backend status … degraded" and nothing else: the CleanupDegradation rows
// naming the failing stage and its OSStatus lived only in memory and died with
// the process, and the unified-log entries that might have hinted at them had
// aged out before anyone looked. These tests pin that the detail now survives.

private func makeTemporaryDirectory() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-shutdown-report-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func degradedOutcome(
  cleanupRows: [CleanupDegradation],
  persistenceIssues: [String] = []
) -> AppTerminationOutcome {
  let result = AppShutdownResult(
    persistenceDegradations: persistenceIssues,
    backendResult: BackendShutdownResult(checkedDegradations: cleanupRows)
  )
  return result.completion == .clean ? .clean(result) : .degraded(result)
}

@Test func degradedShutdownPersistsEveryCleanupRowWithStageAndStatus() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)

  let outcome = degradedOutcome(
    cleanupRows: [
      CleanupDegradation(
        appID: "com.example.one",
        stage: .processTapDestroy,
        nativeStatus: 560_947_818,
        detail: "tap destroy returned !obj"
      ),
      CleanupDegradation(
        stage: .aggregateDeviceDestroy,
        nativeStatus: -50,
        detail: "aggregate destroy failed"
      ),
    ],
    persistenceIssues: ["preferences write failed"]
  )
  store.save(ShutdownReport(outcome: outcome))

  let loaded = try #require(store.load())
  #expect(loaded.completion == "degraded")
  #expect(loaded.isClean == false)
  #expect(loaded.backendCompletion == "degraded")
  #expect(loaded.persistenceIssues == ["preferences write failed"])
  #expect(loaded.cleanupRows.count == 2)

  // The exact stage and native status are what make a degraded shutdown
  // actionable — the 1.3.0 report could name neither.
  #expect(loaded.cleanupRows[0].stage == "processTapDestroy")
  #expect(loaded.cleanupRows[0].nativeStatus == 560_947_818)
  #expect(loaded.cleanupRows[0].appID == "com.example.one")
  #expect(loaded.cleanupRows[0].detail == "tap destroy returned !obj")
  #expect(loaded.cleanupRows[1].stage == "aggregateDeviceDestroy")
  #expect(loaded.cleanupRows[1].nativeStatus == -50)
  #expect(loaded.cleanupRows[1].appID == nil)

  #expect(loaded.droppedCleanupRows == 0)
  #expect(loaded.droppedPersistenceIssues == 0)
}

@Test func cleanShutdownIsRecordedWithNoRows() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)

  store.save(ShutdownReport(outcome: degradedOutcome(cleanupRows: [])))

  let loaded = try #require(store.load())
  #expect(loaded.completion == "clean")
  #expect(loaded.isClean)
  #expect(loaded.cleanupRows.isEmpty)
  #expect(loaded.backendCompletion == "clean")
  #expect(loaded.summary == "Last shutdown completed cleanly.")
}

@Test func timedOutShutdownIsDistinguishedFromDegraded() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)

  store.save(ShutdownReport(outcome: .timedOut))

  let loaded = try #require(store.load())
  #expect(loaded.completion == "timedOut")
  #expect(loaded.isClean == false)
  // A timeout has no backend result at all — it never got one.
  #expect(loaded.backendCompletion == nil)
  #expect(loaded.summary.contains("bounded cleanup wait"))
}

@Test func reportIsBoundedSoAQuitCannotWriteAnUnboundedFile() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)

  let manyRows = (0..<200).map { index in
    CleanupDegradation(
      appID: "com.example.app\(index)",
      stage: .controllerDisposal,
      nativeStatus: Int32(index),
      detail: String(repeating: "x", count: 5_000)
    )
  }
  let manyIssues = (0..<100).map { "persistence failure \($0)" }
  store.save(ShutdownReport(outcome: degradedOutcome(
    cleanupRows: manyRows,
    persistenceIssues: manyIssues
  )))

  let loaded = try #require(store.load())
  #expect(loaded.cleanupRows.count == ShutdownReport.maxCleanupRows)
  #expect(loaded.persistenceIssues.count == ShutdownReport.maxPersistenceIssues)
  // Truncation must be visible, so a bounded report never reads as complete.
  #expect(loaded.droppedCleanupRows == 200 - ShutdownReport.maxCleanupRows)
  #expect(loaded.droppedPersistenceIssues == 100 - ShutdownReport.maxPersistenceIssues)
  // CleanupDegradation itself bounds detail text at 1000 characters.
  #expect((loaded.cleanupRows.first?.detail?.count ?? 0) <= 1_000)
}

@Test func savingReplacesThePreviousReportRatherThanAccumulating() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)

  store.save(ShutdownReport(outcome: degradedOutcome(cleanupRows: [
    CleanupDegradation(stage: .ioProcStop, nativeStatus: -1)
  ])))
  store.save(ShutdownReport(outcome: degradedOutcome(cleanupRows: [])))

  // A clean quit after a degraded one must not leave the old failure on disk to
  // be re-reported forever.
  let loaded = try #require(store.load())
  #expect(loaded.isClean)
  #expect(loaded.cleanupRows.isEmpty)
}

@Test func missingAndDamagedReportsAreTreatedAsAbsent() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)

  // First launch: nothing recorded yet.
  #expect(store.load() == nil)

  // A damaged file is diagnostics, not user data — discard it rather than let
  // it throw on the startup path.
  try Data("{ not json".utf8)
    .write(to: directory.appendingPathComponent("last-shutdown.json"))
  #expect(store.load() == nil)

  store.clear()
  #expect(store.load() == nil)
}

@Test func persistedShutdownAppearsInTheDiagnosticsExport() throws {
  let directory = makeTemporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = ShutdownReportStore(directory: directory)
  store.save(ShutdownReport(outcome: degradedOutcome(cleanupRows: [
    CleanupDegradation(
      appID: "com.example.reported",
      stage: .ioProcDestroy,
      nativeStatus: -66_748,
      detail: "IOProc destroy failed"
    )
  ])))
  let report = try #require(store.load())

  let text = DiagnosticsExportFormatter.format(
    metadata: DiagnosticsMetadata(
      bundleInfo: ["CFBundleShortVersionString": "1.3.1", "CFBundleVersion": "7"],
      operatingSystemVersion: "Version 27.0"
    ),
    captureAuthorization: .authorized,
    session: .empty,
    apps: [],
    availableOutputDeviceCount: 0,
    diagnostics: nil,
    persistenceFailureCount: 0,
    lastPersistenceError: nil,
    shutdownResult: nil,
    previousShutdown: report
  )

  #expect(text.contains("Previous launch's shutdown (persisted)"))
  #expect(text.contains("ioProcDestroy"))
  #expect(text.contains("-66748"))
  #expect(text.contains("com.example.reported"))
  #expect(text.contains("IOProc destroy failed"))
}

@Test func diagnosticsExportSaysSoWhenNoShutdownWasRecorded() {
  let text = DiagnosticsExportFormatter.format(
    metadata: DiagnosticsMetadata(
      bundleInfo: [:],
      operatingSystemVersion: "Version 27.0"
    ),
    captureAuthorization: nil,
    session: .empty,
    apps: [],
    availableOutputDeviceCount: 0,
    diagnostics: nil,
    persistenceFailureCount: 0,
    lastPersistenceError: nil,
    shutdownResult: nil,
    previousShutdown: nil
  )

  #expect(text.contains("Result: notRecorded (no previous shutdown report on disk)"))
}

@Test func everyCleanupStageHasAStableDistinctName() {
  // These strings are a wire format: an older build's stored report is read by a
  // newer one, and bug reports quote them.
  let names = [
    CleanupStage.authorizationProbe,
    .listenerRemoval,
    .ioProcStop,
    .ioProcDestroy,
    .aggregateDeviceDestroy,
    .processTapDestroy,
    .controllerDisposal,
  ].map(\.name)

  #expect(Set(names).count == names.count)
  #expect(names.allSatisfy { !$0.isEmpty })
  #expect(names.contains("processTapDestroy"))
  #expect(names.contains("aggregateDeviceDestroy"))
}
