import Foundation

// The isolated sanitizer graph omits WavesApp.swift so its SwiftUI @main does
// not collide with the harness executable. These value-only declarations are
// the compile-time seams that other production files normally receive from
// WavesApp.swift. The state, persistence, control, and audio sources exercised
// by the harness are copied without modification.
enum WavesURLPolicy {
  static let maxPayloadBytes = 8 * 1_024

  static func parse(_ value: String) -> URL? {
    guard value.utf8.count <= maxPayloadBytes else { return nil }
    return URL(string: value)
  }
}

enum AppTerminationOutcome: Hashable, Sendable {
  case clean(AppShutdownResult)
  case degraded(AppShutdownResult)
  case timedOut
}

enum AppSceneID {
  static let mainWindow = "main-window"
  static let aboutWindow = "about-window"
}
