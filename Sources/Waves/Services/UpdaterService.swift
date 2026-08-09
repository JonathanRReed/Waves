import Foundation
import Observation
@preconcurrency import Sparkle

@MainActor
protocol UpdaterDriving: AnyObject {
  var canCheckForUpdates: Bool { get }
  var automaticallyChecksForUpdates: Bool { get set }
  var onCanCheckForUpdatesChanged: ((Bool) -> Void)? { get set }
  var onAutomaticallyChecksForUpdatesChanged: ((Bool) -> Void)? { get set }
  func checkForUpdates() throws
}

@MainActor
private final class SparkleUpdaterDriver: UpdaterDriving {
  private let controller: SPUStandardUpdaterController
  private var canCheckObservation: NSKeyValueObservation?
  private var automaticChecksObservation: NSKeyValueObservation?

  var onCanCheckForUpdatesChanged: ((Bool) -> Void)?
  var onAutomaticallyChecksForUpdatesChanged: ((Bool) -> Void)?

  var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
  var automaticallyChecksForUpdates: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }

  init(startingUpdater: Bool) {
    controller = SPUStandardUpdaterController(
      startingUpdater: startingUpdater,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    canCheckObservation = controller.updater.observe(
      \.canCheckForUpdates,
      options: [.new]
    ) { [weak self] _, change in
      guard let value = change.newValue else { return }
      Task { @MainActor [weak self] in self?.onCanCheckForUpdatesChanged?(value) }
    }
    automaticChecksObservation = controller.updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.new]
    ) { [weak self] _, change in
      guard let value = change.newValue else { return }
      Task { @MainActor [weak self] in self?.onAutomaticallyChecksForUpdatesChanged?(value) }
    }
  }

  func checkForUpdates() throws {
    controller.checkForUpdates(nil)
  }
}

@Observable
@MainActor
final class UpdaterService {
  enum CheckStatus: Equatable {
    case idle
    case dispatched
    case unavailable
    case failed(String)
  }

  @ObservationIgnored private let driver: any UpdaterDriving
  @ObservationIgnored private var isSynchronizingAutomaticChecks = false

  private(set) var canCheckForUpdates: Bool
  private(set) var lastCheckStatus: CheckStatus = .idle
  var automaticallyChecksForUpdates: Bool {
    didSet {
      guard !isSynchronizingAutomaticChecks,
        automaticallyChecksForUpdates != driver.automaticallyChecksForUpdates
      else { return }
      driver.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  private static var hasUpdateFeed: Bool {
    guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
      return false
    }
    return !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  convenience init() {
    self.init(hasUpdateFeed: Self.hasUpdateFeed) { shouldStart in
      SparkleUpdaterDriver(startingUpdater: shouldStart)
    }
  }

  init(
    hasUpdateFeed: Bool,
    driverFactory: (Bool) -> any UpdaterDriving
  ) {
    let driver = driverFactory(hasUpdateFeed)
    self.driver = driver
    canCheckForUpdates = driver.canCheckForUpdates
    automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates

    driver.onCanCheckForUpdatesChanged = { [weak self] value in
      self?.canCheckForUpdates = value
      if value, self?.lastCheckStatus == .unavailable {
        self?.lastCheckStatus = .idle
      }
    }
    driver.onAutomaticallyChecksForUpdatesChanged = { [weak self] value in
      guard let self else { return }
      isSynchronizingAutomaticChecks = true
      automaticallyChecksForUpdates = value
      isSynchronizingAutomaticChecks = false
    }
  }

  func checkForUpdates() {
    guard canCheckForUpdates else {
      lastCheckStatus = .unavailable
      return
    }
    do {
      try driver.checkForUpdates()
      lastCheckStatus = .dispatched
    } catch {
      lastCheckStatus = .failed(error.localizedDescription)
    }
  }
}
