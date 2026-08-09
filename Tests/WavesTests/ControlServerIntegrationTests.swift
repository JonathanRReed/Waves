import Darwin
import Foundation
import Testing

@testable import Waves

@MainActor
@Test(.timeLimit(.minutes(1)))
func controlServerCreatesPrivateSocketAndRecoversStaleFile() async throws {
  let fixture = await ControlSocketFixture.make()
  defer { fixture.stop() }

  try Data("stale".utf8).write(to: fixture.url)
  try fixture.server.start()

  var status = stat()
  #expect(lstat(fixture.url.path, &status) == 0)
  #expect(status.st_mode & S_IFMT == S_IFSOCK)
  #expect(status.st_mode & 0o777 == 0o600)
  #expect(fileMode(at: fixture.url.deletingLastPathComponent()) == 0o700)

  let client = try ControlSocketClient(path: fixture.url.path)
  defer { client.close() }
  try client.write("{\"id\":1,\"cmd\":\"hello\",\"protocol\":1}\n")
  let response = try await client.readLine()
  #expect(response.contains(#""ok":true"#))
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func controlServerRequiresHandshakeAndAcceptsFragmentedFrames() async throws {
  let fixture = await ControlSocketFixture.make()
  defer { fixture.stop() }
  try fixture.server.start()

  let client = try ControlSocketClient(path: fixture.url.path)
  defer { client.close() }
  try client.write("{\"id\":1,\"cmd\":\"list")
  try client.write("-apps\"}\r\n{\"id\":2,\"cmd\":\"hello\",\"protocol\":1}\n")

  let first = try await client.readLine()
  let second = try await client.readLine()
  #expect(first.contains(#""error":"malformed-request"#))
  #expect(second.contains(#""protocol":1"#))
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func controlConnectionQueuesPartialWritesAndDisconnectsOverflow() async throws {
  let fixture = await ControlSocketFixture.make()
  defer { fixture.stop() }
  try fixture.server.start()

  let client = try ControlSocketClient(path: fixture.url.path)
  defer { client.close() }
  try client.write("{\"id\":1,\"cmd\":\"hello\",\"protocol\":1}\n")
  _ = try await client.readLine()
  try client.write("{\"id\":2,\"cmd\":\"subscribe\"}\n")
  _ = try await client.readLine()

  let closeMarker = fixture.connectionCounts.mark()
  let response = ControlResponse(
    id: 3,
    ok: true,
    icon: String(repeating: "a", count: 128 * 1024)
  )
  fixture.server.broadcast(response)
  let received = try await client.readLine()
  #expect(received.contains(#""id":3"#))

  for index in 0..<32 {
    fixture.server.broadcast(
      ControlResponse(id: index, ok: true, icon: String(repeating: "b", count: 128 * 1024)))
  }
  #expect(await fixture.connectionCounts.wait(for: 0, after: closeMarker))
  #expect(fixture.server.connectionCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func controlConnectionTimesOutWithoutHandshakeButRetainsSubscriber() async throws {
  let fixture = await ControlSocketFixture.make(
    timeouts: ControlConnectionTimeouts(handshake: .milliseconds(40), idle: .milliseconds(40)))
  defer { fixture.stop() }
  try fixture.server.start()

  let unhandshakenMarker = fixture.connectionCounts.mark()
  let unhandshaken = try ControlSocketClient(path: fixture.url.path)
  defer { unhandshaken.close() }
  #expect(await fixture.connectionCounts.wait(for: 1, after: unhandshakenMarker))
  #expect(await fixture.connectionCounts.wait(for: 0, after: unhandshakenMarker))
  #expect(fixture.server.connectionCount == 0)

  let subscriberMarker = fixture.connectionCounts.mark()
  let subscriber = try ControlSocketClient(path: fixture.url.path)
  defer { subscriber.close() }
  try subscriber.write("{\"id\":1,\"cmd\":\"hello\",\"protocol\":1}\n{\"id\":2,\"cmd\":\"subscribe\"}\n")
  _ = try await subscriber.readLine()
  _ = try await subscriber.readLine()
  #expect(await fixture.connectionCounts.wait(for: 1, after: subscriberMarker))
  try? await Task.sleep(for: .milliseconds(120))
  #expect(fixture.server.connectionCount == 1)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func unsubscribingRearmsTheRealSocketIdleTimeout() async throws {
  let fixture = await ControlSocketFixture.make(
    timeouts: ControlConnectionTimeouts(handshake: .seconds(30), idle: .seconds(1)))
  defer { fixture.stop() }
  try fixture.server.start()

  let client = try ControlSocketClient(path: fixture.url.path)
  defer { client.close() }
  try client.write(
    "{\"id\":1,\"cmd\":\"hello\",\"protocol\":1}\n{\"id\":2,\"cmd\":\"subscribe\"}\n")
  #expect((try await client.readLine()).contains(#""id":1"#))
  #expect((try await client.readLine()).contains(#""id":2"#))

  // Stay connected well past the idle threshold while subscribed, then prove
  // unsubscribe re-arms the ordinary idle timer on the real socket.
  try? await Task.sleep(for: .milliseconds(1_500))
  #expect(fixture.server.connectionCount == 1)

  let closeMarker = fixture.connectionCounts.mark()
  try client.write("{\"id\":3,\"cmd\":\"unsubscribe\"}\n")
  #expect((try await client.readLine()).contains(#""id":3"#))
  #expect(await client.reachesEOF(timeout: .seconds(30)))
  #expect(await fixture.connectionCounts.wait(for: 0, after: closeMarker))
  #expect(fixture.server.connectionCount == 0)
}

@Test func validUnsubscribedActivityRefreshesThenExpiresTheIdleDeadline() {
  #expect(ControlConnectionTimeouts.production.handshake == .seconds(5))
  #expect(ControlConnectionTimeouts.production.idle == .seconds(30))
  var deadline = ControlConnectionDeadline(
    timeouts: ControlConnectionTimeouts(handshake: .seconds(5), idle: .seconds(30)))
  deadline.begin(now: 0)
  #expect(deadline.expiresAt == 5)

  deadline.recordValidActivity(didHandshake: true, isSubscribed: false, now: 4)
  #expect(deadline.expiresAt == 34)

  deadline.recordValidActivity(didHandshake: true, isSubscribed: true, now: 8)
  #expect(deadline.expiresAt == nil)
}

@MainActor
@Test func disabledExternalControlReturnsNotPermittedWithoutMutatingStore() async throws {
  let store = await makeControlStoreFixture()
  #expect(store.preferences.enableExternalControl == false)
  let response = await ControlCommandHandler(store: store).handle(
    ControlRequest(id: 1, cmd: .setMute, app: "com.example.render", muted: true),
    session: .init(didHandshake: true))
  #expect(response.response.error == .notPermitted)
  #expect(store.controlApp(forID: "com.example.render")?.isMuted == false)
}

@Test func credentialSeamRejectsForeignUIDs() {
  #expect(ControlServer.peerIsTrusted(peerUID: getuid(), currentUID: getuid()))
  #expect(!ControlServer.peerIsTrusted(peerUID: getuid() &+ 1, currentUID: getuid()))
}

@Test func iconQueueBoundaryRejectsOversizedEncodedIconsOffMainActor() async {
  let oversized = String(repeating: "a", count: ControlIconEncoder.maximumEncodedBytes + 1)
  let accepted = await Task.detached {
    ControlIconEncoder.boundedBase64PNG(oversized)
  }.value
  #expect(accepted == nil)
}

@Test func connectionCountProbeCancellationCannotStrandTheTestTask() async {
  let probe = ControlConnectionCountProbe()
  let marker = probe.mark()
  let task = Task { await probe.wait(for: 1, after: marker) }
  task.cancel()
  #expect(await task.value == false)
}

@MainActor
@Test func disabledURLAutomationDoesNotParseActivatePresentOrMutate() {
  var parseCount = 0
  var setupCount = 0
  var presentationCount = 0
  var mutationCount = 0
  let router = URLAutomationRouter(
    isEnabled: { false },
    isAudioRunning: { false },
    parse: { _ in
      parseCount += 1; return URL(string: "waves://refresh")
    },
    promptForSetup: { setupCount += 1 },
    presentSetup: { presentationCount += 1 },
    perform: { _ in mutationCount += 1 })

  router.handle(rawURLString: "waves://refresh")

  #expect(parseCount == 0)
  #expect(setupCount == 0)
  #expect(presentationCount == 0)
  #expect(mutationCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func controlServerHandlesMalformedOversizedEOFAndReconnect() async throws {
  let fixture = await ControlSocketFixture.make()
  defer { fixture.stop() }
  try fixture.server.start()

  let malformed = try ControlSocketClient(path: fixture.url.path)
  let malformedMarker = fixture.connectionCounts.mark()
  try malformed.write("not json\n")
  #expect((try await malformed.readLine()).contains(#""error":"malformed-request"#))
  malformed.close()
  #expect(await fixture.connectionCounts.wait(for: 0, after: malformedMarker))

  let oversizedMarker = fixture.connectionCounts.mark()
  let oversized = try ControlSocketClient(path: fixture.url.path)
  try await oversized.writeAll(Data(repeating: 0x61, count: ControlProtocol.maximumLineBytes + 1))
  #expect(await oversized.reachesEOF())
  #expect(await fixture.connectionCounts.wait(for: 0, after: oversizedMarker))
  oversized.close()

  let reconnected = try ControlSocketClient(path: fixture.url.path)
  defer { reconnected.close() }
  try reconnected.write("{\"id\":1,\"cmd\":\"hello\",\"protocol\":1}\n")
  #expect((try await reconnected.readLine()).contains(#""ok":true"#))
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func controlServerCapsConnectionsAndRemovesSocketOnShutdown() async throws {
  let fixture = await ControlSocketFixture.make(
    timeouts: ControlConnectionTimeouts(handshake: .seconds(30), idle: .seconds(30))
  )
  try fixture.server.start()
  var clients: [ControlSocketClient] = []
  defer {
    for client in clients { client.close() }
    fixture.stop()
  }

  for expectedCount in 1...ControlServer.maximumConnections {
    let client = try ControlSocketClient(path: fixture.url.path)
    clients.append(client)
    try client.write("{\"id\":\(expectedCount),\"cmd\":\"hello\",\"protocol\":1}\n")
    #expect(
      (try await client.readLine(timeout: .seconds(30))).contains("\"id\":\(expectedCount)")
    )
    #expect(fixture.server.connectionCount == expectedCount)
  }

  let ninthRejected: Bool
  do {
    let ninth = try ControlSocketClient(path: fixture.url.path)
    clients.append(ninth)
    ninthRejected = await ninth.reachesEOF(timeout: .seconds(30))
  } catch {
    ninthRejected = true
  }
  #expect(ninthRejected)
  #expect(fixture.server.connectionCount == ControlServer.maximumConnections)

  fixture.server.stop()
  #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
  #expect(await clients[0].reachesEOF(timeout: .seconds(30)))
}

private struct ControlSocketFixture {
  let directory: URL
  let url: URL
  let server: ControlServer
  let connectionCounts: ControlConnectionCountProbe

  @MainActor
  static func make(
    timeouts: ControlConnectionTimeouts = .integrationTest
  ) async -> ControlSocketFixture {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("wvctl-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let url = directory.appendingPathComponent("control.sock")
    let store = await makeControlStoreFixture()
    store.preferences.enableExternalControl = true
    let connectionCounts = ControlConnectionCountProbe()
    let server = ControlServer(
      url: url,
      handler: ControlCommandHandler(store: store),
      timeouts: timeouts,
      onConnectionCountChange: { connectionCounts.record($0) })
    return ControlSocketFixture(
      directory: directory,
      url: url,
      server: server,
      connectionCounts: connectionCounts
    )
  }

  @MainActor
  func stop() {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}

private extension ControlConnectionTimeouts {
  static let integrationTest = ControlConnectionTimeouts(
    handshake: .seconds(30),
    idle: .seconds(30)
  )
}

private final class ControlSocketClient {
  private let fd: Int32
  private var pending = Data()
  private var isClosed = false

  init(path: String) throws {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
    var noSigPipe: Int32 = 1
    guard
      setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { source in
      strncpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path) - 1)
    }
    let result = withUnsafeBytes(of: &address) { raw in
      connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    _ = Darwin.close(fd)
  }

  func write(_ string: String) throws {
    let data = Data(string.utf8)
    let result = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    guard result == data.count else { throw POSIXError(.EIO) }
  }

  func writeAll(_ data: Data) async throws {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try await Task.sleep(for: .milliseconds(5))
      } else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }

  func readLine(timeout: Duration = .seconds(30)) async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[..<newline]
        pending = Data(pending[pending.index(after: newline)...])
        return String(decoding: line, as: UTF8.self)
      }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = read(fd, &bytes, bytes.count)
      if count > 0 {
        pending.append(contentsOf: bytes[0..<count])
        continue
      }
      if count == 0 { throw POSIXError(.ECONNRESET) }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        try await Task.sleep(for: .milliseconds(10))
        continue
      }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    throw POSIXError(.ETIMEDOUT)
  }

  func reachesEOF(timeout: Duration = .seconds(30)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      var bytes = [UInt8](repeating: 0, count: 64)
      let count = read(fd, &bytes, bytes.count)
      if count == 0 { return true }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try? await Task.sleep(for: .milliseconds(10))
        continue
      }
      if count < 0 { return false }
    }
    return false
  }
}

