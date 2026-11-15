import Foundation
import WavesAudioCore

/// What the control socket is doing right now, as the app delegate sees it.
struct ControlSocketDiagnostics: Equatable, Sendable {
  let isListening: Bool
  let clientCount: Int
}

/// Automation and background-behavior settings for the diagnostics export.
///
/// Settings and counts only: no app names, bundle identifiers, or paths. A
/// refused shortcut is named by its key chord and action kind, never by the
/// app it targets.
struct DiagnosticsAutomationState: Equatable, Sendable {
  var urlCommandsEnabled: Bool
  var controlSocketEnabled: Bool
  /// Nil when the app delegate has not reported on the socket.
  var controlSocket: ControlSocketDiagnostics?
  var keyboardShortcutsEnabled: Bool
  var assignedShortcutCount: Int
  /// "⌥⌘M (mute-app)" for each binding macOS refused to register.
  var refusedShortcuts: [String]
  var loginItem: LoginItemStatus
  var adaptiveMixMode: AdaptiveMixMode
  var adaptiveFocusMode: AdaptiveFocusMode
}

extension DiagnosticsExportFormatter {
  static let maximumRefusedShortcutRows = 10

  static func appendAutomation(_ state: DiagnosticsAutomationState?, to lines: inout [String]) {
    lines.append("")
    lines.append("Automation")
    guard let state else {
      lines.append("State: notAvailable")
      return
    }
    lines.append("URL commands: \(state.urlCommandsEnabled ? "enabled" : "disabled")")
    lines.append("Control socket: \(controlSocketDescription(state))")
    let refused = state.refusedShortcuts
    lines.append(
      "Global shortcuts: \(state.keyboardShortcutsEnabled ? "enabled" : "disabled"), "
        + "\(max(0, state.assignedShortcutCount)) assigned, \(refused.count) refused by macOS"
    )
    for shortcut in refused.prefix(maximumRefusedShortcutRows) {
      lines.append("  Refused shortcut: \(String(shortcut.prefix(64)))")
    }
    if refused.count > maximumRefusedShortcutRows {
      lines.append("  Refused shortcut rows omitted by bound: \(refused.count - maximumRefusedShortcutRows)")
    }
    let login = state.loginItem
    lines.append(
      "Open at login: \(String(login.statusDescription.prefix(64)))"
        + (login.requiresApproval ? " (waiting for approval in System Settings)" : "")
    )
    lines.append(
      "Adaptive Mix: \(state.adaptiveMixMode.rawValue), focus \(state.adaptiveFocusMode.rawValue)"
    )
  }

  private static func controlSocketDescription(_ state: DiagnosticsAutomationState) -> String {
    guard state.controlSocketEnabled else { return "disabled" }
    guard let socket = state.controlSocket else { return "enabled, listener state unknown" }
    guard socket.isListening else { return "enabled, not listening" }
    let clients = max(0, socket.clientCount)
    return "enabled, listening, \(clients) \(clients == 1 ? "client" : "clients") connected"
  }
}
