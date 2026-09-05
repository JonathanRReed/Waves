import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Waves

@Test func waveLinkDiscoveryParsesOnlyValidWSInfoPorts() {
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 1884}"#.utf8)) == 1_884)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 49204}"#.utf8)) == 49_204)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 0}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": 65536}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": -5}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data(#"{"port": "1884"}"#.utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data("not json".utf8)) == nil)
  #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: Data("{}".utf8)) == nil)
}

@Test func waveLinkDiscoveryChecksThePostSandboxWSInfoLocationFirst() {
  let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
  let urls = WaveLinkEndpointDiscovery.wsInfoCandidateURLs(homeDirectory: home)
  #expect(
    urls.map(\.path) == [
      "/Users/example/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
      "/Users/example/Library/Containers/com.elgato.WaveLink3/Data/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
    ]
  )
}

@Test func waveLinkDiscoveryReadsEveryPublishedPortInLocationOrder() throws {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-ws-info-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: home) }
  let urls = WaveLinkEndpointDiscovery.wsInfoCandidateURLs(homeDirectory: home)
  for (url, body) in zip(urls, [#"{"port": 53832}"#, #"{"port": 1884}"#]) {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(body.utf8).write(to: url)
  }

  #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [53_832, 1_884])

  // A stale or unreadable file is ordinary and simply contributes no hint.
  try Data("garbage".utf8).write(to: urls[0])
  #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [1_884])
  try FileManager.default.removeItem(at: urls[1])
  #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [])
}

@Test func waveLinkDiscoveryOrdersPublishedPortsFirstThenAscending() {
  let listeners: [WaveLinkEndpointDiscovery.Listener] = [
    .init(pid: 1_366, port: 60_001),
    .init(pid: 1_366, port: 53_832),
    .init(pid: 1_366, port: 1_884),
    .init(pid: 1_366, port: 53_832),
  ]

  let ordered = WaveLinkEndpointDiscovery.orderedCandidates(
    listeners: listeners,
    publishedPorts: [53_832, 40_000]
  )
  #expect(
    ordered == [
      .init(pid: 1_366, port: 53_832),
      .init(pid: 1_366, port: 1_884),
      .init(pid: 1_366, port: 60_001),
    ]
  )

  let unpublished = WaveLinkEndpointDiscovery.orderedCandidates(listeners: listeners, publishedPorts: [])
  #expect(unpublished.map(\.port) == [1_884, 53_832, 60_001])
}

@Test func waveLinkDiscoveryAcceptsOnlyPIDsThatVerifyAsWaveLink() {
  let verifyOnly1366: WaveLinkEndpointDiscovery.IdentityVerifier = { pid, descriptor in
    guard pid == 1_366 else { return nil }
    return VerifiedRouterProcessIdentity(
      pid: pid,
      teamIdentifier: descriptor.teamIdentifier,
      matchesDesignatedRequirement: true
    )
  }
  let wrongTeam: WaveLinkEndpointDiscovery.IdentityVerifier = { pid, _ in
    VerifiedRouterProcessIdentity(pid: pid, teamIdentifier: "WRONGTEAM", matchesDesignatedRequirement: true)
  }
  let requirementMismatch: WaveLinkEndpointDiscovery.IdentityVerifier = { pid, descriptor in
    VerifiedRouterProcessIdentity(
      pid: pid,
      teamIdentifier: descriptor.teamIdentifier,
      matchesDesignatedRequirement: false
    )
  }

  #expect(
    WaveLinkEndpointDiscovery.verifiedProcessIdentifiers(
      runningPIDs: [99, 1_366, 7],
      identityVerifier: verifyOnly1366
    ) == [1_366]
  )
  #expect(
    WaveLinkEndpointDiscovery.verifiedProcessIdentifiers(runningPIDs: [1_366], identityVerifier: wrongTeam)
      .isEmpty
  )
  #expect(
    WaveLinkEndpointDiscovery.verifiedProcessIdentifiers(
      runningPIDs: [1_366],
      identityVerifier: requirementMismatch
    ).isEmpty
  )
}

