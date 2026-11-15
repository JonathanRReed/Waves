import AppKit
import Foundation
import WavesAudioCore

/// Turns decoded control requests into `AppStore` calls.
///
/// Every mutating command goes through the *same* public store entry points the
/// UI uses — `setDesiredVolume` / `commitDesiredVolume` / `setMuted` /
/// `setVolumeBoost` / `applyProfile` / `refresh`. Nothing
/// here reaches into the backend directly. That is the whole point: a change
/// made from a dial gets identical optimistic projection, persistence, route
/// recovery and generation handling to a change made with the mouse, so there is
/// exactly one code path to reason about and to have already tested.
@MainActor
struct ControlCommandHandler {
  let store: AppStore
  var testingPreflightFailure: ((ControlRequest) -> ControlError?)? = nil

  struct HandlingResult {
    let response: ControlResponse
    let session: Session
  }

  /// One connection's session state. Held by the connection, passed in, so the
  /// handler itself stays stateless and testable.
  struct Session {
    var didHandshake = false
    var isSubscribed = false
  }

  func handle(_ request: ControlRequest, session: Session) async -> HandlingResult {
    var session = session
    if let error = testingPreflightFailure?(request) {
      return HandlingResult(response: .failure(id: request.id, error), session: session)
    }
    guard store.preferences.enableExternalControl else {
      return HandlingResult(response: .failure(id: request.id, .notPermitted), session: session)
    }

    // The handshake is the only command allowed before one has happened, so a
    // client cannot skip version negotiation and then be surprised by a
    // response shape it does not understand.
    guard request.cmd == .hello || session.didHandshake else {
      return HandlingResult(response: .failure(id: request.id, .malformedRequest), session: session)
    }

    let response: ControlResponse
    switch request.cmd {
    case .hello:
      response = handleHello(request, session: &session)
    case .subscribe:
      session.isSubscribed = true
      response = .success(id: request.id)
    case .unsubscribe:
      session.isSubscribed = false
      response = .success(id: request.id)
    case .listApps:
      response = handleListApps(request)
    case .getIcon:
      response = await handleGetIcon(request)
    case .setVolume, .adjustVolume, .setMute, .toggleMute:
      response = handleMutation(request)
    case .setBoost:
      response = await handleSetBoost(request)
    case .applyProfile:
      response = await handleApplyProfile(request)
    case .refresh:
      response = await handleRefresh(request)
    }
    return HandlingResult(response: response, session: session)
  }

  private func handleHello(_ request: ControlRequest, session: inout Session) -> ControlResponse {
    // A client that does not name a version is assumed to speak the current one;
    // one that names a different version is refused rather than half-served.
    let requested = request.protocolVersion ?? ControlProtocol.version
    guard requested == ControlProtocol.version else {
      return .failure(id: request.id, .unsupportedProtocol)
    }
    session.didHandshake = true

    var response = ControlResponse.success(id: request.id)
    response.protocolVersion = ControlProtocol.version
    response.appVersion = AppVersion.short
    response.build = AppVersion.build
    response.commands = ControlCommand.allCases.map(\.rawValue)
    return response
  }

  private func handleListApps(_ request: ControlRequest) -> ControlResponse {
    var response = ControlResponse.success(id: request.id)
    response.apps = store.controlApps()
    return response
  }

  private func handleGetIcon(_ request: ControlRequest) async -> ControlResponse {
    guard let appID = request.app else {
      return .failure(id: request.id, .missingParameter)
    }
    // Never shorten an identifier into the key of a different app.
    guard appID.count <= ControlRequest.maximumAppIDLength else {
      return .failure(id: request.id, .unknownApp)
    }
    guard let app = store.controlApp(forID: appID) else {
      return .failure(id: request.id, .unknownApp)
    }
    var response = ControlResponse.success(id: request.id)
    response.app = appID
    if let iconData = app.iconTIFFData {
      response.icon = await Task.detached(priority: .utility) {
        ControlIconEncoder.base64PNG(iconData)
      }.value
    }
    return response
  }

  private enum MutationTarget {
    case success(AudioApp)
    case failure(ControlError)
  }

  /// The app a per-app mutation targets, or the failure to send instead.
  private func mutationTarget(_ request: ControlRequest) -> MutationTarget {
    guard let appID = request.app else { return .failure(.missingParameter) }
    // Never shorten an identifier into the key of a different app.
    guard appID.count <= ControlRequest.maximumAppIDLength else { return .failure(.unknownApp) }
    guard store.isAudioRunning else { return .failure(.audioNotRunning) }
    guard let app = store.controlApp(forID: appID) else { return .failure(.unknownApp) }
    guard !store.isExcluded(app) else { return .failure(.appExcluded) }
    return .success(app)
  }

