import AppKit
import Foundation
import WavesAudioCore

/// Turns decoded control requests into `AppStore` calls.
///
/// Every mutating command goes through the *same* public store entry points the
/// UI uses — `setDesiredVolume` / `commitDesiredVolume` / `setMuted`. Nothing
/// here reaches into the backend directly. That is the whole point: a change
/// made from a dial gets identical optimistic projection, persistence, route
/// recovery and generation handling to a change made with the mouse, so there is
/// exactly one code path to reason about and to have already tested.
@MainActor
struct ControlCommandHandler {
  let store: AppStore

  /// One connection's session state. Held by the connection, passed in, so the
  /// handler itself stays stateless and testable.
  struct Session {
    var didHandshake = false
    var isSubscribed = false
  }

  func handle(_ request: ControlRequest, session: inout Session) -> ControlResponse {
    // The handshake is the only command allowed before one has happened, so a
    // client cannot skip version negotiation and then be surprised by a
    // response shape it does not understand.
    guard request.cmd == .hello || session.didHandshake else {
      return .failure(id: request.id, .malformedRequest)
    }

    switch request.cmd {
    case .hello:
      return handleHello(request, session: &session)
    case .subscribe:
      session.isSubscribed = true
      return .success(id: request.id)
    case .unsubscribe:
      session.isSubscribed = false
      return .success(id: request.id)
    case .listApps:
      return handleListApps(request)
    case .getIcon:
      return handleGetIcon(request)
    case .setVolume, .adjustVolume, .setMute, .toggleMute:
      return handleMutation(request)
    }
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
    return response
  }

  private func handleListApps(_ request: ControlRequest) -> ControlResponse {
    var response = ControlResponse.success(id: request.id)
    response.apps = store.controlApps()
    return response
  }

  private func handleGetIcon(_ request: ControlRequest) -> ControlResponse {
    guard let appID = request.app else {
      return .failure(id: request.id, .missingParameter)
    }
    guard let app = store.controlApp(forID: appID) else {
      return .failure(id: request.id, .unknownApp)
    }
    var response = ControlResponse.success(id: request.id)
    response.app = appID
    response.icon = app.iconTIFFData.flatMap { Self.base64PNG($0) }
    return response
  }

  private func handleMutation(_ request: ControlRequest) -> ControlResponse {
    guard let appID = request.app else {
      return .failure(id: request.id, .missingParameter)
    }
    guard store.isAudioRunning else {
      return .failure(id: request.id, .audioNotRunning)
    }
    guard let app = store.controlApp(forID: appID) else {
      return .failure(id: request.id, .unknownApp)
    }
    guard !store.isExcluded(app) else {
      return .failure(id: request.id, .appExcluded)
    }

    var response = ControlResponse.success(id: request.id)
    response.app = appID

    switch request.cmd {
    case .setVolume:
      guard let volume = request.volume else {
        return .failure(id: request.id, .missingParameter)
      }
      let clamped = max(0, min(1, volume))
      store.setDesiredVolume(clamped, for: app)
      store.commitDesiredVolume(for: app)
      response.volume = clamped

    case .adjustVolume:
      guard let delta = request.delta else {
        return .failure(id: request.id, .missingParameter)
      }
      // Waves owns the clamp so a fast dial sweep cannot overshoot, and the
      // resulting value comes back so the client never has to read first.
      let clamped = max(0, min(1, app.desiredVolume + delta))
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

  /// Re-encodes an app icon as base64 PNG at a size a Stream Deck key can use.
  ///
  /// Deliberately small: the key art is 144x144 at 2x, so sending anything
  /// larger would just be bytes the client throws away.
  static func base64PNG(_ tiffData: Data, side: CGFloat = 144) -> String? {
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

    return rep.representation(using: .png, properties: [:])?.base64EncodedString()
  }
}
