import AppKit
import Foundation

/// The pre-filled GitHub issue behind Report a Problem.
///
/// The URL carries only the Waves and macOS versions. Diagnostics go to the
/// clipboard instead, so the user reviews them before anything leaves the Mac,
/// and nothing is sent until they submit the issue themselves.
enum ProblemReport {
  static let newIssueURL = URL(string: "https://github.com/JonathanRReed/Waves/issues/new")!

  /// One line of UI text saying what the action does and does not do.
  static let explanation =
    "Copies your diagnostics and opens a new GitHub issue in your browser. Nothing is sent until you submit it."

  static func body(metadata: DiagnosticsMetadata) -> String {
    """
    ### What happened?


    ### What did you expect?


    ### Diagnostics
    Waves copied its diagnostics to your clipboard. Review them, then paste them here.

    Waves \(metadata.shortVersion) (\(metadata.buildVersion)), macOS \(metadata.operatingSystemVersion)
    """
  }

  static func issueURL(metadata: DiagnosticsMetadata) -> URL {
    var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "body", value: body(metadata: metadata))]
    return components.url ?? newIssueURL
  }
}

extension AppStore {
  /// Copies the same diagnostics as Copy Diagnostics, then opens a new issue.
  func reportProblem(
    metadata: DiagnosticsMetadata = .current,
    pasteboard: NSPasteboard = .general,
    openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
  ) {
    pasteboard.clearContents()
    pasteboard.setString(diagnosticsExportText, forType: .string)
    if openURL(ProblemReport.issueURL(metadata: metadata)) {
      showToast(
        title: "Diagnostics copied",
        detail: "Paste them into the new issue.",
        kind: .success,
        duration: .seconds(3)
      )
    } else {
      showToast(
        title: "Could not open GitHub",
        detail: "Your diagnostics are on the clipboard. Report the problem at github.com/JonathanRReed/Waves/issues.",
        kind: .warning,
        duration: .seconds(6)
      )
    }
  }
}
