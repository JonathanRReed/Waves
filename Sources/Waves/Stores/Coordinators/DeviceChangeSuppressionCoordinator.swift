import Foundation

struct DeviceChangeSuppressionLifecycleSnapshot: Equatable, Sendable {
  let hasPendingDevice: Bool
  let trackedTaskCount: Int

  static let idle = DeviceChangeSuppressionLifecycleSnapshot(
    hasPendingDevice: false,
    trackedTaskCount: 0
  )
}

/// Owns the one-shot duplicate-toast suppression created by a manual output
/// switch. Expiry prevents a missing Core Audio event from suppressing a later,
/// unrelated device change.
@MainActor
final class DeviceChangeSuppressionCoordinator {
  typealias Sleep = @Sendable (Duration) async throws -> Void

  private let interval: Duration
  private let sleep: Sleep
  private var expiryTask: Task<Void, Never>?
  private var token: UUID?
  private(set) var pendingDeviceID: String?
  private var isShutDown = false

  init(
    interval: Duration = .seconds(5),
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    self.interval = interval
    self.sleep = sleep
  }

  var trackedTaskCount: Int { expiryTask == nil ? 0 : 1 }

  var lifecycleSnapshot: DeviceChangeSuppressionLifecycleSnapshot {
    DeviceChangeSuppressionLifecycleSnapshot(
      hasPendingDevice: pendingDeviceID != nil,
      trackedTaskCount: trackedTaskCount
    )
  }

  func begin(deviceID: String) {
    guard !isShutDown else { return }
    expiryTask?.cancel()
    let nextToken = UUID()
    token = nextToken
    pendingDeviceID = deviceID
    let sleep = sleep
    let interval = interval
    expiryTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled else { return }
      do {
        try await sleep(interval)
      } catch {
        return
      }
      guard let self, !Task.isCancelled, self.token == nextToken else { return }
      self.pendingDeviceID = nil
      self.token = nil
      self.expiryTask = nil
    }
  }

  @discardableResult
  func consumeIfMatching(deviceID: String?, didChange: Bool) -> Bool {
    guard didChange else { return false }
    let matches = pendingDeviceID == deviceID
    clear()
    return matches
  }

  func clear() {
    expiryTask?.cancel()
    expiryTask = nil
    token = nil
    pendingDeviceID = nil
  }

  func clear(ifMatching deviceID: String) {
    guard pendingDeviceID == deviceID else { return }
    clear()
  }

  func drain() async {
    await expiryTask?.value
  }

  func beginShutdown() -> Task<Void, Never>? {
    isShutDown = true
    let task = expiryTask
    clear()
    return task
  }

  func shutdown() async {
    let task = beginShutdown()
    await task?.value
  }
}
