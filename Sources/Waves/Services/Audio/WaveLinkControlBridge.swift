import Foundation
import OSLog
import WavesAudioCore

protocol WaveLinkControlling: Sendable {
  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) async throws -> WaveLinkControlConfirmation

  /// `allowsChannelRelocation` permits moving the app onto an empty software
  /// channel when it does not already have one of its own. Automation must
  /// pass `false`: silently re-routing an app inside Wave Link changes what
  /// the stream and monitor mixes hear, which only a deliberate user gesture
  /// may do.
  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool,
    allowsChannelRelocation: Bool
  ) async throws -> WaveLinkControlConfirmation

  /// Read-only connection test: handshake plus a channel listing, recorded in
  /// the returned status. Never mutates Wave Link.
  func inspect() async -> WaveLinkBridgeStatus

  /// The status recorded by the most recent exchange, without talking to
  /// Wave Link.
  func currentStatus() async -> WaveLinkBridgeStatus
}

extension WaveLinkControlling {
  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool,
    allowsChannelRelocation: Bool
  ) async throws -> WaveLinkControlConfirmation {
    try await apply(bundleIdentifier: bundleIdentifier, volume: volume, isMuted: isMuted)
  }

  func inspect() async -> WaveLinkBridgeStatus { .idle }

  func currentStatus() async -> WaveLinkBridgeStatus { .idle }
}

struct WaveLinkControlConfirmation: Equatable, Sendable {
  let channelID: String
  let channelName: String
  let appliedVolume: Float
  let isMuted: Bool
  /// True when this apply moved the app onto its own channel.
  var relocated: Bool = false
}

enum WaveLinkControlBridgeError: Error, Equatable, LocalizedError, Sendable {
  case invalidBundleIdentifier
  case invalidVolume
  case unavailable(String)
  case incompatibleApplication
  case unverifiedLoopbackPeer
  case dedicatedChannelRequired(String)
  case relocationNotPermitted(String)
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
      "The control service that answered is not a compatible Elgato Wave Link 3."
    case .unverifiedLoopbackPeer:
      "The running Wave Link is not signed by Elgato, so Waves will not send it commands."
    case .dedicatedChannelRequired(let appID):
      "Every Wave Link software channel already holds an app, so \(appID) cannot get its own level. In Wave Link, give it a channel of its own or empty one."
    case .relocationNotPermitted(let appID):
      "\(appID) shares a Wave Link channel with other apps. Waves only moves an app to its own Wave Link channel when you change its level yourself."
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
  var version: String?

  init(interfaceRevision: Int, appID: String, name: String?, version: String? = nil) {
    self.interfaceRevision = interfaceRevision
    self.appID = appID
    self.name = name
    self.version = version
  }

  /// Wave Link 3 reset its protocol: `appID` is "EWL" and `interfaceRevision`
  /// restarted at 1, the value 3.0 through 3.2 report and the gate the
  /// official Stream Deck plugin applies. Earlier generations answer "egwl"
  /// with revisions 6-7 and a different method set, and are rejected.
  var isSupportedWaveLink3: Bool {
    appID == "EWL" && interfaceRevision >= 1
  }
}

struct WaveLinkChannelApp: Codable, Equatable, Sendable {
  let id: String
  var name: String?

  init(id: String, name: String? = nil) {
    self.id = id
    self.name = name
  }
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
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    level = try container.decodeIfPresent(Float.self, forKey: .level) ?? 1
    isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    // Hardware channels omit `apps` entirely; software channels list them.
    apps = try container.decodeIfPresent([WaveLinkChannelApp].self, forKey: .apps) ?? []
  }

  var isSoftware: Bool {
    type.caseInsensitiveCompare("software") == .orderedSame
  }

  func holds(_ bundleIdentifier: String) -> Bool {
    apps.contains { $0.id.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
  }

  var statusSummary: WaveLinkBridgeStatus.ChannelSummary {
    WaveLinkBridgeStatus.ChannelSummary(
      id: id,
      name: name,
      isSoftware: isSoftware,
      appIdentifiers: apps.map(\.id),
      level: level,
      isMuted: isMuted
    )
  }
}

