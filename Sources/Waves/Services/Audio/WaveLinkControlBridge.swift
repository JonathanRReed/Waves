import Foundation

protocol WaveLinkControlling: Sendable {
  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) async throws -> WaveLinkControlConfirmation
}

struct WaveLinkControlConfirmation: Equatable, Sendable {
  let channelID: String
  let channelName: String
  let appliedVolume: Float
  let isMuted: Bool
}

enum WaveLinkControlBridgeError: Error, Equatable, LocalizedError, Sendable {
  case invalidBundleIdentifier
  case invalidVolume
  case unavailable(String)
  case incompatibleApplication
  case unverifiedLoopbackPeer
  case dedicatedChannelRequired(String)
  case protocolViolation(String)
  case readBackMismatch(String)

  var errorDescription: String? {
    switch self {
    case .invalidBundleIdentifier:
      "Wave Link control requires the app's exact bundle identifier."
    case .invalidVolume:
      "Wave Link rejected a non-finite or out-of-range volume."
    case .unavailable(let detail):
      "Wave Link control is unavailable: \(detail)"
    case .incompatibleApplication:
      "The loopback control service is not a compatible Elgato Wave Link instance."
    case .unverifiedLoopbackPeer:
      "The loopback control service is not owned by the verified Elgato Wave Link process."
    case .dedicatedChannelRequired(let appID):
      "Wave Link needs an empty software channel to control \(appID) independently."
    case .protocolViolation(let detail):
      "Wave Link returned an invalid control response: \(detail)"
    case .readBackMismatch(let detail):
      "Wave Link did not confirm the requested app level: \(detail)"
    }
  }
}

struct WaveLinkApplicationInfo: Codable, Equatable, Sendable {
  let interfaceRevision: Int
  let appID: String
  let name: String?
}

struct WaveLinkChannelApp: Codable, Equatable, Sendable {
  let id: String
}

struct WaveLinkChannel: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let type: String
  var level: Float
  var isMuted: Bool
  var apps: [WaveLinkChannelApp]

  init(
    id: String,
    name: String,
    type: String,
    level: Float,
    isMuted: Bool,
    apps: [WaveLinkChannelApp]
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.level = level
    self.isMuted = isMuted
    self.apps = apps
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    type = try container.decode(String.self, forKey: .type)
    level = try container.decodeIfPresent(Float.self, forKey: .level) ?? 1
    isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    apps = try container.decodeIfPresent([WaveLinkChannelApp].self, forKey: .apps) ?? []
  }

  var isSoftware: Bool {
    type.caseInsensitiveCompare("software") == .orderedSame
  }
}

struct WaveLinkChannelsResponse: Codable, Equatable, Sendable {
  let channels: [WaveLinkChannel]
}

