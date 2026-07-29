import Foundation

/// The wire format spoken over Waves's control socket.
///
/// Newline-delimited JSON, one object per line, UTF-8. Requests carry a
/// client-chosen `id` and responses echo it, so a client can have several in
/// flight. Unsolicited state pushes carry `event` and no `id`.
///
/// Everything here is pure: no sockets, no `AppStore`, no Core Audio. That is
/// deliberate — it makes the entire protocol testable without opening a file
/// descriptor, which matters because the first real client (a Stream Deck
/// plugin) lives on hardware that cannot be tested from here.
enum ControlProtocol {
  /// Bumped only for a breaking change. `hello` refuses a client asking for a
  /// version this build does not speak, so a mismatch is a clear error rather
  /// than a mystery, and an old plugin against a new app fails loudly.
  static let version = 1

  /// A line longer than this is refused and the connection closed. Commands are
  /// tiny; anything approaching this is either a bug or an attempt to exhaust
  /// memory. Icon *responses* can be larger — this bounds input only.
  static let maximumLineBytes = 64 * 1024
}

// MARK: - Requests

/// A command name. Closed set, so an unknown command is rejected by decoding
/// rather than reaching any handler.
enum ControlCommand: String, Codable, CaseIterable, Sendable {
  case hello
  case listApps = "list-apps"
  case getIcon = "get-icon"
  case setVolume = "set-volume"
  case adjustVolume = "adjust-volume"
  case setMute = "set-mute"
  case toggleMute = "toggle-mute"
  case subscribe
  case unsubscribe
}

struct ControlRequest: Codable, Equatable, Sendable {
  var id: Int?
  var cmd: ControlCommand
  /// Logical app identifier — the same stable key Waves persists everywhere
  /// else, so a Stream Deck binding survives the app quitting and relaunching.
  var app: String?
  /// Absolute volume, 0…1, for `set-volume`.
  var volume: Float?
  /// Relative change for `adjust-volume`. A dial emits a stream of rotate
  /// events; sending a delta means the client never has to read-then-write,
  /// which would race itself on a fast twist and overshoot.
  var delta: Float?
  var muted: Bool?
  /// Client name, for logging. Free text, bounded on decode.
  var client: String?
  var protocolVersion: Int?

  enum CodingKeys: String, CodingKey {
    case id, cmd, app, volume, delta, muted, client
    case protocolVersion = "protocol"
  }
}

// MARK: - Responses

/// A machine-readable failure. Clients branch on these; the human-readable
/// `message` is for logs and for surfacing in a plugin's UI.
enum ControlError: String, Codable, Equatable, Sendable {
  case unsupportedProtocol = "unsupported-protocol"
  case malformedRequest = "malformed-request"
  case missingParameter = "missing-parameter"
  case unknownApp = "unknown-app"
  case appExcluded = "app-excluded"
  case audioNotRunning = "audio-not-running"
  case rateLimited = "rate-limited"
  case notPermitted = "not-permitted"

  var message: String {
    switch self {
    case .unsupportedProtocol:
      "This version of Waves does not speak that protocol version."
    case .malformedRequest:
      "The request could not be understood."
    case .missingParameter:
      "The request is missing a required parameter."
    case .unknownApp:
      "Waves does not know an app with that identifier."
    case .appExcluded:
      "That app is excluded from Waves."
    case .audioNotRunning:
      "Waves is not managing audio yet. Finish setup in Waves."
    case .rateLimited:
      "Too many commands. Slow down."
    case .notPermitted:
      "External control is turned off. Turn it on in Waves \u{25B8} Settings \u{25B8} Advanced."
    }
  }
}

/// One app, as the control surface describes it.
struct ControlApp: Codable, Equatable, Sendable {
  var id: String
  var name: String
  var running: Bool
  var muted: Bool
  var volume: Float
  /// Producing audio right now (no linger), so a key can show "playing".
  var live: Bool
  /// Waves owns this app's route, so volume and mute will actually take effect.
  var managed: Bool
}

struct ControlResponse: Codable, Equatable, Sendable {
  var id: Int?
  var ok: Bool
  var error: ControlError?
  var message: String?
  var event: ControlEvent?

  var protocolVersion: Int?
  var app: String?
  var appVersion: String?
  var build: String?
  var apps: [ControlApp]?
  /// The app this response is about, for a single-app change push.
  var changed: ControlApp?
  var volume: Float?
  var muted: Bool?
  /// Base64 PNG. Separate from `list-apps` because icons are the heaviest field
  /// and a client needs them once per app, not on every list.
  var icon: String?

  enum CodingKeys: String, CodingKey {
    case id, ok, error, message, event, app, apps, changed, volume, muted, icon
    case protocolVersion = "protocol"
    case appVersion = "appVersion"
    case build
  }

  static func success(id: Int?) -> ControlResponse {
    ControlResponse(id: id, ok: true)
  }

  static func failure(id: Int?, _ error: ControlError) -> ControlResponse {
    ControlResponse(id: id, ok: false, error: error, message: error.message)
  }
}

/// Unsolicited pushes, sent only to subscribed connections.
enum ControlEvent: String, Codable, Equatable, Sendable {
  /// One app's state moved — mute, volume, or whether it is live.
  case appChanged = "app-changed"
  /// The roster itself changed: an app launched, quit, or was excluded. The
  /// client should re-list rather than being sent the whole set unprompted.
  case appsChanged = "apps-changed"
}

// MARK: - Codec

/// Frames and parses newline-delimited JSON.
///
/// Kept separate from the socket so the framing rules — which are where line
/// protocols usually go wrong — can be tested directly.
struct ControlCodec {
  private var buffer = Data()

  /// Feeds received bytes and returns whatever complete lines they produced.
  ///
  /// Throws `.lineTooLong` if a single line exceeds the cap, which the caller
  /// must treat as fatal for that connection: a client that cannot frame
  /// correctly will not recover, and buffering more would be the memory
  /// exhaustion the cap exists to prevent.
  mutating func append(_ data: Data) throws -> [Data] {
    guard buffer.count + data.count <= ControlProtocol.maximumLineBytes else {
      throw ControlCodecError.lineTooLong
    }
    buffer.append(data)

    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer = buffer[buffer.index(after: newline)...]
      // Tolerate CRLF and skip blank keepalive lines rather than erroring.
      var trimmed = Data(line)
      if trimmed.last == 0x0D { trimmed.removeLast() }
      if !trimmed.isEmpty { lines.append(trimmed) }
    }
    buffer = Data(buffer)
    return lines
  }

  static func decode(_ line: Data) -> ControlRequest? {
    try? JSONDecoder().decode(ControlRequest.self, from: line)
  }

  static func encode(_ response: ControlResponse) -> Data? {
    guard var data = try? JSONEncoder().encode(response) else { return nil }
    data.append(0x0A)
    return data
  }
}

enum ControlCodecError: Error, Equatable {
  case lineTooLong
}
