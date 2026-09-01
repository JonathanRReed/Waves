import Foundation
import WavesAudioCore

struct DiagnosticsMetadata: Equatable {
  let shortVersion: String
  let buildVersion: String
  /// The commit the running binary was built from, when the packaging script
  /// stamped one. Version and build alone could not tell two binaries apart
  /// once a rebuild reused 1.3.0 (6).
  let sourceRevision: String?
  let operatingSystemVersion: String

  init(bundleInfo: [String: Any], operatingSystemVersion: String) {
    self.shortVersion = Self.normalized(
      bundleInfo["CFBundleShortVersionString"],
      fallback: "development"
    )
    self.buildVersion = Self.normalized(
      bundleInfo["CFBundleVersion"],
      fallback: "development"
    )
    self.sourceRevision = (bundleInfo["WavesSourceRevision"] as? String)
      .map { Self.normalized($0, fallback: "unknown") }
    self.operatingSystemVersion = Self.normalized(
      operatingSystemVersion,
      fallback: "unknown"
    )
  }

  static var current: DiagnosticsMetadata {
    DiagnosticsMetadata(
      bundleInfo: Bundle.main.infoDictionary ?? [:],
      operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )
  }

  private static func normalized(_ value: Any?, fallback: String) -> String {
    guard let value = value as? String else { return fallback }
    return normalized(value, fallback: fallback)
  }

  private static func normalized(_ value: String, fallback: String) -> String {
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return normalized.isEmpty ? fallback : String(normalized.prefix(128))
  }
}

enum DiagnosticsExportFormatter {
  static let maximumAppRows = 50
  static let maximumCheckRows = 20
  static let maximumCleanupRows = 10
  static let maximumReportCharacters = 65_536

  static func captureAuthorizationDescription(
    _ result: CaptureAuthorizationResult?
  ) -> String {
    guard let result else {
      return "undetermined (no live authorization probe result retained in this process)"
    }
    switch result {
    case .authorized:
      return "authorized"
    case .notGranted:
      return "notGranted"
    case .undetermined:
      return "undetermined"
    case .unsupported:
      return "unsupported"
    case .probeFailed(let nativeStatus):
      return "probeFailed (native status: \(nativeStatus))"
    }
  }

  static func format(
    metadata: DiagnosticsMetadata,
    captureAuthorization: CaptureAuthorizationResult?,
    session: AudioSessionSnapshot,
    apps: [AudioApp],
    availableOutputDeviceCount: Int,
    diagnostics: DiagnosticsReport?,
    waveLinkBridge: WaveLinkBridgeStatus? = nil,
    persistenceFailureCount: Int,
    lastPersistenceError: String?,
    shutdownResult: AppShutdownResult?,
    previousShutdown: ShutdownReport? = nil
  ) -> String {
    var lines: [String] = [
      "Waves diagnostics",
      "Waves version (CFBundleShortVersionString): \(metadata.shortVersion)",
      "Waves build (CFBundleVersion): \(metadata.buildVersion)",
      "Waves source revision (WavesSourceRevision): \(boundedOptional(metadata.sourceRevision, maximumLength: 64))",
      "macOS: \(metadata.operatingSystemVersion)",
      "Privacy note: Fields marked below may include app names, identifiers, device names, route states, or error text. This report contains no audio samples.",
      "",
      "Capture authorization",
      "Structured state: \(captureAuthorizationDescription(captureAuthorization))",
      "",
      "Output device",
      "Query/readiness state: \(session.currentDevice == nil ? "notReady" : "ready")",
      "Last enumerated output-device count: \(max(0, availableOutputDeviceCount))",
    ]

    if let device = session.currentDevice {
      lines.append("Current output device name [device name]: \(bounded(device.name, maximumLength: 256))")
      lines.append("Current output device identifier [identifier]: \(bounded(device.id, maximumLength: 256))")
      lines.append("Current output device kind: \(device.kind.rawValue)")
      lines.append("Managed-route readiness: \(device.isManagedRouteAvailable ? "ready" : "notReady")")
      lines.append("Volume-control mode: \(device.volumeControlMode.rawValue)")
    } else {
      lines.append("Current output device name [device name]: not available")
      lines.append("Current output device identifier [identifier]: not available")
      lines.append("Managed-route readiness: notReady")
    }

    let status = session.backendStatus
    lines.append("")
    lines.append("Backend and route state")
    lines.append("Audio component installed: \(status.isAudioComponentInstalled)")
    lines.append("Capture permission ready: \(status.hasRequiredPermissions)")
    lines.append("Route recovery healthy: \(status.isRouteRecoveryHealthy)")
    lines.append("Backend/route/format error [error text]: \(boundedOptional(status.lastError, maximumLength: 1_000))")

    lines.append("")
    lines.append("Persistence")
    lines.append("Failure count this process: \(max(0, persistenceFailureCount))")
    lines.append("Last failure [error text]: \(boundedOptional(lastPersistenceError, maximumLength: 1_000))")

    appendWaveLinkBridge(waveLinkBridge, to: &lines)
    appendShutdown(shutdownResult, to: &lines)
    appendPreviousShutdown(previousShutdown, to: &lines)
    appendApps(apps, to: &lines)
    appendChecks(diagnostics, to: &lines)

    return boundedReport(lines)
  }