actor WaveLinkControlBridge: WaveLinkControlling {
  typealias Request = @Sendable (_ method: String, _ params: Data?) async throws -> Data
  typealias PeerValidator = @Sendable () async throws -> Void
  typealias SequenceFinalizer = @Sendable () async -> Void

  private struct AddToChannelRequest: Encodable {
    let appID: String
    let channelID: String

    enum CodingKeys: String, CodingKey {
      case appID = "appId"
      case channelID = "channelId"
    }
  }

  private struct SetChannelRequest: Encodable {
    let id: String
    let level: Float
    let isMuted: Bool
  }

  private let request: Request
  private let validatePeer: PeerValidator
  private let finishSequence: SequenceFinalizer
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    request: @escaping Request,
    validatePeer: @escaping PeerValidator = {},
    finishSequence: @escaping SequenceFinalizer = {}
  ) {
    self.request = request
    self.validatePeer = validatePeer
    self.finishSequence = finishSequence
  }

  init() {
    // The resolver both discovers Wave Link's current control port and proves
    // the listener is the signed Wave Link process, so peer validation and the
    // transport destination can never disagree.
    let resolver = WaveLinkVerifiedEndpointResolver()
    let transport = WaveLinkJSONRPCTransport(portProvider: {
      try await resolver.verifiedEndpoint().port
    })
    self.request = { method, params in
      do {
        return try await transport.request(method: method, params: params)
      } catch {
        // A dead socket usually means Wave Link restarted on a new port.
        await resolver.invalidate()
        throw error
      }
    }
    self.validatePeer = {
      _ = try await resolver.verifiedEndpoint()
    }
    self.finishSequence = {
      await transport.endSequence()
    }
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) async throws -> WaveLinkControlConfirmation {
    do {
      let confirmation = try await performApply(
        bundleIdentifier: bundleIdentifier,
        volume: volume,
        isMuted: isMuted
      )
      await finishSequence()
      return confirmation
    } catch {
      await finishSequence()
      throw error
    }
  }

  private func performApply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) async throws -> WaveLinkControlConfirmation {
    guard !bundleIdentifier.isEmpty else {
      throw WaveLinkControlBridgeError.invalidBundleIdentifier
    }
    guard volume.isFinite, (0...1).contains(volume) else {
      throw WaveLinkControlBridgeError.invalidVolume
    }

    try await validatePeer()

    let applicationInfoData = try await request("getApplicationInfo", nil)
    let applicationInfo = try decode(WaveLinkApplicationInfo.self, from: applicationInfoData)
    // Wave Link 3 reset its protocol: `appID` is "EWL" and `interfaceRevision`
    // restarted at 1 (the value 3.0-3.2 report). Earlier Wave Link generations
    // answer "egwl" with revisions 6-7 and a different method set, so they are
    // rejected here and stay monitoring-only.
    guard applicationInfo.appID == "EWL", applicationInfo.interfaceRevision >= 1 else {
      throw WaveLinkControlBridgeError.incompatibleApplication
    }

    var channels = try await readChannels()
    let matchingChannels = channels.filter {
      $0.isSoftware && $0.apps.contains(where: { $0.id == bundleIdentifier })
    }

    let targetChannel: WaveLinkChannel
    if matchingChannels.count == 1,
      let dedicated = matchingChannels.first,
      dedicated.apps.count == 1,
      dedicated.apps[0].id == bundleIdentifier
    {
      targetChannel = dedicated
    } else {
      guard let empty = channels.first(where: { $0.isSoftware && $0.apps.isEmpty }) else {
        throw WaveLinkControlBridgeError.dedicatedChannelRequired(bundleIdentifier)
      }
      let addRequest = AddToChannelRequest(appID: bundleIdentifier, channelID: empty.id)
      _ = try await request("addToChannel", try encoder.encode(addRequest))
      channels = try await readChannels()
      let movedMatches = channels.filter {
        $0.isSoftware && $0.apps.contains(where: { $0.id == bundleIdentifier })
      }
      guard
        movedMatches.count == 1,
        let moved = movedMatches.first,
        moved.id == empty.id,
        moved.apps.count == 1
      else {
        throw WaveLinkControlBridgeError.readBackMismatch(
          "The app was not isolated on channel \(empty.name)."
        )
      }
      targetChannel = moved
    }

    let setRequest = SetChannelRequest(id: targetChannel.id, level: volume, isMuted: isMuted)
    _ = try await request("setChannel", try encoder.encode(setRequest))

    let confirmedChannels = try await readChannels()
    let confirmedMatches = confirmedChannels.filter {
      $0.isSoftware && $0.apps.contains(where: { $0.id == bundleIdentifier })
    }
    guard
      confirmedMatches.count == 1,
      let confirmed = confirmedMatches.first,
      confirmed.id == targetChannel.id,
      confirmed.apps.count == 1
    else {
      throw WaveLinkControlBridgeError.readBackMismatch(
        "The dedicated app channel disappeared after the update."
      )
    }
    guard abs(confirmed.level - volume) <= 0.001, confirmed.isMuted == isMuted else {
      throw WaveLinkControlBridgeError.readBackMismatch(
        "Requested \(volume), muted \(isMuted); received \(confirmed.level), muted \(confirmed.isMuted)."
      )
    }

    return WaveLinkControlConfirmation(
      channelID: confirmed.id,
      channelName: confirmed.name,
      appliedVolume: confirmed.level,
      isMuted: confirmed.isMuted
    )
  }

  private func readChannels() async throws -> [WaveLinkChannel] {
    let data = try await request("getChannels", nil)
    let response = try decode(WaveLinkChannelsResponse.self, from: data)
    return response.channels
  }

  private func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data
  ) throws -> Value {
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw WaveLinkControlBridgeError.protocolViolation(error.localizedDescription)
    }
  }
}

enum WaveLinkLoopbackPeerVerifier {
  typealias IdentityVerifier =
    @Sendable (
      pid_t,
      VerifiedRouterDescriptor
    ) -> VerifiedRouterProcessIdentity?

  static func validate(
    listenerPIDs: [pid_t],
    descriptor: VerifiedRouterDescriptor = .waveLink3_2_2,
    identityVerifier: IdentityVerifier
  ) throws {
    let hasVerifiedOwner = listenerPIDs.contains { pid in
      guard let identity = identityVerifier(pid, descriptor) else { return false }
      return identity.pid == pid
        && identity.teamIdentifier == descriptor.teamIdentifier
        && identity.matchesDesignatedRequirement
    }
    guard hasVerifiedOwner else {
      throw WaveLinkControlBridgeError.unverifiedLoopbackPeer
    }
  }