struct WaveLinkChannelsResponse: Codable, Equatable, Sendable {
  let channels: [WaveLinkChannel]
}

/// Where the production session is connected, for status reporting.
struct WaveLinkConnectionDescription: Equatable, Sendable {
  let endpoint: String
  let processIdentifier: pid_t
}

actor WaveLinkControlBridge: WaveLinkControlling {
  typealias Request = @Sendable (_ method: String, _ params: Data?) async throws -> Data
  typealias PeerValidator = @Sendable () async throws -> Void
  typealias SequenceFinalizer = @Sendable () async -> Void
  typealias ConnectionDescriber = @Sendable () async -> WaveLinkConnectionDescription?

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

  private static let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "WaveLinkBridge")

  private let request: Request
  private let validatePeer: PeerValidator
  private let finishSequence: SequenceFinalizer
  private let describeConnection: ConnectionDescriber
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private var status: WaveLinkBridgeStatus = .idle
  /// Tail of the strictly serialized queue of sequences on this bridge, so a
  /// Settings connection test can never interleave with an in-flight apply on
  /// the shared control socket.
  private var sequenceTail: Task<Void, Never>?

  init(
    request: @escaping Request,
    validatePeer: @escaping PeerValidator = {},
    finishSequence: @escaping SequenceFinalizer = {},
    describeConnection: @escaping ConnectionDescriber = { nil }
  ) {
    self.request = request
    self.validatePeer = validatePeer
    self.finishSequence = finishSequence
    self.describeConnection = describeConnection
  }

  init() {
    // One session owns discovery, peer verification, the socket, and the
    // handshake, so the transport destination and the verified peer can never
    // disagree.
    let session = WaveLinkLoopbackSession()
    self.request = { method, params in
      try await session.request(method: method, params: params)
    }
    self.validatePeer = {
      _ = try await session.connect()
    }
    self.finishSequence = {
      await session.endSequence()
    }
    self.describeConnection = {
      await session.connectionDescription
    }
  }

  /// Declared `async` to match the protocol requirement exactly: a synchronous
  /// actor method with the same name loses overload resolution to the
  /// protocol extension's default at async call sites, which would hand every
  /// caller the static idle value instead of the recorded status.
  func currentStatus() async -> WaveLinkBridgeStatus {
    status
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool
  ) async throws -> WaveLinkControlConfirmation {
    try await apply(
      bundleIdentifier: bundleIdentifier,
      volume: volume,
      isMuted: isMuted,
      allowsChannelRelocation: true
    )
  }

  func apply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool,
    allowsChannelRelocation: Bool
  ) async throws -> WaveLinkControlConfirmation {
    try await serialized {
      do {
        let confirmation = try await self.performApply(
          bundleIdentifier: bundleIdentifier,
          volume: volume,
          isMuted: isMuted,
          allowsChannelRelocation: allowsChannelRelocation
        )
        await self.finishSequence()
        return confirmation
      } catch {
        await self.recordFailure(error)
        await self.finishSequence()
        throw error
      }
    }
  }

  func inspect() async -> WaveLinkBridgeStatus {
    // The body records its own outcome and never throws, so the sequence
    // itself cannot fail; `try?` only satisfies the serialized signature.
    _ = try? await serialized { () async throws -> Void in
      do {
        try await self.validatePeer()
        let applicationInfo = try await self.handshake()
        let channels = try await self.readChannels()
        await self.recordSuccess(applicationInfo: applicationInfo, channels: channels)
        Self.logger.info(
          "Connection test succeeded: \(applicationInfo.name ?? "Wave Link", privacy: .public) \(applicationInfo.version ?? "", privacy: .public), \(channels.count) channels"
        )
      } catch {
        await self.recordFailure(error)
      }
      await self.finishSequence()
    }
    return status
  }

  // MARK: - Sequences

  private func serialized<Value: Sendable>(
    _ body: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let previous = sequenceTail
    let (finished, continuation) = AsyncStream<Void>.makeStream()
    sequenceTail = Task { for await _ in finished {} }
    defer { continuation.finish() }
    if let previous {
      await previous.value
    }
    return try await body()
  }

  private func performApply(
    bundleIdentifier: String,
    volume: Float,
    isMuted: Bool,
    allowsChannelRelocation: Bool
  ) async throws -> WaveLinkControlConfirmation {
    guard !bundleIdentifier.isEmpty else {
      throw WaveLinkControlBridgeError.invalidBundleIdentifier
    }
    guard volume.isFinite, (0...1).contains(volume) else {
      throw WaveLinkControlBridgeError.invalidVolume
    }

    try await validatePeer()
    let applicationInfo = try await handshake()

    var channels = try await readChannels()
    let matchingChannels = channels.filter { $0.isSoftware && $0.holds(bundleIdentifier) }

    let targetChannel: WaveLinkChannel
    var relocated = false
    if matchingChannels.count == 1,
      let dedicated = matchingChannels.first,
      dedicated.apps.count == 1
    {
      targetChannel = dedicated
    } else {
      guard allowsChannelRelocation else {
        throw WaveLinkControlBridgeError.relocationNotPermitted(bundleIdentifier)
      }
      guard let empty = channels.first(where: { $0.isSoftware && $0.apps.isEmpty }) else {
        throw WaveLinkControlBridgeError.dedicatedChannelRequired(bundleIdentifier)
      }
      Self.logger.info(
        "Moving \(bundleIdentifier, privacy: .public) to empty Wave Link channel \(empty.name, privacy: .public)"
      )
      let addRequest = AddToChannelRequest(appID: bundleIdentifier, channelID: empty.id)
      _ = try await request("addToChannel", try encoder.encode(addRequest))
      channels = try await readChannels()
      let movedMatches = channels.filter { $0.isSoftware && $0.holds(bundleIdentifier) }
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
      relocated = true
    }

    let setRequest = SetChannelRequest(id: targetChannel.id, level: volume, isMuted: isMuted)
    _ = try await request("setChannel", try encoder.encode(setRequest))

    let confirmedChannels = try await readChannels()
    let confirmedMatches = confirmedChannels.filter { $0.isSoftware && $0.holds(bundleIdentifier) }
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

    await recordSuccess(applicationInfo: applicationInfo, channels: confirmedChannels)
    Self.logger.debug(
      "Applied level \(volume, privacy: .public) muted \(isMuted, privacy: .public) to \(bundleIdentifier, privacy: .public) on channel \(confirmed.name, privacy: .public)"
    )
    return WaveLinkControlConfirmation(
      channelID: confirmed.id,
      channelName: confirmed.name,
      appliedVolume: confirmed.level,
      isMuted: confirmed.isMuted,
      relocated: relocated
    )
  }

  private func handshake() async throws -> WaveLinkApplicationInfo {
    let applicationInfoData = try await request("getApplicationInfo", nil)
    let applicationInfo = try decode(WaveLinkApplicationInfo.self, from: applicationInfoData)
    guard applicationInfo.isSupportedWaveLink3 else {
      Self.logger.error(
        "Rejected control peer appID=\(applicationInfo.appID, privacy: .public) revision=\(applicationInfo.interfaceRevision, privacy: .public)"
      )
      throw WaveLinkControlBridgeError.incompatibleApplication
    }
    return applicationInfo
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
      let excerpt = String(decoding: data.prefix(160), as: UTF8.self)
      Self.logger.error(
        "Could not decode \(String(describing: type), privacy: .public): \(error.localizedDescription, privacy: .public) from \(excerpt, privacy: .private)"
      )
      throw WaveLinkControlBridgeError.protocolViolation(error.localizedDescription)
    }
  }

  // MARK: - Status

  private func recordSuccess(
    applicationInfo: WaveLinkApplicationInfo,
    channels: [WaveLinkChannel]
  ) async {
    let connection = await describeConnection()
    let now = Date()
    status.phase = .connected
    status.endpoint = connection?.endpoint
    status.processIdentifier = connection?.processIdentifier
    status.applicationName = applicationInfo.name
    status.applicationVersion = applicationInfo.version
    status.interfaceRevision = applicationInfo.interfaceRevision
    status.channels = channels.map(\.statusSummary)
    status.lastError = nil
    status.lastSuccessAt = now
    status.updatedAt = now
  }

  private func recordFailure(_ error: Error) async {
    let now = Date()
    status.phase = .failed
    status.lastError = error.localizedDescription
    status.lastFailureAt = now
    status.updatedAt = now
    Self.logger.error("Bridge sequence failed: \(error.localizedDescription, privacy: .public)")
  }
}