  /// What the Wave Link control bridge last saw. Channel names and app
  /// identifiers come from Wave Link's own listing, so they are labeled like
  /// the app rows above.
  static let maximumWaveLinkChannelRows = 16

  private static func appendWaveLinkBridge(
    _ bridge: WaveLinkBridgeStatus?,
    to lines: inout [String]
  ) {
    lines.append("")
    lines.append("Wave Link bridge")
    guard let bridge else {
      lines.append("State: notAvailable (no bridge in this backend)")
      return
    }
    lines.append("State: \(bridge.phase.rawValue)")
    lines.append("Endpoint [identifier]: \(boundedOptional(bridge.endpoint, maximumLength: 64))")
    lines.append("Peer process identifier: \(bridge.processIdentifier.map(String.init) ?? "not available")")
    lines.append("Application [app name]: \(boundedOptional(bridge.applicationName, maximumLength: 128))")
    lines.append("Application version: \(boundedOptional(bridge.applicationVersion, maximumLength: 64))")
    lines.append("Interface revision: \(bridge.interfaceRevision.map(String.init) ?? "not available")")
    lines.append("Last success: \(bridge.lastSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
    lines.append("Last failure: \(bridge.lastFailureAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
    lines.append("Last error [error text]: \(boundedOptional(bridge.lastError, maximumLength: 1_000))")
    lines.append("Software channels: \(bridge.softwareChannelCount) (\(bridge.freeSoftwareChannelCount) free)")
    for channel in bridge.channels.prefix(maximumWaveLinkChannelRows) {
      let apps = channel.appIdentifiers.isEmpty ? "empty" : channel.appIdentifiers.joined(separator: ", ")
      lines.append(
        "  Channel [channel name]: \(bounded(channel.name, maximumLength: 128)) · \(channel.isSoftware ? "software" : "hardware") · level \(String(format: "%.2f", channel.level)) · \(channel.isMuted ? "muted" : "unmuted") · apps [identifier]: \(bounded(apps, maximumLength: 512))"
      )
    }
    if bridge.channels.count > maximumWaveLinkChannelRows {
      lines.append("  Channel rows omitted by bound: \(bridge.channels.count - maximumWaveLinkChannelRows)")
    }
  }

  /// The *previous* launch's checked shutdown, read back from disk.
  ///
  /// The section above can only describe a shutdown that happened inside this
  /// process, so it reads `notAvailable` in every live export — which is exactly
  /// why the 1.3.0 degraded cleanup left nothing to investigate. This section is
  /// the durable one.
  private static func appendPreviousShutdown(
    _ report: ShutdownReport?,
    to lines: inout [String]
  ) {
    lines.append("")
    lines.append("Previous launch's shutdown (persisted)")
    guard let report else {
      lines.append("Result: notRecorded (no previous shutdown report on disk)")
      return
    }

    lines.append("Result: \(bounded(report.completion, maximumLength: 64))")
    lines.append("Recorded: \(ISO8601DateFormatter().string(from: report.date))")
    lines.append("Recorded by version: \(bounded(report.appVersion, maximumLength: 64)) (\(bounded(report.appBuild, maximumLength: 64)))")
    lines.append("Recorded by source revision: \(boundedOptional(report.sourceRevision, maximumLength: 64))")
    lines.append("Recorded on macOS: \(bounded(report.osVersion, maximumLength: 128))")
    lines.append("Backend cleanup result: \(boundedOptional(report.backendCompletion, maximumLength: 64))")
    lines.append("Persistence issue count: \(report.persistenceIssues.count)")
    for issue in report.persistenceIssues.prefix(maximumCleanupRows) {
      lines.append("  Previous persistence issue [error text]: \(bounded(issue, maximumLength: 1_000))")
    }
    if report.droppedPersistenceIssues > 0 {
      lines.append("Persistence issues omitted by bound: \(report.droppedPersistenceIssues)")
    }
    lines.append("Cleanup degradation count: \(report.cleanupRows.count)")
    for (index, row) in report.cleanupRows.prefix(maximumCleanupRows).enumerated() {
      lines.append("  Cleanup \(index + 1) stage: \(bounded(row.stage, maximumLength: 64))")
      if let appID = row.appID {
        lines.append("    App identifier [identifier]: \(bounded(appID, maximumLength: 256))")
      }
      if let nativeStatus = row.nativeStatus {
        lines.append("    Native status: \(nativeStatus)")
      }
      if let detail = row.detail {
        lines.append("    Cleanup detail [error text]: \(bounded(detail, maximumLength: 1_000))")
      }
    }
    if report.cleanupRows.count > maximumCleanupRows {
      lines.append("  Cleanup rows omitted by bound: \(report.cleanupRows.count - maximumCleanupRows)")
    }
    if report.droppedCleanupRows > 0 {
      lines.append("  Cleanup rows dropped when recorded: \(report.droppedCleanupRows)")
    }
  }

  private static func appendShutdown(
    _ shutdownResult: AppShutdownResult?,
    to lines: inout [String]
  ) {
    lines.append("")
    lines.append("Checked shutdown and cleanup")
    guard let shutdownResult else {
      lines.append("Result: notAvailable (checked shutdown has not completed in this process)")
      return
    }

    lines.append("Result: \(shutdownCompletionDescription(shutdownResult.completion))")
    lines.append("Shutdown persistence degradation count: \(shutdownResult.persistenceDegradations.count)")
    if let lastPersistenceDegradation = shutdownResult.persistenceDegradations.last {
      lines.append(
        "Last shutdown persistence degradation [error text]: \(bounded(lastPersistenceDegradation, maximumLength: 1_000))"
      )
    }

    guard let backendResult = shutdownResult.backendResult else {
      lines.append("Backend cleanup result: notRun")
      return
    }

    lines.append("Backend cleanup result: \(backendShutdownDescription(backendResult.completion))")
    lines.append("Backend cleanup degradation count: \(backendResult.degradations.count)")
    let shown = Array(backendResult.degradations.prefix(maximumCleanupRows))
    for (index, degradation) in shown.enumerated() {
      lines.append("  Cleanup \(index + 1) stage: \(cleanupStageDescription(degradation.stage))")
      if let appID = degradation.appID {
        lines.append("    App identifier [identifier]: \(bounded(appID, maximumLength: 256))")
      }
      if let nativeStatus = degradation.nativeStatus {
        lines.append("    Native status: \(nativeStatus)")
      }
      if let detail = degradation.detail {
        lines.append("    Cleanup detail [error text]: \(bounded(detail, maximumLength: 1_000))")
      }
    }
    if backendResult.degradations.count > shown.count {
      lines.append("  Cleanup rows omitted by bound: \(backendResult.degradations.count - shown.count)")
    }
  }

  private static func appendApps(
    _ apps: [AudioApp],
    to lines: inout [String]
  ) {
    let sortedApps = apps.sorted { lhs, rhs in
      if lhs.logicalID != rhs.logicalID { return lhs.logicalID < rhs.logicalID }
      if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
      return lhs.id < rhs.id
    }
    let shown = Array(sortedApps.prefix(maximumAppRows))

    lines.append("")
    lines.append("Apps (total: \(apps.count), shown: \(shown.count))")
    for app in shown {
      lines.append("  App name [app name]: \(bounded(app.displayName, maximumLength: 256))")
      lines.append("    App identifier [identifier]: \(bounded(app.logicalID, maximumLength: 256))")
      lines.append("    Route state [route state]: \(app.routingState.rawValue)")
      lines.append("    Desired volume: \(Int(max(0, min(1, app.desiredVolume)) * 100))%")
      lines.append("    Muted: \(app.isMuted)")
      lines.append("    Boost: \(formattedBoost(app.volumeBoost))x")
      lines.append(
        "    Target output device identifier [identifier]: \(boundedOptional(app.targetDeviceUID, maximumLength: 256))"
      )
      if let notes = app.notes {
        lines.append("    App route/backend error [error text]: \(bounded(notes, maximumLength: 1_000))")
      }
    }
    if apps.count > shown.count {
      lines.append("  App rows omitted by bound: \(apps.count - shown.count)")
    }
  }

  private static func appendChecks(
    _ diagnostics: DiagnosticsReport?,
    to lines: inout [String]
  ) {
    lines.append("")
    lines.append("Diagnostic checks")
    guard let diagnostics else {
      lines.append("Summary [may include route state or error text]: not loaded")
      return
    }

    lines.append(
      "Summary [may include route state or error text]: \(bounded(diagnostics.summary, maximumLength: 1_000))"
    )
    let shown = Array(diagnostics.checks.prefix(maximumCheckRows))
    lines.append("Checks (total: \(diagnostics.checks.count), shown: \(shown.count))")
    for check in shown {
      lines.append("  [\(check.status.rawValue)] \(bounded(check.title, maximumLength: 256))")
      lines.append(
        "    Detail [may include route state or error text]: \(bounded(check.detail, maximumLength: 1_000))"
      )
    }
    if diagnostics.checks.count > shown.count {
      lines.append("  Check rows omitted by bound: \(diagnostics.checks.count - shown.count)")
    }
  }

  private static func boundedOptional(
    _ value: String?,
    maximumLength: Int
  ) -> String {
    guard let value else { return "none" }
    return bounded(value, maximumLength: maximumLength)
  }

  private static func bounded(_ value: String, maximumLength: Int) -> String {
    let singleLine = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !singleLine.isEmpty else { return "empty" }
    return String(singleLine.prefix(maximumLength))
  }

  private static func formattedBoost(_ boost: Float) -> String {
    guard boost.isFinite else { return "1" }
    return String(format: "%.3g", locale: Locale(identifier: "en_US_POSIX"), Double(max(1, boost)))
  }

  private static func boundedReport(_ lines: [String]) -> String {
    let truncationMarker = "[Report truncated at \(maximumReportCharacters) characters.]"
    let contentLimit = maximumReportCharacters - truncationMarker.count - 1
    var report = ""

    for line in lines {
      let candidate = report.isEmpty ? line : "\n\(line)"
      guard report.count + candidate.count <= contentLimit else {
        if !report.isEmpty { report.append("\n") }
        report.append(truncationMarker)
        return report
      }
      report.append(candidate)
    }
    return report
  }

  private static func shutdownCompletionDescription(
    _ completion: AppShutdownCompletion
  ) -> String {
    switch completion {
    case .clean: "clean"
    case .degraded: "degraded"
    }
  }

  private static func backendShutdownDescription(
    _ completion: BackendShutdownCompletion
  ) -> String {
    switch completion {
    case .clean: "clean"
    case .degraded: "degraded"
    case .timedOut: "timedOut"
    case .unverified: "unverified"
    }
  }

  private static func cleanupStageDescription(_ stage: CleanupStage) -> String {
    // One source of truth with the persisted shutdown report, so an exported
    // diagnostic and a stored `last-shutdown.json` name the same stage the
    // same way.
    stage.name
  }
}
