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
  nonisolated static let maximumConnections = 8
  nonisolated static let maximumConnectionsPerProcess = 4
  nonisolated static let maximumAcceptAttemptsPerEvent = 16
  nonisolated static let maximumSubscribersPerProcess = 2

  // nonisolated: the accept/read paths log from the I/O queue, and Logger is
  // Sendable, so requiring main-actor isolation here would trap at runtime.
  private nonisolated let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Control")
  private let url: URL
  private let handler: ControlCommandHandler
  private let timeouts: ControlConnectionTimeouts
  private let onConnectionCountChange: @MainActor @Sendable (Int) -> Void

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

  init(
    url: URL = ControlSocketLocation.defaultURL(),
    handler: ControlCommandHandler,
    timeouts: ControlConnectionTimeouts = .production,
    onConnectionCountChange: @escaping @MainActor @Sendable (Int) -> Void = { _ in }
  ) {
    self.url = url
    self.handler = handler
    self.timeouts = timeouts
    self.onConnectionCountChange = onConnectionCountChange
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

    do {
      try ControlSocketFilesystem.prepareParent(at: url.deletingLastPathComponent())
    } catch {
      throw ControlServerError.unsafeParent
    }
    do {
      try ControlSocketFilesystem.removeStaleLeaf(at: url)
    } catch {
      throw ControlServerError.unsafeExistingLeaf
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlServerError.socketFailed(errno) }
    guard Self.setNonBlocking(fd) else {
      let configurationError = errno
      close(fd)
      throw ControlServerError.socketFailed(configurationError)
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

    guard bindResult == 0 else {
      close(fd)
      throw ControlServerError.bindFailed(errno)
    }
    // The containing directory is already 0700, so the new node cannot be
    // reached by another user while its final mode is applied. Avoid changing
    // process-global umask here: concurrent file creation elsewhere in Waves
    // must never inherit the socket's restrictive creation mask.
    guard chmod(path, 0o600) == 0 else {
      let permissionsError = errno
      close(fd)
      unlink(path)
      throw ControlServerError.permissionsFailed(permissionsError)
    }
    guard listen(fd, Int32(Self.maximumConnections)) == 0 else {
      close(fd)
      unlink(path)
      throw ControlServerError.listenFailed(errno)
    }

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
        let accepted = Self.acceptPendingFileDescriptors(
          listener: fd,
          remainingCapacity: Self.maximumConnections - self.connections.count,
          logger: self.logger
        )
        self.adopt(accepted)
      }
    }
    source.resume()
    acceptSource = source

    logger.info("Control socket listening")
  }

  func stop() {
    let hadConnections = !connections.isEmpty
    for connection in connections.values { connection.close() }
    connections.removeAll()
    if hadConnections { reportConnectionCount() }

    acceptSource?.cancel()
    acceptSource = nil
    if listenerFD >= 0 {
      close(listenerFD)
      listenerFD = -1
    }
    // Leaving the file behind would make the next launch look like a stale
    // socket it has to clean up; removing it keeps the filesystem honest.
    ControlSocketFilesystem.removeOwnedSocketLeafIfPresent(at: url)
    logger.info("Control socket stopped")
  }

  // MARK: Accept

  /// The dispatch source only promises that at least one connection is ready.
  /// The listener must be nonblocking so draining that backlog stops at EAGAIN
  /// instead of waiting for another client on the main actor.
  nonisolated static func setNonBlocking(_ fd: Int32) -> Bool {
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0 else { return false }
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
  }

  /// Runs on `ioQueue`. Drains the accept backlog, rejecting anything that
  /// fails the uid check before it becomes a connection at all.
  private nonisolated static func acceptPendingFileDescriptors(
    listener: Int32,
    remainingCapacity: Int,
    logger: Logger
  ) -> [AcceptedControlDescriptor] {
    collectAcceptedDescriptors(
      remainingCapacity: remainingCapacity,
      maximumAttempts: maximumAcceptAttemptsPerEvent,
      acceptOne: {
        let clientFD = accept(listener, nil, nil)
        guard clientFD >= 0 else { return nil }
        return clientFD
      },
      identity: { descriptor in
        guard let identity = Self.peerIdentity(descriptor) else {
          // Filesystem permissions already restrict this to our uid; this is
          // defence in depth against a mode that somehow widened.
          logger.error("Refused an unverified control connection")
          return nil
        }
        return identity
      },
      close: { _ = Darwin.close($0) }
    )
  }

  nonisolated static func collectAcceptedDescriptors(
    remainingCapacity: Int,
    maximumAttempts: Int,
    acceptOne: () -> Int32?,
    identity: (Int32) -> ControlPeerIdentity?,
    close: (Int32) -> Void
  ) -> [AcceptedControlDescriptor] {
    let remainingCapacity = max(0, remainingCapacity)
    var accepted: [AcceptedControlDescriptor] = []
    var attempts = 0
    while attempts < max(0, maximumAttempts), let descriptor = acceptOne() {
      attempts += 1
      guard let identity = identity(descriptor), accepted.count < remainingCapacity else {
        close(descriptor)
        continue
      }
      accepted.append(
        AcceptedControlDescriptor(fileDescriptor: descriptor, identity: identity)
      )
    }
    return accepted
  }

  private func adopt(_ descriptors: [AcceptedControlDescriptor]) {
    for accepted in descriptors {
      let clientFD = accepted.fileDescriptor
      let peerProcessID = accepted.identity.processID
      let peerConnectionCount = connections.values.count {
        $0.peerProcessID == peerProcessID
      }
      guard connections.count < Self.maximumConnections,
        peerConnectionCount < Self.maximumConnectionsPerProcess
      else {
        logger.error("Refused a control connection: too many already open")
        _ = Darwin.close(clientFD)
        continue
      }
      let connection = ControlConnection(
        fd: clientFD,
        peerProcessID: peerProcessID,
        handler: handler,
        timeouts: timeouts,
        canSubscribe: { [weak self] in
          guard let self else { return false }
          return self.connections.values.count {
            $0.peerProcessID == peerProcessID && $0.isSubscribed
          } < Self.maximumSubscribersPerProcess
        }
      )
      connection.onClose = { [weak self] closed in
        guard let self,
          self.connections.removeValue(forKey: ObjectIdentifier(closed)) != nil
        else { return }
        self.reportConnectionCount()
      }
      connections[ObjectIdentifier(connection)] = connection
      reportConnectionCount()
      connection.resume()
    }
  }

  private func reportConnectionCount() {
    onConnectionCountChange(connections.count)
  }

  /// True when the connecting process runs as the same user.
  private nonisolated static func peerIdentity(_ fd: Int32) -> ControlPeerIdentity? {
    var uid = uid_t()
    var gid = gid_t()
    guard getpeereid(fd, &uid, &gid) == 0,
      peerIsTrusted(peerUID: uid, currentUID: getuid())
    else { return nil }
    var processID = pid_t()
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &processID, &length) == 0,
      length == MemoryLayout<pid_t>.size,
      processID > 0
    else { return nil }
    return ControlPeerIdentity(uid: uid, processID: processID)
  }

  nonisolated static func peerIsTrusted(peerUID: uid_t, currentUID: uid_t) -> Bool {
    peerUID == currentUID
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
  case unsafeParent
  case unsafeExistingLeaf
  case socketFailed(Int32)
  case bindFailed(Int32)
  case permissionsFailed(Int32)
  case listenFailed(Int32)
}