// MARK: - Loopback session

/// Owns the WebSocket to the verified Wave Link 3 process: discovery of its
/// control port, the protocol handshake that proves a port is the control
/// service, and the socket's lifetime. The socket is kept open briefly after a
/// sequence so a slider drag reuses one connection, then closed while idle so
/// a Wave Link restart on a new port is picked up by the next sequence.
actor WaveLinkLoopbackSession {
  private static let maximumMessageBytes = 1_048_576
  private static let maximumResponseBytes = 4 * 1_048_576
  private static let maximumResponseMessages = 64

  typealias CandidateProvider = @Sendable () throws -> [WaveLinkEndpointDiscovery.Listener]

  struct Connection: Equatable, Sendable {
    let endpoint: WaveLinkEndpointDiscovery.Listener
    let applicationInfo: WaveLinkApplicationInfo

    var description: WaveLinkConnectionDescription {
      WaveLinkConnectionDescription(
        endpoint: "127.0.0.1:\(endpoint.port)",
        processIdentifier: endpoint.pid
      )
    }
  }

  private struct RPCErrorPayload: Decodable {
    let code: Int?
    let message: String?
  }

  private static let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "WaveLinkBridge")

  private let candidateProvider: CandidateProvider
  private let urlSession: URLSession
  private let receiveTimeout: Duration
  private let idleCloseDelay: Duration
  private var socket: URLSessionWebSocketTask?
  private var connection: Connection?
  private var nextRequestID = 1
  private var activeRequests = 0
  private var idleCloseTask: Task<Void, Never>?
  private var connectionGeneration: UInt64 = 0

  init(
    candidateProvider: @escaping CandidateProvider = { try WaveLinkEndpointDiscovery.liveCandidates() },
    receiveTimeout: Duration = .seconds(3),
    idleCloseDelay: Duration = .seconds(2)
  ) {
    // Only the connect handshake gets a session timeout. A resource lifetime
    // limit would tear the socket down mid-sequence. Each request instead gets
    // one deadline covering its send and all response messages.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    urlSession = URLSession(configuration: configuration)
    self.candidateProvider = candidateProvider
    self.receiveTimeout = receiveTimeout
    self.idleCloseDelay = idleCloseDelay
  }

  var connectionDescription: WaveLinkConnectionDescription? {
    connection?.description
  }

  /// Returns the live connection, establishing one when needed. Every
  /// candidate port must answer `getApplicationInfo` as Wave Link 3 before it
  /// is accepted; the first that does becomes the connection.
  @discardableResult
  func connect() async throws -> Connection {
    try Task.checkCancellation()
    cancelIdleClose()
    if let connection, socket != nil { return connection }
    closeSocket(with: .goingAway)

    let candidateProvider = self.candidateProvider
    let candidates = try await Task.detached(priority: .utility) {
      try candidateProvider()
    }.value
    try Task.checkCancellation()

    var rejections: [String] = []
    for candidate in candidates {
      try Task.checkCancellation()
      let socket = openSocket(port: candidate.port)
      do {
        let data = try await performRequest(method: "getApplicationInfo", params: nil, on: socket)
        let info = try JSONDecoder().decode(WaveLinkApplicationInfo.self, from: data)
        guard info.isSupportedWaveLink3 else {
          rejections.append("port \(candidate.port) answered as \(info.appID) revision \(info.interfaceRevision)")
          socket.cancel(with: .normalClosure, reason: nil)
          continue
        }
        self.socket = socket
        connectionGeneration &+= 1
        let connection = Connection(endpoint: candidate, applicationInfo: info)
        self.connection = connection
        Self.logger.info(
          "Connected to \(info.name ?? "Wave Link", privacy: .public) \(info.version ?? "", privacy: .public) on 127.0.0.1:\(candidate.port, privacy: .public) (pid \(candidate.pid, privacy: .public))"
        )
        return connection
      } catch {
        if error is CancellationError || Task.isCancelled {
          socket.cancel(with: .abnormalClosure, reason: nil)
          throw CancellationError()
        }
        rejections.append("port \(candidate.port): \(error.localizedDescription)")
        socket.cancel(with: .abnormalClosure, reason: nil)
      }
    }
    let detail =
      rejections.isEmpty
      ? "Wave Link 3 has no open control port."
      : "No Wave Link control port accepted the handshake (\(rejections.joined(separator: "; ")))."
    Self.logger.error("\(detail, privacy: .public)")
    throw WaveLinkControlBridgeError.unavailable(detail)
  }

  func request(method: String, params: Data?) async throws -> Data {
    cancelIdleClose()
    let socket: URLSessionWebSocketTask
    if let existing = self.socket {
      socket = existing
    } else {
      try await connect()
      guard let connected = self.socket else {
        throw WaveLinkControlBridgeError.unavailable("The control connection closed before the request was sent.")
      }
      socket = connected
    }
    activeRequests += 1
    defer { activeRequests -= 1 }
    do {
      return try await performRequest(method: method, params: params, on: socket)
    } catch {
      // Never keep a socket that produced any failure; the next sequence
      // rediscovers the port, which is what a Wave Link restart requires.
      closeSocket(with: .abnormalClosure)
      throw error
    }
  }

  /// Ends one sequence. The socket stays open for `idleCloseDelay` so the
  /// next sequence of a drag reuses it, then closes on its own.
  func endSequence() {
    cancelIdleClose()
    guard socket != nil else { return }
    let generation = connectionGeneration
    let delay = idleCloseDelay
    idleCloseTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.closeIfIdle(generation: generation)
    }
  }

  func close() {
    cancelIdleClose()
    closeSocket(with: .goingAway)
  }

  private func closeIfIdle(generation: UInt64) {
    guard !Task.isCancelled, activeRequests == 0, connectionGeneration == generation else { return }
    closeSocket(with: .goingAway)
  }

  private func cancelIdleClose() {
    idleCloseTask?.cancel()
    idleCloseTask = nil
  }

  private func closeSocket(with code: URLSessionWebSocketTask.CloseCode) {
    socket?.cancel(with: code, reason: nil)
    socket = nil
    connection = nil
  }

  private func openSocket(port: UInt16) -> URLSessionWebSocketTask {
    // Wave Link listens on IPv4 loopback only (its IPv6 listener answers
    // HTTP 400), and it requires the Stream Deck origin as the credential.
    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
    request.setValue("streamdeck://", forHTTPHeaderField: "Origin")
    let socket = urlSession.webSocketTask(with: request)
    socket.maximumMessageSize = Self.maximumMessageBytes
    socket.resume()
    return socket
  }

  private func performRequest(
    method: String,
    params: Data?,
    on socket: URLSessionWebSocketTask
  ) async throws -> Data {
    try Task.checkCancellation()
    let requestID = nextRequestID
    nextRequestID += 1

    // The official plugin sends an explicit null for parameterless calls.
    var payload: [String: Any] = [
      "id": requestID,
      "jsonrpc": "2.0",
      "method": method,
      "params": NSNull(),
    ]
    if let params {
      payload["params"] = try JSONSerialization.jsonObject(with: params)
    }
    let requestData = try JSONSerialization.data(withJSONObject: payload)
    guard requestData.count <= Self.maximumMessageBytes else {
      throw WaveLinkControlBridgeError.protocolViolation("The request exceeded the message byte limit.")
    }
    guard let requestText = String(data: requestData, encoding: .utf8) else {
      throw WaveLinkControlBridgeError.protocolViolation("The request was not UTF-8.")
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: receiveTimeout)
    let timeoutError = WaveLinkControlBridgeError.unavailable("Wave Link did not answer within the request time limit.")
    let maximumMessageBytes = Self.maximumMessageBytes
    let maximumResponseBytes = Self.maximumResponseBytes
    let maximumResponseMessages = Self.maximumResponseMessages

    do {
      return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: Data?.self) { group in
          defer { group.cancelAll() }
          group.addTask {
            try await socket.send(.string(requestText))
            var receivedBytes = 0
            for _ in 0..<maximumResponseMessages {
              try Task.checkCancellation()
              guard clock.now < deadline else { throw timeoutError }
              let message = try await socket.receive()
              let responseData: Data
              switch message {
              case .data(let data):
                guard data.count <= maximumMessageBytes else {
                  throw WaveLinkControlBridgeError.protocolViolation("The response exceeded the message byte limit.")
                }
                responseData = data
              case .string(let string):
                guard string.utf8.count <= maximumMessageBytes else {
                  throw WaveLinkControlBridgeError.protocolViolation("The response exceeded the message byte limit.")
                }
                responseData = Data(string.utf8)
              @unknown default:
                throw WaveLinkControlBridgeError.protocolViolation("Unknown WebSocket message type.")
              }
              guard responseData.count <= maximumResponseBytes - receivedBytes else {
                throw WaveLinkControlBridgeError.protocolViolation("The response exceeded the aggregate byte limit.")
              }
              receivedBytes += responseData.count
              // Notifications and wrong IDs consume the same request budget.
              guard
                let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                (object["id"] as? NSNumber)?.intValue == requestID
              else { continue }
              if let errorObject = object["error"] {
                let errorData = try JSONSerialization.data(withJSONObject: errorObject)
                let errorPayload = try? JSONDecoder().decode(RPCErrorPayload.self, from: errorData)
                let detail = errorPayload?.message ?? "JSON-RPC error \(errorPayload?.code ?? -1)"
                throw WaveLinkControlBridgeError.unavailable("\(method): \(detail)")
              }
              guard let result = object["result"] else {
                throw WaveLinkControlBridgeError.protocolViolation("Missing JSON-RPC result for \(method).")
              }
              guard clock.now < deadline else { throw timeoutError }
              if result is NSNull { return Data("{}".utf8) }
              return try JSONSerialization.data(withJSONObject: result)
            }
            throw WaveLinkControlBridgeError.protocolViolation("The response exceeded the message-count limit.")
          }
          group.addTask {
            try await clock.sleep(until: deadline)
            return nil
          }
          guard let completion = try await group.next() else {
            throw WaveLinkControlBridgeError.unavailable("The control connection closed unexpectedly.")
          }
          try Task.checkCancellation()
          guard let response = completion else {
            socket.cancel(with: .abnormalClosure, reason: nil)
            throw timeoutError
          }
          return response
        }
      } onCancel: {
        socket.cancel(with: .abnormalClosure, reason: nil)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as WaveLinkControlBridgeError {
      if Task.isCancelled { throw CancellationError() }
      throw error
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw WaveLinkControlBridgeError.unavailable("\(method): \(error.localizedDescription)")
    }
  }
}
