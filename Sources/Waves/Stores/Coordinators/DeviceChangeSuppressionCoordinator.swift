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
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var activeToken: UUID?
  private(set) var pendingDeviceID: String?
  private var isShutDown = false

  init(
    interval: Duration = .seconds(5),
    sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
  ) {
    self.interval = interval
    self.sleep = sleep
  }

  var trackedTaskCount: Int { tasks.count }

  var lifecycleSnapshot: DeviceChangeSuppressionLifecycleSnapshot {
    DeviceChangeSuppressionLifecycleSnapshot(
      hasPendingDevice: pendingDeviceID != nil,
      trackedTaskCount: trackedTaskCount
    )
  }

  func begin(deviceID: String) {
    guard !isShutDown else { return }
    cancelActive()
    let nextToken = UUID()
    activeToken = nextToken
    pendingDeviceID = deviceID
    let sleep = sleep
    let interval = interval
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      guard !Task.isCancelled else {
        self.finishTask(token: nextToken)
        return
      }
      do {
        try await sleep(interval)
      } catch {
        self.finishTask(token: nextToken)
        return
      }
      guard !Task.isCancelled, self.activeToken == nextToken else {
        self.finishTask(token: nextToken)
        return
      }
      self.pendingDeviceID = nil
      self.activeToken = nil
      self.finishTask(token: nextToken)
    }
    tasks[nextToken] = task
  }

  @discardableResult
  func consumeIfMatching(deviceID: String?, didChange: Bool) -> Bool {
    guard didChange else { return false }
    let matches = pendingDeviceID == deviceID
    clear()
    return matches
  }

  func clear() {
    cancelActive()
  }

  func clear(ifMatching deviceID: String) {
    guard pendingDeviceID == deviceID else { return }
    clear()
  }

  func drain() async {
    while !tasks.isEmpty {
      for task in tasks.values { await task.value }
    }
  }

  func beginShutdown() -> [Task<Void, Never>] {
    isShutDown = true
    clear()
    return Array(tasks.values)
  }

  func shutdown() async {
    let tasks = beginShutdown()
    for task in tasks { await task.value }
  }

  private func cancelActive() {
    guard let activeToken else {
      pendingDeviceID = nil
      return
    }
    tasks[activeToken]?.cancel()
    self.activeToken = nil
    pendingDeviceID = nil
  }

  private func finishTask(token: UUID) {
    tasks.removeValue(forKey: token)
  }
}