@Test func waveLinkDiscoveryReadsAProcessesListeningPortsFromTheKernel() throws {
  // A real listener owned by this test process, on a port the kernel picks.
  let listener = try TestTCPListener()
  defer { listener.close() }

  let ports = WaveLinkEndpointDiscovery.listeningTCPPorts(ofPID: ProcessInfo.processInfo.processIdentifier)
  #expect(ports.contains(listener.port))
  #expect(ports == ports.sorted())
  #expect(WaveLinkEndpointDiscovery.listeningTCPPorts(ofPID: -1).isEmpty)
}

@Test func waveLinkSessionAcceptsTheFirstCandidateThatAnswersAsWaveLink3() async throws {
  let waveLink = try TestJSONRPCServer(
    applicationInfo: #"{"appID":"EWL","interfaceRevision":1,"name":"Elgato Wave Link","version":"3.2.2"}"#
  )
  defer { waveLink.close() }
  let impostor = try TestJSONRPCServer(applicationInfo: #"{"appID":"egwl","interfaceRevision":7}"#)
  defer { impostor.close() }

  let session = WaveLinkLoopbackSession(
    candidateProvider: {
      [
        .init(pid: 1, port: impostor.port),
        .init(pid: 1, port: waveLink.port),
      ]
    },
    receiveTimeout: .seconds(3),
    idleCloseDelay: .milliseconds(50)
  )

  let connection = try await session.connect()
  #expect(connection.endpoint.port == waveLink.port)
  #expect(connection.applicationInfo.version == "3.2.2")
  #expect(await session.connectionDescription?.endpoint == "127.0.0.1:\(waveLink.port)")

  // Requests reuse the accepted socket, and notifications on it are skipped.
  let data = try await session.request(method: "getChannels", params: nil)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect((object["channels"] as? [Any])?.isEmpty == true)
  #expect(waveLink.receivedMethods == ["getApplicationInfo", "getChannels"])
  #expect(waveLink.lastOrigin == "streamdeck://")

  await session.endSequence()
  try await Task.sleep(for: .milliseconds(300))
  #expect(await session.connectionDescription == nil)
}

@Test func waveLinkSessionFailsClosedWhenNoCandidateAnswersAsWaveLink3() async throws {
  let impostor = try TestJSONRPCServer(applicationInfo: #"{"appID":"egwl","interfaceRevision":7}"#)
  defer { impostor.close() }
  let session = WaveLinkLoopbackSession(
    candidateProvider: { [.init(pid: 1, port: impostor.port)] },
    receiveTimeout: .seconds(2),
    idleCloseDelay: .milliseconds(50)
  )
  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await session.connect()
  }
  #expect(await session.connectionDescription == nil)

  let nothing = WaveLinkLoopbackSession(
    candidateProvider: { throw WaveLinkControlBridgeError.unavailable("Wave Link 3 is not running.") },
    receiveTimeout: .seconds(2),
    idleCloseDelay: .milliseconds(50)
  )
  await #expect(throws: WaveLinkControlBridgeError.unavailable("Wave Link 3 is not running.")) {
    try await nothing.request(method: "getChannels", params: nil)
  }
}

@Test func waveLinkSessionUsesOneDeadlineAcrossUnmatchedNotifications() async throws {
  let server = try TestJSONRPCServer(
    getChannelsBehavior: .notificationsThenReply(count: 17, payloadBytes: 0, intervalMicroseconds: 50_000)
  )
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server, receiveTimeout: .milliseconds(150))
  try await session.connect()
  let started = ContinuousClock.now

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await session.request(method: "getChannels", params: nil)
  }
  #expect(await session.connectionDescription == nil)
  #expect(started.duration(to: ContinuousClock.now) < .milliseconds(600))
}

@Test func waveLinkSessionRejectsMoreThan64MessagesForOneRequest() async throws {
  let server = try TestJSONRPCServer(
    getChannelsBehavior: .notificationsThenReply(count: 65, payloadBytes: 0, intervalMicroseconds: 0)
  )
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server)

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await session.request(method: "getChannels", params: nil)
  }
  #expect(await session.connectionDescription == nil)
}

