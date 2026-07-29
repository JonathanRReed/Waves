import Foundation
import Observation
@preconcurrency import Sparkle

@Observable
@MainActor
final class UpdaterService {
  private let controller: SPUStandardUpdaterController
  @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
  @ObservationIgnored private var automaticChecksObservation: NSKeyValueObservation?
  @ObservationIgnored private var isSynchronizingAutomaticChecks = false

  private(set) var canCheckForUpdates: Bool
  var automaticallyChecksForUpdates: Bool {
    didSet {
      guard !isSynchronizingAutomaticChecks,
            automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates else { return }
      controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  /// Whether there is anything for Sparkle to check.
  ///
  /// Keyed on the appcast URL rather than the bundle identifier: it is the exact
  /// precondition for the updater doing useful work, and it cannot drift from
  /// the packaging script the way a hardcoded bundle id could (`BUNDLE_ID` is
  /// overridable in `script/build_and_run.sh`). A packaged Waves app has
  /// `SUFeedURL`; a test binary or a bare `swift run` build does not.
  ///
  /// This matters because starting the updater without a feed still arms
  /// Sparkle's scheduler, and when a check fires it puts up a modal `NSAlert` on
  /// the main thread that a headless test host can never dismiss —
  /// `PhaseOneContractTests` constructs `WavesApp`, which constructs this
  /// service, so the entire suite could hang indefinitely.
  private static var hasUpdateFeed: Bool {
    guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
      return false
    }
    return !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  init() {
    let controller = SPUStandardUpdaterController(
      startingUpdater: Self.hasUpdateFeed,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    self.controller = controller
    canCheckForUpdates = controller.updater.canCheckForUpdates
    automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

    canCheckObservation = controller.updater.observe(
      \.canCheckForUpdates,
      options: [.initial, .new]
    ) { [weak self] _, change in
      guard let value = change.newValue else { return }
      Task { @MainActor [weak self] in
        self?.canCheckForUpdates = value
      }
    }

    automaticChecksObservation = controller.updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.initial, .new]
    ) { [weak self] _, change in
      guard let value = change.newValue else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        isSynchronizingAutomaticChecks = true
        automaticallyChecksForUpdates = value
        isSynchronizingAutomaticChecks = false
      }
    }
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
