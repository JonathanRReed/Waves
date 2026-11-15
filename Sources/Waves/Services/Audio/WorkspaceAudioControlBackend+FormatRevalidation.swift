import AppKit
import AudioToolbox
import Foundation
import WavesAudioCore

// MARK: - Sample-rate, stream-format, alive, and wake revalidation

extension WorkspaceAudioControlBackend {
  static let formatEventDebounce: Duration = .milliseconds(500)

  /// The device `app`'s route should render to now: its pinned target, or
  /// the current default. Nil only when the default cannot be read.
  func expectedOutputDeviceUID(for app: AudioApp) -> String? {
    if let outputDeviceUIDProvider { return outputDeviceUIDProvider(app) }
    return app.targetDeviceUID ?? (try? currentDefaultOutputDeviceUID())
  }

  /// The device `app`'s route would render to now and that device's current
  /// format. Creation records the binding of the attempt that succeeded.
  func currentOutputBinding(for app: AudioApp) -> RouteOutputBinding? {
    expectedOutputDeviceUID(for: app).map(outputBinding(forDeviceUID:))
  }

  /// Always names the device; the format is nil if it cannot be read now.
  func outputBinding(forDeviceUID deviceUID: String) -> RouteOutputBinding {
    guard case .alive(let signature) = deviceFormatObservation(uid: deviceUID) else {
      return RouteOutputBinding(deviceUID: deviceUID, signature: nil)
    }
    return RouteOutputBinding(deviceUID: deviceUID, signature: signature)
  }

  func deviceFormatObservation(uid: String) -> DeviceFormatObservation {
    if let deviceFormatObservationProvider { return deviceFormatObservationProvider(uid) }
    guard let deviceID = allDeviceIDs().first(where: { OutputDeviceInventory.deviceUID($0) == uid }) else {
      return .missing
    }
    return OutputDeviceInventory.formatObservation(deviceID)
  }

  /// Rebuilds the routes whose output device changed rate or stream layout,
  /// or came back after not being alive. The rebuild is ordinary route
  /// maintenance: automatic (so it spends the backend-wide rebuild budget),
  /// guarded against newer intent, and make before break.
  func revalidateRouteFormats(now: Duration) async {
    guard !isShuttingDown else { return }
    routeOutputBindingByRuntimeID = routeOutputBindingByRuntimeID.filter { controllers[$0.key] != nil }
    let deviceUIDs = Set(routeOutputBindingByRuntimeID.values.map(\.deviceUID))
    let observations = Dictionary(
      uniqueKeysWithValues: deviceUIDs.map { ($0, deviceFormatObservation(uid: $0)) }
    )
    // A device that dropped and returned inside the debounce window was
    // caught by its listener; treat it as seen not alive.
    let decision = RouteFormatRevalidation.decide(
      bindings: routeOutputBindingByRuntimeID,
      observations: observations,
      devicesPreviouslySeenNotAlive: devicesSeenNotAlive.union(deviceFormatListeners.takeDevicesSeenNotAlive())
    )
    devicesSeenNotAlive = decision.devicesSeenNotAlive
    guard !decision.runtimeIDsToRebuild.isEmpty else { return }
    logger.info("Output format changed; rebuilding \(decision.runtimeIDsToRebuild.count, privacy: .public) route(s)")
    await performRouteMaintenance(forceRebuildIDs: decision.runtimeIDsToRebuild, now: now)
  }

  /// Listens for format events on every output-capable device outside
  /// Waves's own aggregates. Registering on all of them, rather than only the
  /// devices that carry routes, keeps the set independent of route churn;
  /// an event for a device no route uses is a no-op in `revalidateRouteFormats`.
  func syncDeviceFormatListeners() {
    guard !isShuttingDown else { return }
    syncDeviceFormatListeners(devices: externalOutputDevices())
  }

  /// Every output-capable device outside Waves's own aggregates, by object.
  func externalOutputDevices() -> [AudioObjectID: String] {
    if let deviceInventoryProvider { return deviceInventoryProvider() }
    var devices: [AudioObjectID: String] = [:]
    for deviceID in allDeviceIDs() where OutputDeviceInventory.hasOutputStreams(deviceID) {
      guard let uid = OutputDeviceInventory.deviceUID(deviceID), !uid.hasPrefix("com.waves.aggregate.") else {
        continue
      }
      devices[deviceID] = uid
    }
    return devices
  }

  private func syncDeviceFormatListeners(devices: [AudioObjectID: String]) {
    let mailbox = deviceChangeMailbox
    retainCleanupDegradations(
      deviceFormatListeners.sync(devices: devices) { mailbox.enqueue(.deviceFormat) }
    )
  }

  func addWakeObserver() {
    guard !isShuttingDown, wakeObserver == nil else { return }
    let mailbox = deviceChangeMailbox
    wakeObserver = WakeObserverToken(center: NSWorkspace.shared.notificationCenter) {
      mailbox.enqueue(.wake)
    }
  }

  func removeWakeObserver() {
    wakeObserver?.invalidate()
    wakeObserver = nil
  }

  func syncDeviceFormatListenersForTesting(devices: [AudioObjectID: String]) {
    syncDeviceFormatListeners(devices: devices)
  }

  func revalidateRouteFormatsForTesting(at now: Duration) async {
    await revalidateRouteFormats(now: now)
  }
}

/// Owns the wake registration and removes it exactly once: on an explicit
/// shutdown, or when the backend is released without one. A separate
/// non-isolated owner, like the device-format listeners, because an actor's
/// deinit cannot reach back into isolated state to clean up.
final class WakeObserverToken: @unchecked Sendable {
  private let center: NotificationCenter
  private let lock = NSLock()
  private var token: NSObjectProtocol?

  init(center: NotificationCenter, onWake: @escaping @Sendable () -> Void) {
    self.center = center
    self.token = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: nil
    ) { _ in onWake() }
  }

  func invalidate() {
    let token = lock.withLock {
      defer { self.token = nil }
      return self.token
    }
    if let token { center.removeObserver(token) }
  }

  deinit {
    invalidate()
  }
}