@Test func waveLinkSessionRejectsMoreThan4MiBForOneResponse() async throws {
  let server = try TestJSONRPCServer(
    getChannelsBehavior: .notificationsThenReply(count: 5, payloadBytes: 900_000, intervalMicroseconds: 0)
  )
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server)

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await session.request(method: "getChannels", params: nil)
  }
  #expect(await session.connectionDescription == nil)
}

@Test func waveLinkSessionRejectsAWebSocketMessageLargerThan1MiB() async throws {
  let server = try TestJSONRPCServer(
    getChannelsBehavior: .notificationsThenReply(count: 1, payloadBytes: 1_048_577, intervalMicroseconds: 0)
  )
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server)

  await #expect(throws: WaveLinkControlBridgeError.self) {
    try await session.request(method: "getChannels", params: nil)
  }
  #expect(await session.connectionDescription == nil)
}

@Test func waveLinkSessionPreservesCancellationAndClearsItsConnection() async throws {
  let server = try TestJSONRPCServer(getChannelsBehavior: .delayedReply(microseconds: 800_000))
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server)
  let request = Task {
    try await session.request(method: "getChannels", params: nil)
  }

  try await server.waitUntilReceived(method: "getChannels")
  let cancelledAt = ContinuousClock.now
  request.cancel()
  do {
    _ = try await request.value
    Issue.record("Expected the request to be cancelled")
  } catch is CancellationError {
    // Cancellation is a control-flow signal and must not be wrapped.
  } catch {
    Issue.record("Expected CancellationError, got \(error)")
  }
  #expect(await session.connectionDescription == nil)
  #expect(cancelledAt.duration(to: ContinuousClock.now) < .milliseconds(600))
}

@Test func waveLinkSessionAcceptsAReplyAtTheMessageCountLimit() async throws {
  let server = try TestJSONRPCServer(
    getChannelsBehavior: .notificationsThenReply(count: 63, payloadBytes: 0, intervalMicroseconds: 0)
  )
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server)
  let data = try await session.request(method: "getChannels", params: nil)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect((object["channels"] as? [Any])?.isEmpty == true)
}

@Test func waveLinkSessionStillAcceptsNotificationsBeforeItsReply() async throws {
  let server = try TestJSONRPCServer(
    getChannelsBehavior: .notificationsThenReply(count: 4, payloadBytes: 32, intervalMicroseconds: 10_000)
  )
  defer { server.close() }
  let session = makeTestWaveLinkSession(server: server, receiveTimeout: .seconds(1))

  let data = try await session.request(method: "getChannels", params: nil)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect((object["channels"] as? [Any])?.isEmpty == true)
}

private func makeTestWaveLinkSession(
  server: TestJSONRPCServer,
  receiveTimeout: Duration = .seconds(3)
) -> WaveLinkLoopbackSession {
  WaveLinkLoopbackSession(
    candidateProvider: { [.init(pid: 1, port: server.port)] },
    receiveTimeout: receiveTimeout,
    idleCloseDelay: .milliseconds(50)
  )
}

// MARK: - Test servers

/// A bare TCP listener so the kernel port enumeration has something real to
/// find.
private final class TestTCPListener {
  let port: UInt16
  private let socket: Int32

  init() throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EADDRINUSE)
    }
    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &boundAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard named == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EIO)
    }
    socket = descriptor
    port = UInt16(bigEndian: boundAddress.sin_port)
  }

  func close() {
    Darwin.close(socket)
  }
}

/// A minimal WebSocket JSON-RPC server that answers `getApplicationInfo` with
/// a configurable payload, applies bounded test behavior to `getChannels`,
/// and records what it saw.
private final class TestJSONRPCServer: @unchecked Sendable {
  enum GetChannelsBehavior {
    case notificationsThenReply(count: Int, payloadBytes: Int, intervalMicroseconds: useconds_t)
    case delayedReply(microseconds: useconds_t)
  }