  static func parseListenerPIDs(_ output: String) -> [pid_t] {
    Array(
      Set(
        output.split(whereSeparator: \.isNewline).compactMap { line in
          guard line.first == "p", let pid = pid_t(line.dropFirst()) else { return nil }
          return pid
        }
      )
    ).sorted()
  }
}

private actor WaveLinkJSONRPCTransport {
  typealias PortProvider = @Sendable () async throws -> UInt16

  private struct RPCErrorPayload: Decodable {
    let code: Int?
    let message: String?
  }

  private let session: URLSession
  private let portProvider: PortProvider
  private var socket: URLSessionWebSocketTask?
  private var nextRequestID = 1

  init(portProvider: @escaping PortProvider) {
    // Only the connect handshake gets a session timeout. A resource lifetime
    // limit would tear the socket down mid-sequence; per-message stalls are
    // bounded by the receive timeout below instead.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    session = URLSession(configuration: configuration)
    self.portProvider = portProvider
  }

  func request(method: String, params: Data?) async throws -> Data {
    do {
      return try await performRequest(method: method, params: params)
    } catch {
      // Never keep a socket that produced any failure; the next sequence
      // reconnects against a freshly verified endpoint.
      closeSocket(with: .abnormalClosure)
      throw error
    }
  }

  /// Ends one bridge apply sequence. Wave Link expects short-lived control
  /// connections, and dropping the socket here keeps an idle Waves from
  /// pinning a stale connection across Wave Link restarts.
  func endSequence() {
    closeSocket(with: .goingAway)
  }

  private func closeSocket(with code: URLSessionWebSocketTask.CloseCode) {
    socket?.cancel(with: code, reason: nil)
    socket = nil
  }

  private func performRequest(method: String, params: Data?) async throws -> Data {
    let socket = try await connectedSocket()
    let requestID = nextRequestID
    nextRequestID += 1

    var payload: [String: Any] = [
      "id": requestID,
      "jsonrpc": "2.0",
      "method": method,
    ]
    if let params {
      payload["params"] = try JSONSerialization.jsonObject(with: params)
    }
    let requestData = try JSONSerialization.data(withJSONObject: payload)
    guard let requestText = String(data: requestData, encoding: .utf8) else {
      throw WaveLinkControlBridgeError.protocolViolation("The request was not UTF-8.")
    }

    do {
      try await socket.send(.string(requestText))
      while true {
        let message = try await receiveNextMessage(from: socket)
        let responseData: Data
        switch message {
        case .data(let data):
          responseData = data
        case .string(let string):
          responseData = Data(string.utf8)
        @unknown default:
          throw WaveLinkControlBridgeError.protocolViolation("Unknown WebSocket message type.")
        }
        guard
          let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          (object["id"] as? NSNumber)?.intValue == requestID
        else {
          continue
        }
        if let errorObject = object["error"] {
          let errorData = try JSONSerialization.data(withJSONObject: errorObject)
          let errorPayload = try? JSONDecoder().decode(RPCErrorPayload.self, from: errorData)
          let detail = errorPayload?.message ?? "JSON-RPC error \(errorPayload?.code ?? -1)"
          throw WaveLinkControlBridgeError.unavailable(detail)
        }
        guard let result = object["result"] else {
          throw WaveLinkControlBridgeError.protocolViolation("Missing JSON-RPC result.")
        }
        if result is NSNull { return Data("{}".utf8) }
        return try JSONSerialization.data(withJSONObject: result)
      }
    } catch let error as WaveLinkControlBridgeError {
      throw error
    } catch {
      throw WaveLinkControlBridgeError.unavailable(error.localizedDescription)
    }
  }

  private func receiveNextMessage(
    from socket: URLSessionWebSocketTask
  ) async throws -> URLSessionWebSocketTask.Message {
    try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
      group.addTask {
        try await socket.receive()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw WaveLinkControlBridgeError.unavailable("The loopback service timed out.")
      }
      guard let message = try await group.next() else {
        throw WaveLinkControlBridgeError.unavailable("The loopback service closed unexpectedly.")
      }
      group.cancelAll()
      return message
    }
  }

  private func connectedSocket() async throws -> URLSessionWebSocketTask {
    if let socket { return socket }
    let port = try await portProvider()
    guard let url = URL(string: "ws://127.0.0.1:\(port)") else {
      throw WaveLinkControlBridgeError.unavailable("Port \(port) is not a valid loopback URL.")
    }
    var request = URLRequest(url: url)
    request.setValue("streamdeck://", forHTTPHeaderField: "Origin")
    let socket = session.webSocketTask(with: request)
    socket.resume()
    self.socket = socket
    return socket
  }
}
