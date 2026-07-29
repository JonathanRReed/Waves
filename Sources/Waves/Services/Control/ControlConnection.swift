import Darwin
import Foundation
import OSLog

/// One accepted control connection: reads lines, answers them, and pushes state
/// once subscribed.
///
/// Main-actor isolated throughout: framing state, the session, the rate limiter,
/// and the `AppStore` behind the handler all belong there, and control messages
/// are far too small for the syscalls to matter.
///
/// The consequence is worth stating, because it is easy to trip over: anything
/// waiting on a reply must not block the main thread, or it deadlocks against
/// the response it is waiting for. The test client reads on a detached task.
@MainActor
final class ControlConnection {
  // nonisolated: the accept/read paths log from the I/O queue, and Logger is
  // Sendable, so requiring main-actor isolation here would trap at runtime.
  private nonisolated let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Control")
  private nonisolated let fd: Int32
  private let handler: ControlCommandHandler

  private var readSource: DispatchSourceRead?
  private var codec = ControlCodec()
  private var session = ControlCommandHandler.Session()
  private var limiter = ControlRateLimiter(now: Date().timeIntervalSinceReferenceDate)
  private var isClosed = false

  var onClose: ((ControlConnection) -> Void)?
  var isSubscribed: Bool { session.isSubscribed }

  init(fd: Int32, handler: ControlCommandHandler) {
    self.fd = fd
    self.handler = handler

    // Never let a wedged client block the app: a full send buffer must fail the
    // write rather than stall.
    var flags = fcntl(fd, F_GETFL, 0)
    flags |= O_NONBLOCK
    _ = fcntl(fd, F_SETFL, flags)
    // SIGPIPE would kill the process when a client disappears mid-write.
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
  }

  func resume() {
    let descriptor = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let outcome = Self.readAvailable(descriptor) else { return }
        switch outcome {
        case .data(let received): self.consume(received)
        case .closed: self.finish()
        }
      }
    }
    source.setCancelHandler {
      // Explicitly the POSIX close, not this type's own close().
      _ = Darwin.close(descriptor)
    }
    source.resume()
    readSource = source
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    readSource?.cancel()
    readSource = nil
  }

  // MARK: Reading

  private enum ReadOutcome: Sendable {
    case data(Data)
    case closed
  }

  /// The only part that runs off the main actor: one `read`, no decisions.
  private nonisolated static func readAvailable(_ fd: Int32) -> ReadOutcome? {
    var buffer = [UInt8](repeating: 0, count: 4_096)
    let count = read(fd, &buffer, buffer.count)
    if count > 0 { return .data(Data(buffer[0..<count])) }
    if count == 0 { return .closed }
    if errno == EAGAIN || errno == EINTR { return nil }
    return .closed
  }

  private func consume(_ received: Data) {
    guard !isClosed else { return }

    let lines: [Data]
    do {
      lines = try codec.append(received)
    } catch {
      // A client that cannot frame correctly will not recover, and buffering
      // more is exactly the exhaustion the cap exists to prevent.
      logger.error("Closing a control connection that sent an oversized line")
      send(.failure(id: nil, .malformedRequest))
      finish()
      return
    }

    for line in lines {
      // Decode first, so a refusal can still carry the request's id.
      //
      // Rate-limiting ahead of the decode meant every refusal came back with
      // `id: null`, which no client keying pending requests by id can match —
      // it waits out its timeout instead of seeing the answer it was sent. And
      // this is reachable in ordinary use: a Stream Deck dial spends two
      // commands per tick, so a few seconds of continuous twisting drains the
      // burst allowance.
      let request = ControlCodec.decode(line)

      guard limiter.allow(now: Date().timeIntervalSinceReferenceDate) else {
        send(.failure(id: request?.id, .rateLimited))
        continue
      }
      guard let request else {
        // Malformed input is refused without disturbing the connection — a
        // client recovering from a bad frame should not have to reconnect.
        send(.failure(id: nil, .malformedRequest))
        continue
      }
      send(handler.handle(request, session: &session))
    }
  }

  private func finish() {
    close()
    onClose?(self)
  }

  // MARK: Writing

  func send(_ response: ControlResponse) {
    guard !isClosed, let data = ControlCodec.encode(response) else { return }
    let descriptor = fd
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < raw.count {
        let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
        if written > 0 {
          offset += written
          continue
        }
        if written < 0, errno == EINTR { continue }
        // EAGAIN means the client is not draining. Dropping the push is correct
        // for a state feed — the next one supersedes it — and far better than
        // blocking on a stalled reader.
        break
      }
    }
  }
}
