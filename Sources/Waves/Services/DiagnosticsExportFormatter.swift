import Foundation
import WavesAudioCore

struct DiagnosticsMetadata: Equatable {
  let shortVersion: String
  let buildVersion: String
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
    persistenceFailureCount: Int,
    lastPersistenceError: String?,
    shutdownResult: AppShutdownResult?
  ) -> String {
    var lines: [String] = [
      "Waves diagnostics",
      "Waves version (CFBundleShortVersionString): \(metadata.shortVersion)",
      "Waves build (CFBundleVersion): \(metadata.buildVersion)",
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

    appendShutdown(shutdownResult, to: &lines)
    appendApps(apps, to: &lines)
    appendChecks(diagnostics, to: &lines)

    return boundedReport(lines)
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
    switch stage {
    case .authorizationProbe: "authorizationProbe"
    case .listenerRemoval: "listenerRemoval"
    case .ioProcStop: "ioProcStop"
    case .ioProcDestroy: "ioProcDestroy"
    case .aggregateDeviceDestroy: "aggregateDeviceDestroy"
    case .processTapDestroy: "processTapDestroy"
    case .controllerDisposal: "controllerDisposal"
    }
  }
}