struct ControlPeerIdentity: Equatable {
  let uid: uid_t
  let processID: pid_t
}

struct AcceptedControlDescriptor: Equatable {
  let fileDescriptor: Int32
  let identity: ControlPeerIdentity
}

enum ControlSocketFilesystem {
  static func parentStatusIsSafe(_ status: stat, currentUID: uid_t) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && status.st_uid == currentUID
      && status.st_mode & 0o777 == 0o700
  }

  static func prepareParent(
    at url: URL,
    fileManager: FileManager = .default,
    currentUID: uid_t = getuid()
  ) throws {
    var status = stat()
    if lstat(url.path, &status) != 0 {
      guard errno == ENOENT else { throw POSIXError(.EIO) }
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
    }

    guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == currentUID else {
      throw POSIXError(.EACCES)
    }
    if status.st_mode & 0o777 != 0o700 {
      guard chmod(url.path, 0o700) == 0 else { throw POSIXError(.EACCES) }
      guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
    }
    guard parentStatusIsSafe(status, currentUID: currentUID) else {
      throw POSIXError(.EACCES)
    }

    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
    defer { _ = Darwin.close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      parentStatusIsSafe(opened, currentUID: currentUID),
      opened.st_dev == status.st_dev,
      opened.st_ino == status.st_ino
    else { throw POSIXError(.EACCES) }
  }

  static func removeStaleLeaf(at url: URL, currentUID: uid_t = getuid()) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      guard errno == ENOENT else { throw POSIXError(.EIO) }
      return
    }
    let type = status.st_mode & S_IFMT
    guard status.st_uid == currentUID, type == S_IFSOCK || type == S_IFREG else {
      throw POSIXError(.EACCES)
    }
    guard unlink(url.path) == 0 else { throw POSIXError(.EACCES) }
  }

  static func removeOwnedSocketLeafIfPresent(
    at url: URL,
    currentUID: uid_t = getuid()
  ) {
    var status = stat()
    guard lstat(url.path, &status) == 0,
      status.st_uid == currentUID,
      status.st_mode & S_IFMT == S_IFSOCK
    else { return }
    _ = unlink(url.path)
  }
}
