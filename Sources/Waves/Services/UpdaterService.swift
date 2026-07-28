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

  /// True only in a real packaged Waves bundle.
  ///
  /// Sparkle has nothing to update in a test binary, but starting its updater
  /// there still arms the scheduler — and when a check fires it puts up a modal
  /// `NSAlert` on the main thread, which in a headless test host nobody can
  /// dismiss. That deadlocks the entire run: `PhaseOneContractTests` constructs
  /// `WavesApp`, which constructs this service, so the whole suite could hang
  /// indefinitely once enough time had passed since the last check.
  private static var isRunningInRealAppBundle: Bool {
    Bundle.main.bundleIdentifier == "com.jonathanreed.Waves"
  }

  init() {
    let controller = SPUStandardUpdaterController(
      startingUpdater: Self.isRunningInRealAppBundle,
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
