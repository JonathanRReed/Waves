import Darwin
import Foundation
import OSLog

struct ControlConnectionTimeouts: Sendable {
  let handshake: Duration
  let idle: Duration

  static let production = ControlConnectionTimeouts(handshake: .seconds(5), idle: .seconds(30))
}

/// Deterministic deadline policy used by socket timers and tests. `nil` means
/// a subscribed connection remains persistent until another transport event.
struct ControlConnectionDeadline: Equatable {
  private(set) var expiresAt: TimeInterval?
  private let handshakeInterval: TimeInterval
  private let idleInterval: TimeInterval

  init(timeouts: ControlConnectionTimeouts) {
    handshakeInterval = Self.seconds(timeouts.handshake)
    idleInterval = Self.seconds(timeouts.idle)
  }

  mutating func begin(now: TimeInterval) {
    expiresAt = now + handshakeInterval
  }

  mutating func recordValidActivity(
    didHandshake: Bool,
    isSubscribed: Bool,
    now: TimeInterval
  ) {
    guard didHandshake else { return }
    expiresAt = isSubscribed ? nil : now + idleInterval
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}

enum ControlWriteResult: Equatable {
  case written(Int)
  case interrupted
  case wouldBlock
  case terminalFailure
}

enum ControlWriteDrainResult: Equatable {
  case empty
  case blocked
  case terminalFailure
}

/// Owns queued frame order and the unwritten head offset. It deliberately
/// accepts a small writer seam so short writes and EAGAIN stay deterministic.
struct ControlWritePump {
  private var frames: [Data] = []
  private var headOffset = 0
  private(set) var queuedByteCount = 0

  mutating func enqueue(_ frame: Data) -> Bool {
    guard queuedByteCount + frame.count <= ControlProtocol.maximumQueuedOutputBytes else { return false }
    frames.append(frame)
    queuedByteCount += frame.count
    return true
  }

  mutating func drain(
    write: (_ frame: Data, _ offset: Int) -> ControlWriteResult
  ) -> ControlWriteDrainResult {
    while let frame = frames.first {
      switch write(frame, headOffset) {
      case let .written(count) where count > 0 && count <= frame.count - headOffset:
        headOffset += count
        queuedByteCount -= count
        if headOffset == frame.count {
          frames.removeFirst()
          headOffset = 0
        }
      case .interrupted:
        continue
      case .wouldBlock:
        return .blocked
      case .terminalFailure, .written:
        return .terminalFailure
      }
    }
    return .empty
  }

  mutating func removeAll() {
    frames.removeAll()
    headOffset = 0
    queuedByteCount = 0
  }
}

/// One accepted control connection. The connection owns its framing, session,
/// deadlines, and ordered nonblocking output queue for its entire lifetime.
@MainActor
final class ControlConnection {
  private nonisolated let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Control")
  private nonisolated let fd: Int32
  private let handler: ControlCommandHandler
  private let timeouts: ControlConnectionTimeouts

  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var timeoutSource: DispatchSourceTimer?
  private var isWriteSourceActive = false
  private var codec = ControlCodec()
  private var session = ControlCommandHandler.Session()
  private var limiter = ControlRateLimiter(now: Date().timeIntervalSinceReferenceDate)
  private var writePump = ControlWritePump()
  private var pendingRequests: [ControlRequest] = []
  private var isHandlingRequest = false
  private var isClosed = false

  var onClose: ((ControlConnection) -> Void)?
  var isSubscribed: Bool { session.isSubscribed }

  init(fd: Int32, handler: ControlCommandHandler, timeouts: ControlConnectionTimeouts = .production) {
    self.fd = fd
    self.handler = handler
    self.timeouts = timeouts

    var flags = fcntl(fd, F_GETFL, 0)
    flags |= O_NONBLOCK
    _ = fcntl(fd, F_SETFL, flags)
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
  }

  func resume() {
    let descriptor = fd
    let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
    readSource.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let outcome = Self.readAvailable(descriptor) else { return }
        switch outcome {
        case .data(let received): self.consume(received)
        case .closed: self.finish()
        }
      }
    }
    readSource.setCancelHandler { _ = Darwin.close(descriptor) }
    readSource.resume()
    self.readSource = readSource

