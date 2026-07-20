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

  init() {
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
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
