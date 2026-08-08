import Foundation

/// Orders URL automation checks so disabled automation cannot cause parsing,
/// setup presentation, activation, or a store mutation.
@MainActor
struct URLAutomationRouter {
  let isEnabled: () -> Bool
  let isAudioRunning: () -> Bool
  let parse: (String) -> URL?
  let promptForSetup: () -> Void
  let presentSetup: () -> Void
  let perform: (URL) -> Void

  func handle(rawURLString: String) {
    guard isEnabled() else { return }
    guard let url = parse(rawURLString), url.scheme == "waves" else { return }
    guard isAudioRunning() else {
      promptForSetup()
      presentSetup()
      return
    }
    perform(url)
  }
}
