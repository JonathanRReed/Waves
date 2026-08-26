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
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    request: @escaping Request,
    validatePeer: @escaping PeerValidator = {}
  ) {
    self.request = request
    self.validatePeer = validatePeer
  }

  init() {
    let transport = WaveLinkJSONRPCTransport()
    self.request = { method, params in
      try await transport.request(method: method, params: params)
    }
    self.validatePeer = {
      try await WaveLinkLoopbackPeerVerifier.verify()
    }
  }

  func apply(
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
    guard applicationInfo.appID == "EWL", applicationInfo.interfaceRevision >= 2 else {
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

  static func verify() async throws {
    try await Task.detached(priority: .utility) {
      let listenerPIDs = try liveListenerPIDs()
      try validate(
        listenerPIDs: listenerPIDs,
        identityVerifier: VerifiedRouterProcessIdentity.verifyLive
      )
    }.value
  }

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

  private static func liveListenerPIDs() throws -> [pid_t] {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-a", "-iTCP:1884", "-sTCP:LISTEN", "-Fp"]
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw WaveLinkControlBridgeError.unavailable(
        "Could not inspect the loopback service owner: \(error.localizedDescription)"
      )
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw WaveLinkControlBridgeError.unverifiedLoopbackPeer
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
      throw WaveLinkControlBridgeError.protocolViolation(
        "The loopback listener inspection was not UTF-8."
      )
    }
    return parseListenerPIDs(output)
  }
}

private actor WaveLinkJSONRPCTransport {
  private struct RPCErrorPayload: Decodable {
    let code: Int?
    let message: String?
  }

  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var nextRequestID = 1

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    session = URLSession(configuration: configuration)
  }

  func request(method: String, params: Data?) async throws -> Data {
    let socket = connectedSocket()
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
      self.socket?.cancel(with: .goingAway, reason: nil)
      self.socket = nil
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

  private func connectedSocket() -> URLSessionWebSocketTask {
    if let socket { return socket }
    var request = URLRequest(url: URL(string: "ws://127.0.0.1:1884")!)
    request.setValue("streamdeck://", forHTTPHeaderField: "Origin")
    let socket = session.webSocketTask(with: request)
    socket.resume()
    self.socket = socket
    return socket
  }
}
