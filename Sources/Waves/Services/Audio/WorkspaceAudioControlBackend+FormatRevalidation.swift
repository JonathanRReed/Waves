import AppKit
import AudioToolbox
import Foundation
import WavesAudioCore

// MARK: - Sample-rate, stream-format, alive, and wake revalidation

extension WorkspaceAudioControlBackend {
  static let formatEventDebounce: Duration = .milliseconds(500)

  /// The device `app`'s route renders to and that device's current format.
  /// Read before the controller is built, so a format change that lands
  /// during creation is seen as a change afterwards rather than absorbed.
  func currentOutputBinding(for app: AudioApp) -> RouteOutputBinding? {
    if let routeOutputBindingProvider { return routeOutputBindingProvider(app) }
    guard let deviceUID = app.targetDeviceUID ?? (try? currentDefaultOutputDeviceUID()),
      case .alive(let signature) = deviceFormatObservation(uid: deviceUID)
    else { return nil }
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
    let decision = RouteFormatRevalidation.decide(
      bindings: routeOutputBindingByRuntimeID,
      observations: observations,
      devicesPreviouslySeenNotAlive: devicesSeenNotAlive
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
    let mailbox = deviceChangeMailbox
    let deviceIDs = Set(
      allDeviceIDs().filter {
        OutputDeviceInventory.hasOutputStreams($0)
          && OutputDeviceInventory.deviceUID($0)?.hasPrefix("com.waves.aggregate.") == false
      }
    )
    retainCleanupDegradations(
      deviceFormatListeners.sync(deviceIDs: deviceIDs) { mailbox.enqueue(.deviceFormat) }
    )
  }

  func addWakeObserver() {
    guard !isShuttingDown, wakeObserver == nil else { return }
    let mailbox = deviceChangeMailbox
    wakeObserver = WakeObserverToken(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: nil
      ) { _ in mailbox.enqueue(.wake) }
    )
  }

  func removeWakeObserver() {
    guard let wakeObserver else { return }
    NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver.token)
    self.wakeObserver = nil
  }

  func revalidateRouteFormatsForTesting(at now: Duration) async {
    await revalidateRouteFormats(now: now)
  }
}

final class WakeObserverToken: @unchecked Sendable {
  let token: NSObjectProtocol
  init(_ token: NSObjectProtocol) { self.token = token }
}