  let port: UInt16
  var receivedMethods: [String] { lock.withLock { recordedMethods } }
  var lastOrigin: String? { lock.withLock { recordedOrigin } }
  private let applicationInfo: String
  private let getChannelsBehavior: GetChannelsBehavior
  private let listener: Int32
  private let queue = DispatchQueue(label: "waves.tests.wavelink-server")
  private let workers = DispatchGroup()
  private let lock = NSLock()
  private var recordedMethods: [String] = []
  private var recordedOrigin: String?
  private var clients: [Int32] = []
  private var closed = false

  init(
    applicationInfo: String = #"{"appID":"EWL","interfaceRevision":1,"name":"Elgato Wave Link","version":"3.2.2"}"#,
    getChannelsBehavior: GetChannelsBehavior = .notificationsThenReply(
      count: 1,
      payloadBytes: 0,
      intervalMicroseconds: 0
    )
  ) throws {
    self.applicationInfo = applicationInfo
    self.getChannelsBehavior = getChannelsBehavior
    let tcp = try TestTCPListener()
    listener = tcp.socketDescriptorForServer
    port = tcp.port
    let flags = fcntl(listener, F_GETFL)
    guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0 else {
      Darwin.close(listener)
      throw POSIXError(.EIO)
    }
    workers.enter()
    queue.async { [self] in
      acceptLoop()
      workers.leave()
    }
  }

  func close() {
    let clients: [Int32]? = lock.withLock {
      guard !closed else { return nil }
      closed = true
      return self.clients
    }
    guard let clients else { return }
    Darwin.shutdown(listener, SHUT_RDWR)
    for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
    guard workers.wait(timeout: .now() + 5) == .success else {
      Issue.record("The local WebSocket fixture did not stop within five seconds.")
      return
    }
    Darwin.close(listener)
    for client in lock.withLock({ self.clients }) { Darwin.close(client) }
  }

  func waitUntilReceived(method: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while !receivedMethods.contains(method) {
      guard clock.now < deadline else {
        throw POSIXError(.ETIMEDOUT)
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func acceptLoop() {
    while !lock.withLock({ closed }) {
      var address = sockaddr()
      var length = socklen_t(MemoryLayout<sockaddr>.size)
      let client = accept(listener, &address, &length)
      guard client >= 0 else {
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
          usleep(10_000)
          continue
        }
        return
      }
      lock.lock()
      if closed {
        lock.unlock()
        Darwin.close(client)
        return
      }
      let clientFlags = fcntl(client, F_GETFL)
      guard clientFlags >= 0, fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0 else {
        lock.unlock()
        Darwin.close(client)
        continue
      }
      var noSIGPIPE: Int32 = 1
      _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout.size(ofValue: noSIGPIPE)))
      clients.append(client)
      lock.unlock()
      workers.enter()
      DispatchQueue.global().async { [self] in
        serve(client)
        workers.leave()
      }
    }
  }

  private func serve(_ client: Int32) {
    guard let request = readHTTPRequest(client) else { return }
    let headers = request.split(separator: "\r\n").dropFirst()
    var key: String?
    for header in headers {
      let parts = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2 else { continue }
      switch parts[0].lowercased() {
      case "sec-websocket-key": key = parts[1]
      case "origin":
        lock.withLock { recordedOrigin = parts[1] }
      default: break
      }
    }
    guard let key else { return }
    let accept = TestWebSocketFraming.acceptKey(for: key)
    let response =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
    guard TestWebSocketFraming.writeAll(Data(response.utf8), to: client) else { return }

    while let text = TestWebSocketFraming.readTextFrame(from: client) {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let method = object["method"] as? String
      else { continue }
      lock.withLock { recordedMethods.append(method) }
      let id = object["id"] ?? NSNull()
      let result: String
      switch method {
      case "getApplicationInfo": result = applicationInfo
      case "getChannels":
        guard performGetChannelsBehavior(on: client) else { return }
        result = #"{"channels":[]}"#
      default: result = "{}"
      }
      let idText = (id as? NSNumber).map { "\($0)" } ?? "null"
      _ = TestWebSocketFraming.writeTextFrame(
        #"{"jsonrpc":"2.0","id":\#(idText),"result":\#(result)}"#,
        to: client
      )
    }
  }

