import Darwin
import Foundation
import OSLog

/// Where the control socket lives, and how it is secured.
enum ControlSocketLocation {
  /// `~/Library/Application Support/Waves/control.sock`.
  ///
  /// Inside the existing `0700` support directory, and created `0600`, so access
  /// is restricted to this user by the filesystem. That is the whole
  /// authorization story — there is no port, so nothing on the network can reach
  /// it, no firewall prompt appears, and no web page can POST to it (a real
  /// hazard for `127.0.0.1` servers).
  static func defaultURL(fileManager: FileManager = .default) -> URL {
    let directory: URL
    if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      directory = support.appendingPathComponent("Waves", isDirectory: true)
    } else {
      directory = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent(".Waves", isDirectory: true)
    }
    try? PersistenceSecurity.preparePrivateDirectory(directory, fileManager: fileManager)
    return directory.appendingPathComponent("control.sock")
  }

  /// A Unix socket path lives in a fixed-size C buffer (104 bytes on Darwin),
  /// and a home directory deep enough to overflow it would otherwise be a
  /// truncation bug rather than a clear failure.
  static let maximumPathBytes = 104
}

/// Accepts control connections over a Unix domain socket.
///
/// POSIX sockets rather than Network.framework: this needs `getpeereid` for the
/// peer-uid check and precise control over the listening socket's mode, neither
/// of which the higher-level API exposes for Unix domain sockets.
@MainActor
final class ControlServer {
  /// Beyond this, further connects are refused. A control surface needs one
  /// client, maybe a few; a bound stops a misbehaving one from exhausting
  /// descriptors for the whole app.
  static let maximumConnections = 8

  // nonisolated: the accept/read paths log from the I/O queue, and Logger is
  // Sendable, so requiring main-actor isolation here would trap at runtime.
  private nonisolated let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Control")
  private let url: URL
  private let handler: ControlCommandHandler

  /// Accept and read run on the main queue.
  ///
  /// Control messages are a few hundred bytes and arrive at human speed — even a
  /// dial sweep is tens per second — so the syscalls are not a meaningful cost
  /// there, and running on the same actor as `AppStore` removes a whole class of
  /// isolation hazard. Anything waiting for a reply must therefore not block the
  /// main thread; the test client reads on a detached task for exactly that
  /// reason.
  private var listenerFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: [ObjectIdentifier: ControlConnection] = [:]

  init(url: URL = ControlSocketLocation.defaultURL(), handler: ControlCommandHandler) {
    self.url = url
    self.handler = handler
  }

  var isRunning: Bool { listenerFD >= 0 }
  var connectionCount: Int { connections.count }

  // MARK: Lifecycle

  func start() throws {
    guard !isRunning else { return }

    let path = url.path
    guard path.utf8.count < ControlSocketLocation.maximumPathBytes else {
      throw ControlServerError.pathTooLong
    }

    // A socket file left behind by a crash would make bind() fail with EADDRINUSE
    // forever. Nothing else owns this path, so replacing it is safe and is the
    // difference between "recovers on next launch" and "never works again".
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlServerError.socketFailed(errno) }
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      let configurationError = errno
      close(fd)
      throw ControlServerError.socketConfigurationFailed(configurationError)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      path.withCString { source in
        strncpy(
          UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self),
          source,
          ControlSocketLocation.maximumPathBytes - 1
        )
      }
    }

    // Create the socket file with 0600 from the outset rather than widening then
    // narrowing, so there is no window where it is world-accessible.
    let previousMask = umask(0o177)
    // `withMemoryRebound(to: sockaddr.self, capacity: 1)` is the classic idiom
    // here, but it traps on current runtimes: sockaddr_un is 106 bytes and
    // sockaddr is 16, and rebinding now requires the strides to match.
    // `assumingMemoryBound` carries no such precondition and is what the C API
    // actually wants — a pointer to the front of the address structure.
    let bindResult = withUnsafeBytes(of: &address) { raw -> Int32 in
      guard let base = raw.baseAddress else { return -1 }
      return bind(
        fd,
        base.assumingMemoryBound(to: sockaddr.self),
        socklen_t(MemoryLayout<sockaddr_un>.size)
      )
    }
    umask(previousMask)

    guard bindResult == 0 else {
      close(fd)
      throw ControlServerError.bindFailed(errno)
    }
    guard listen(fd, Int32(Self.maximumConnections)) == 0 else {
      close(fd)
      unlink(path)
      throw ControlServerError.listenFailed(errno)
    }
    // Belt and braces: bind() honours umask, but an inherited mask could differ.
    chmod(path, 0o600)

    listenerFD = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    // Captures nothing main-actor-isolated. Capturing `self` here makes Swift
    // infer the closure as isolated, and the runtime then asserts it is running
    // on the main queue — which it is not, by design. The syscall runs with only
    // the descriptor and a Sendable logger; everything it produces is handed to
    // the main actor, where the connection table and the store live.
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let accepted = Self.acceptPendingFileDescriptors(listener: fd, logger: self.logger)
        self.adopt(accepted)
      }
    }
    source.resume()
    acceptSource = source

    logger.info("Control socket listening")
  }

  func stop() {
    for connection in connections.values { connection.close() }
    connections.removeAll()

    acceptSource?.cancel()
    acceptSource = nil
    if listenerFD >= 0 {
      close(listenerFD)
      listenerFD = -1
    }
    // Leaving the file behind would make the next launch look like a stale
    // socket it has to clean up; removing it keeps the filesystem honest.
    unlink(url.path)
    logger.info("Control socket stopped")
  }

  // MARK: Accept

  /// Runs on `ioQueue`. Drains the accept backlog, rejecting anything that
  /// fails the uid check before it becomes a connection at all.
  private nonisolated static func acceptPendingFileDescriptors(
    listener: Int32,
    logger: Logger
  ) -> [Int32] {
    var accepted: [Int32] = []
    while true {
      let clientFD = accept(listener, nil, nil)
      guard clientFD >= 0 else { return accepted }
      guard Self.isPeerTrusted(clientFD) else {
        // Filesystem permissions already restrict this to our uid; this is
        // defence in depth against a mode that somehow widened.
        logger.error("Refused a control connection from another user")
        _ = Darwin.close(clientFD)
        continue
      }
      accepted.append(clientFD)
    }
  }

  private func adopt(_ fileDescriptors: [Int32]) {
    for clientFD in fileDescriptors {
      guard connections.count < Self.maximumConnections else {
        logger.error("Refused a control connection: too many already open")
        _ = Darwin.close(clientFD)
        continue
      }
      let connection = ControlConnection(fd: clientFD, handler: handler)
      connection.onClose = { [weak self] closed in
        _ = self?.connections.removeValue(forKey: ObjectIdentifier(closed))
      }
      connections[ObjectIdentifier(connection)] = connection
      connection.resume()
    }
  }

  /// True when the connecting process runs as the same user.
  private nonisolated static func isPeerTrusted(_ fd: Int32) -> Bool {
    var uid = uid_t()
    var gid = gid_t()
    guard getpeereid(fd, &uid, &gid) == 0 else { return false }
    return uid == getuid()
  }

  // MARK: Pushes

  /// Sends an event to every subscribed connection.
  func broadcast(_ response: ControlResponse) {
    guard !connections.isEmpty else { return }
    for connection in connections.values where connection.isSubscribed {
      connection.send(response)
    }
  }
}

enum ControlServerError: Error, Equatable {
  case pathTooLong
  case socketFailed(Int32)
  case socketConfigurationFailed(Int32)
  case bindFailed(Int32)
  case listenFailed(Int32)
}