  private func handleMutation(_ request: ControlRequest) -> ControlResponse {
    let app: AudioApp
    switch mutationTarget(request) {
    case let .success(target): app = target
    case let .failure(error): return .failure(id: request.id, error)
    }
    let appID = app.logicalID

    var response = ControlResponse.success(id: request.id)
    response.app = appID

    switch request.cmd {
    case .setVolume:
      // Protocol 1 has always clamped a finite volume into 0...1, so an
      // existing client that overshoots by a rounding error keeps working.
      // A missing or non-finite volume is refused.
      guard let clamped = LevelRange.volume.clamped(request.volume) else {
        return .failure(id: request.id, .missingParameter)
      }
      store.setDesiredVolume(clamped, for: app)
      store.commitDesiredVolume(for: app)
      response.volume = clamped

    case .adjustVolume:
      guard let delta = request.delta, delta.isFinite,
        // Waves owns the clamp so a fast dial sweep cannot overshoot, and the
        // resulting value comes back so the client never has to read first.
        let clamped = LevelRange.volume.clamped(Double(app.desiredVolume) + Double(delta))
      else {
        return .failure(id: request.id, .missingParameter)
      }
      store.setDesiredVolume(clamped, for: app)
      store.commitDesiredVolume(for: app)
      response.volume = clamped

    case .setMute:
      guard let muted = request.muted else {
        return .failure(id: request.id, .missingParameter)
      }
      store.setMuted(muted, for: app)
      response.muted = muted

    case .toggleMute:
      let muted = !app.isMuted
      store.setMuted(muted, for: app)
      response.muted = muted

    default:
      return .failure(id: request.id, .malformedRequest)
    }

    return response
  }

  /// Boost is the one control that makes an app louder than its own level,
  /// so it follows the mixer exactly: refused (never clamped) outside the
  /// Boost menu's 1...4, refused for excluded apps and for routes the mixer
  /// disables Boost on, and answered only once the route has taken it.
  private func handleSetBoost(_ request: ControlRequest) async -> ControlResponse {
    let app: AudioApp
    switch mutationTarget(request) {
    case let .success(target): app = target
    case let .failure(error): return .failure(id: request.id, error)
    }
    guard request.boost != nil else {
      return .failure(id: request.id, .missingParameter)
    }
    guard let boost = LevelRange.boost.validated(request.boost) else {
      return .failure(id: request.id, .invalidParameter)
    }
    guard MixerRouteControlPolicy(app: app).allowsDSPControl else {
      return .failure(id: request.id, .routeUnavailable)
    }

    switch await store.applyExternalBoost(boost, to: app) {
    case .applied, .noChange:
      var response = ControlResponse.success(id: request.id)
      response.app = app.logicalID
      response.boost = boost
      return response
    case .excluded:
      return .failure(id: request.id, .appExcluded)
    case .unavailable, .unsupported:
      return .failure(id: request.id, .routeUnavailable)
    case .superseded, .failed:
      return .failure(id: request.id, .notApplied)
    }
  }

  private func handleApplyProfile(_ request: ControlRequest) async -> ControlResponse {
    guard let name = request.profile else {
      return .failure(id: request.id, .missingParameter)
    }
    guard AutomationCommandParser.isAcceptableProfileName(name) else {
      return .failure(id: request.id, .invalidParameter)
    }
    guard store.isAudioRunning else {
      return .failure(id: request.id, .audioNotRunning)
    }
    guard let profile = store.automationProfile(named: name) else {
      return .failure(id: request.id, .unknownProfile)
    }
    guard let (result, settingsSaved) = await store.applyProfileForExternalControl(profile) else {
      return .failure(id: request.id, .notApplied)
    }

    var counts = ControlProfileResult(name: profile.name, applied: 0, savedForLater: 0, skipped: 0, failed: 0)
    for (entry, row) in zip(profile.entries, result.rows) where entry.hasLevels {
      switch row.outcome {
      case .applied, .noChange: counts.applied += 1
      // Levels for an app that is not running exist only in saved settings.
      case .unavailable where settingsSaved: counts.savedForLater += 1
      case .unavailable: counts.failed += 1
      case .excluded: counts.skipped += 1
      case .membershipOnly: break
      case .failed, .unsupported, .superseded: counts.failed += 1
      }
    }
    var response =
      counts.failed == 0
      ? ControlResponse.success(id: request.id)
      : ControlResponse.failure(id: request.id, .notApplied)
    response.profile = counts
    return response
  }

  private func handleRefresh(_ request: ControlRequest) async -> ControlResponse {
    guard store.isAudioRunning,
      let refresh = store.startRefresh(announce: true, reevaluateAutomation: true)
    else {
      return .failure(id: request.id, .audioNotRunning)
    }
    guard await refresh.value else {
      return .failure(id: request.id, .notApplied)
    }
    var response = ControlResponse.success(id: request.id)
    response.apps = store.controlApps()
    return response
  }

}

/// Re-encodes captured icon data off the main actor. The source `Data` is
/// Sendable and has already been detached from NSWorkspace/AppKit state.
enum ControlIconEncoder {
  static let maximumEncodedBytes = 512 * 1024

  nonisolated static func boundedBase64PNG(_ encoded: String?) -> String? {
    guard let encoded, encoded.utf8.count <= maximumEncodedBytes else { return nil }
    return encoded
  }

  nonisolated static func base64PNG(_ tiffData: Data, side: CGFloat = 144) -> String? {
    // Validate side dimension to prevent non-finite numbers, zero/negative, or oversized dimensions from causing memory issues or crashes.
    guard side.isFinite, side > 0, side <= 2048 else { return nil }
    guard let image = NSImage(data: tiffData) else { return nil }
    let target = NSSize(width: side, height: side)
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(side),
        pixelsHigh: Int(side),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    image.draw(in: NSRect(origin: .zero, size: target))
    context.flushGraphics()

    return boundedBase64PNG(rep.representation(using: .png, properties: [:])?.base64EncodedString())
  }
}