  private func performGetChannelsBehavior(on client: Int32) -> Bool {
    switch getChannelsBehavior {
    case .notificationsThenReply(let count, let payloadBytes, let intervalMicroseconds):
      let payload = String(repeating: "x", count: payloadBytes)
      let notification =
        #"{"jsonrpc":"2.0","method":"channelChanged","params":{"payload":"\#(payload)"}}"#
      for index in 0..<count {
        guard TestWebSocketFraming.writeTextFrame(notification, to: client) else { return false }
        if intervalMicroseconds > 0, index + 1 < count { usleep(intervalMicroseconds) }
      }
      return true
    case .delayedReply(let microseconds):
      usleep(microseconds)
      return true
    }
  }

  private func readHTTPRequest(_ client: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: 8_192)
    var collected = Data()
    while true {
      let read = recv(client, &buffer, buffer.count, 0)
      guard read > 0 else { return nil }
      collected.append(buffer, count: read)
      if let text = String(data: collected, encoding: .utf8), text.contains("\r\n\r\n") {
        return text
      }
      if collected.count > 65_536 { return nil }
    }
  }
}

extension TestTCPListener {
  /// Hands the listening descriptor to a server that will own and close it.
  fileprivate var socketDescriptorForServer: Int32 {
    socket
  }
}

private enum TestWebSocketFraming {
  static func acceptKey(for key: String) -> String {
    let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
    return Data(digest).base64EncodedString()
  }

  static func readTextFrame(from client: Int32) -> String? {
    guard let header = readExactly(2, from: client) else { return nil }
    let opcode = header[0] & 0x0F
    let masked = header[1] & 0x80 != 0
    var length = Int(header[1] & 0x7F)
    if length == 126 {
      guard let extended = readExactly(2, from: client) else { return nil }
      length = Int(extended[0]) << 8 | Int(extended[1])
    } else if length == 127 {
      guard let extended = readExactly(8, from: client) else { return nil }
      length = extended.reduce(0) { $0 << 8 | Int($1) }
    }
    var mask: [UInt8] = []
    if masked {
      guard let read = readExactly(4, from: client) else { return nil }
      mask = read
    }
    guard let payload = readExactly(length, from: client) else { return nil }
    let unmasked = masked ? payload.enumerated().map { $0.element ^ mask[$0.offset % 4] } : payload
    switch opcode {
    case 0x1: return String(decoding: unmasked, as: UTF8.self)
    case 0x8: return nil
    default: return readTextFrame(from: client)
    }
  }

  static func writeTextFrame(_ text: String, to client: Int32) -> Bool {
    let payload = Array(text.utf8)
    var frame: [UInt8] = [0x81]
    if payload.count < 126 {
      frame.append(UInt8(payload.count))
    } else if payload.count <= Int(UInt16.max) {
      frame.append(126)
      frame.append(UInt8(payload.count >> 8))
      frame.append(UInt8(payload.count & 0xFF))
    } else {
      frame.append(127)
      let length = UInt64(payload.count)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
      }
    }
    frame.append(contentsOf: payload)
    return writeAll(Data(frame), to: client)
  }

  static func writeAll(_ data: Data, to client: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return true }
      var offset = 0
      while offset < bytes.count {
        let written = send(client, baseAddress.advanced(by: offset), bytes.count - offset, 0)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
      }
      return true
    }
  }

  private static func readExactly(_ count: Int, from client: Int32) -> [UInt8]? {
    guard count > 0 else { return [] }
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let read = bytes.withUnsafeMutableBufferPointer {
        recv(client, $0.baseAddress! + offset, count - offset, 0)
      }
      guard read > 0 else { return nil }
      offset += read
    }
    return bytes
  }
}
