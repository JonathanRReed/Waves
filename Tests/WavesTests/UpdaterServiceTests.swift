import Foundation
import Testing

@testable import Waves

@MainActor
@Test func updaterStartPolicyFollowsFeedConsentAndUnavailableChecksAreSurfaced() {
  let driver = FakeUpdaterDriver(canCheckForUpdates: false)
  var observedStartPolicy: Bool?
  let service = UpdaterService(hasUpdateFeed: false) { shouldStart in
    observedStartPolicy = shouldStart
    return driver
  }

  #expect(observedStartPolicy == false)
  #expect(!service.canCheckForUpdates)
  service.checkForUpdates()
  #expect(driver.checkCount == 0)
  #expect(service.lastCheckStatus == .unavailable)
}

@MainActor
@Test func updaterExplicitCheckDispatchesOnlyToInjectedDriver() {
  let driver = FakeUpdaterDriver(canCheckForUpdates: true)
  var observedStartPolicy: Bool?
  let service = UpdaterService(hasUpdateFeed: true) { shouldStart in
    observedStartPolicy = shouldStart
    return driver
  }

  service.checkForUpdates()
  #expect(observedStartPolicy == true)
  #expect(driver.checkCount == 1)
  #expect(service.lastCheckStatus == .dispatched)
}

@MainActor
@Test func updaterAvailabilityAndAutomaticPreferenceSynchronizeBothDirections() {
  let driver = FakeUpdaterDriver(canCheckForUpdates: false, automaticallyChecksForUpdates: false)
  let service = UpdaterService(hasUpdateFeed: true) { _ in driver }

  driver.publishCanCheck(true)
  #expect(service.canCheckForUpdates)

  service.automaticallyChecksForUpdates = true
  #expect(driver.automaticallyChecksForUpdates)
  #expect(driver.automaticWriteCount == 1)

  driver.publishAutomaticChecks(false)
  #expect(!service.automaticallyChecksForUpdates)
  #expect(driver.automaticWriteCount == 1, "driver-originated synchronization must not echo back")
}

@MainActor
@Test func updaterDriverFailureIsSurfacedWithoutAProductionFeed() {
  let driver = FakeUpdaterDriver(canCheckForUpdates: true)
  driver.checkError = FakeUpdaterError.failed
  let service = UpdaterService(hasUpdateFeed: true) { _ in driver }

  service.checkForUpdates()
  #expect(driver.checkCount == 1)
  #expect(service.lastCheckStatus == .failed("failed"))
}

private enum FakeUpdaterError: LocalizedError {
  case failed

  var errorDescription: String? { "failed" }
}

@MainActor
private final class FakeUpdaterDriver: UpdaterDriving {
  var canCheckForUpdates: Bool
  var automaticallyChecksForUpdates: Bool {
    didSet { automaticWriteCount += 1 }
  }
  var onCanCheckForUpdatesChanged: ((Bool) -> Void)?
  var onAutomaticallyChecksForUpdatesChanged: ((Bool) -> Void)?
  var checkCount = 0
  var automaticWriteCount = 0
  var checkError: Error?

  init(canCheckForUpdates: Bool, automaticallyChecksForUpdates: Bool = false) {
    self.canCheckForUpdates = canCheckForUpdates
    self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
  }

  func checkForUpdates() throws {
    checkCount += 1
    if let checkError { throw checkError }
  }

  func publishCanCheck(_ value: Bool) {
    canCheckForUpdates = value
    onCanCheckForUpdatesChanged?(value)
  }

  func publishAutomaticChecks(_ value: Bool) {
    automaticallyChecksForUpdates = value
    automaticWriteCount -= 1
    onAutomaticallyChecksForUpdatesChanged?(value)
  }
}