    let writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
    writeSource.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.flushOutput() }
    }
    self.writeSource = writeSource

    let timeoutSource = DispatchSource.makeTimerSource(queue: .main)
    timeoutSource.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.handleDeadline() }
    }
    timeoutSource.resume()
    self.timeoutSource = timeoutSource
    scheduleHandshakeDeadline()
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    writePump.removeAll()
    readSource?.cancel()
    readSource = nil
    if let writeSource {
      if !isWriteSourceActive { writeSource.resume() }
      writeSource.cancel()
    }
    writeSource = nil
    timeoutSource?.cancel()
    timeoutSource = nil
  }

  private enum ReadOutcome: Sendable {
    case data(Data)
    case closed
  }

  private nonisolated static func readAvailable(_ fd: Int32) -> ReadOutcome? {
    var buffer = [UInt8](repeating: 0, count: 4_096)
    let count = read(fd, &buffer, buffer.count)
    if count > 0 { return .data(Data(buffer[0..<count])) }
    if count == 0 { return .closed }
    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return nil }
    return .closed
  }

  private func consume(_ received: Data) {
    guard !isClosed else { return }
    let lines: [Data]
    do {
      lines = try codec.append(received)
    } catch {
      logger.error("Closing a control connection that sent an oversized line")
      finish()
      return
    }

    for line in lines {
      guard let request = ControlCodec.decode(line) else {
        send(.failure(id: nil, .malformedRequest))
        continue
      }

      // A valid decoded request keeps an established, unsubscribed session
      // alive. It cannot extend the initial handshake window.
      if session.didHandshake { scheduleActivityDeadline() }
      guard limiter.allow(now: Date().timeIntervalSinceReferenceDate) else {
        send(.failure(id: request.id, .rateLimited))
        continue
      }
      enqueue(request)
    }
  }

  private func finish() {
    close()
    onClose?(self)
  }

  private func enqueue(_ request: ControlRequest) {
    pendingRequests.append(request)
    processNextRequestIfNeeded()
  }

  private func processNextRequestIfNeeded() {
    guard !isClosed, !isHandlingRequest, !pendingRequests.isEmpty else { return }
    isHandlingRequest = true
    let request = pendingRequests.removeFirst()
    let priorSession = session
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.handler.handle(request, session: priorSession)
      guard !self.isClosed else { return }
      self.session = result.session
      self.send(result.response)
      if self.session.didHandshake { self.scheduleActivityDeadline() }
      self.isHandlingRequest = false
      self.processNextRequestIfNeeded()
    }
  }

  // MARK: Deadlines

  private func scheduleHandshakeDeadline() {
    timeoutSource?.schedule(deadline: .now() + dispatchInterval(for: timeouts.handshake))
  }

  private func scheduleActivityDeadline() {
    guard session.didHandshake else {
      scheduleHandshakeDeadline()
      return
    }
    guard !session.isSubscribed else {
      timeoutSource?.schedule(deadline: .distantFuture)
      return
    }
    timeoutSource?.schedule(deadline: .now() + dispatchInterval(for: timeouts.idle))
  }

  private func handleDeadline() {
    guard !isClosed else { return }
    if !session.didHandshake {
      logger.debug("Closing control connection that did not complete a handshake")
      finish()
    } else if !session.isSubscribed {
      logger.debug("Closing idle control connection")
      finish()
    }
  }

  private func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
    let components = duration.components
    let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    return .nanoseconds(Int(clamping: nanoseconds))
  }

  // MARK: Writing

  func send(_ response: ControlResponse) {
    guard !isClosed, let data = ControlCodec.encode(response) else { return }
    guard writePump.enqueue(data) else {
      logger.error("Closing control connection whose output queue exceeded its limit")
      finish()
      return
    }
    activateWriteSource()
    flushOutput()
  }

  private func activateWriteSource() {
    guard !isWriteSourceActive, let writeSource else { return }
    isWriteSourceActive = true
    writeSource.resume()
  }

  private func flushOutput() {
    guard !isClosed else { return }
    let result = writePump.drain { frame, offset in
      let written = frame.withUnsafeBytes { raw in
        Darwin.write(fd, raw.baseAddress!.advanced(by: offset), frame.count - offset)
      }
      if written > 0 { return .written(written) }
      if written < 0, errno == EINTR { return .interrupted }
      if written < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
      return .terminalFailure
    }
    if result == .terminalFailure {
      finish()
      return
    }
    if result == .empty, isWriteSourceActive, let writeSource {
      writeSource.suspend()
      isWriteSourceActive = false
    }
  }
}