private func fileMode(at url: URL) -> mode_t {
  var status = stat()
  guard lstat(url.path, &status) == 0 else { return 0 }
  return status.st_mode & 0o777
}

private final class ControlConnectionCountProbe: @unchecked Sendable {
  private struct Waiter {
    let id: UUID
    let count: Int
    let after: Int
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let lock = NSLock()
  private var sequence = 0
  private var events: [(sequence: Int, count: Int)] = []
  private var waiters: [Waiter] = []

  func mark() -> Int { lock.withLock { sequence } }

  func record(_ count: Int) {
    let ready = lock.withLock { () -> [Waiter] in
      sequence += 1
      events.append((sequence, count))
      let ready = waiters.filter { $0.count == count && sequence > $0.after }
      let readyIDs = Set(ready.map(\.id))
      waiters.removeAll { readyIDs.contains($0.id) }
      return ready
    }
    ready.forEach { $0.continuation.resume(returning: true) }
  }

  func wait(for count: Int, after marker: Int) async -> Bool {
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediateResult = lock.withLock { () -> Bool? in
          if events.contains(where: { $0.sequence > marker && $0.count == count }) {
            return true
          }
          if Task.isCancelled { return false }
          waiters.append(
            Waiter(
              id: id,
              count: count,
              after: marker,
              continuation: continuation
            )
          )
          return nil
        }
        if let immediateResult {
          continuation.resume(returning: immediateResult)
        }
      }
    } onCancel: {
      cancelWaiter(id: id)
    }
  }

  private func cancelWaiter(id: UUID) {
    let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
      return waiters.remove(at: index).continuation
    }
    continuation?.resume(returning: false)
  }
}
