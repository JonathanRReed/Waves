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

/// Narrow lifecycle seams used to deterministically exercise filesystem races.
/// Production uses the empty hooks.
struct ControlServerFilesystemHooks {
  var afterParentOpened: @MainActor () throws -> Void = {}
  var beforeBind: @MainActor () throws -> Void = {}
  var afterStagingBind: @MainActor (String) throws -> Void = { _ in }
  var afterPublicPublish: @MainActor () throws -> Void = {}
  var selfProofOverride: @MainActor (ControlListenerSelfProofPhase) -> Bool? = { _ in nil }
  var afterShutdownQuarantine: @MainActor (String) -> Void = { _ in }
}

enum ControlListenerSelfProofPhase: Equatable {
  case staging
  case publicLeaf
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
  private let requestHandler: ControlRequestHandler
  private let timeouts: ControlConnectionTimeouts
  private let filesystemHooks: ControlServerFilesystemHooks
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
  private var parentDirectoryFD: Int32 = -1
  private var boundLeafIdentity: ControlSocketIdentity?
  private var acceptSource: DispatchSourceRead?
  private var connections: [ObjectIdentifier: ControlConnection] = [:]

  init(
    url: URL = ControlSocketLocation.defaultURL(),
    handler: ControlCommandHandler,
    timeouts: ControlConnectionTimeouts = .production,
    requestHandler: ControlRequestHandler? = nil,
    filesystemHooks: ControlServerFilesystemHooks = .init(),
    onConnectionCountChange: @escaping @MainActor @Sendable (Int) -> Void = { _ in }
  ) {
    self.url = url
    self.requestHandler =
      requestHandler ?? { request, session in
        await handler.handle(request, session: session)
      }
    self.timeouts = timeouts
    self.filesystemHooks = filesystemHooks
    self.onConnectionCountChange = onConnectionCountChange
  }

  var isRunning: Bool { listenerFD >= 0 }
  var connectionCount: Int { connections.count }

  // MARK: Lifecycle

  func start() throws {
    guard !isRunning else { return }

    let publicPath = url.path
    guard publicPath.utf8.count < ControlSocketLocation.maximumPathBytes else {
      throw ControlServerError.pathTooLong
    }
    let leafName = url.lastPathComponent
    guard !leafName.isEmpty, leafName != ".", leafName != "..", !leafName.contains("/") else {
      throw ControlServerError.unsafeExistingLeaf
    }

    let parent: OpenedControlSocketParent
    do {
      parent = try ControlSocketFilesystem.openVerifiedParent(
        at: url.deletingLastPathComponent()
      )
    } catch {
      throw ControlServerError.unsafeParent
    }
    var retainParent = false
    defer {
      if !retainParent { _ = Darwin.close(parent.descriptor) }
    }

    try filesystemHooks.afterParentOpened()
    guard
      ControlSocketFilesystem.publicParentMatches(
        at: url.deletingLastPathComponent(),
        identity: parent.identity
      )
    else { throw ControlServerError.unsafeParent }

    do {
      try ControlSocketFilesystem.removeStaleLeaf(
        parentDescriptor: parent.descriptor,
        leafName: leafName
      )
    } catch {
      throw ControlServerError.unsafeExistingLeaf
    }
    try filesystemHooks.beforeBind()
    guard
      ControlSocketFilesystem.publicParentMatches(
        at: url.deletingLastPathComponent(),
        identity: parent.identity
      )
    else { throw ControlServerError.unsafeParent }

    let stagingLeaf = ControlSocketFilesystem.uniqueLeafName(kind: "stage")
    let stagingPath: String
    do {
      stagingPath = try ControlSocketFilesystem.bindingPath(
        parentDescriptor: parent.descriptor,
        leafName: stagingLeaf
      )
    } catch {
      throw ControlServerError.unsafeParent
    }
    guard stagingPath.utf8.count < ControlSocketLocation.maximumPathBytes else {
      throw ControlServerError.pathTooLong
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ControlServerError.socketFailed(errno) }
    var retainListener = false
    var createdIdentity: ControlSocketIdentity?
    var didPublishPublicLeaf = false
    defer {
      if !retainListener {
        _ = Darwin.close(fd)
        if let createdIdentity {
          if didPublishPublicLeaf {
            ControlSocketFilesystem.quarantineAndRemoveSocketIfMatches(
              parentDescriptor: parent.descriptor,
              leafName: leafName,
              identity: createdIdentity
            )
          }
          ControlSocketFilesystem.quarantineAndRemoveSocketIfMatches(
            parentDescriptor: parent.descriptor,
            leafName: stagingLeaf,
            identity: createdIdentity
          )
        }
      }
    }
    guard Self.setNonBlocking(fd) else {
      let configurationError = errno
      throw ControlServerError.socketFailed(configurationError)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      stagingPath.withCString { source in
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
      throw ControlServerError.bindFailed(errno)
    }
    guard listen(fd, Int32(Self.maximumConnections)) == 0 else {
      throw ControlServerError.listenFailed(errno)
    }
    guard
      let socketIdentity = ControlSocketFilesystem.ownedSocketIdentity(
        parentDescriptor: parent.descriptor,
        leafName: stagingLeaf
      )
    else { throw ControlServerError.unsafeExistingLeaf }
    createdIdentity = socketIdentity
    try filesystemHooks.afterStagingBind(stagingLeaf)

    guard
      verifyListener(
        phase: .staging,
        listener: fd,
        path: stagingPath,
        parentDescriptor: parent.descriptor,
        leafName: stagingLeaf,
        identity: socketIdentity
      )
    else { throw ControlServerError.listenerVerificationFailed }

    // The containing directory is already 0700, so the new node cannot be
    // reached by another user while its final mode is applied. Avoid changing
    // process-global umask here: concurrent file creation elsewhere in Waves
    // must never inherit the socket's restrictive creation mask.
    if let permissionsError = ControlSocketFilesystem.setPrivateMode(
      parentDescriptor: parent.descriptor,
      leafName: stagingLeaf,
      identity: socketIdentity
    ) {
      throw ControlServerError.permissionsFailed(permissionsError)
    }

    if let publicationError = ControlSocketFilesystem.publishSocketLeaf(
      parentDescriptor: parent.descriptor,
      stagingLeaf: stagingLeaf,
      publicLeaf: leafName
    ) {
      throw ControlServerError.publicationFailed(publicationError)
    }
    didPublishPublicLeaf = true
    guard
      ControlSocketFilesystem.socketIdentityMatches(
        parentDescriptor: parent.descriptor,
        leafName: leafName,
        identity: socketIdentity
      )
    else { throw ControlServerError.listenerVerificationFailed }
    try filesystemHooks.afterPublicPublish()

    guard
      verifyListener(
        phase: .publicLeaf,
        listener: fd,
        path: publicPath,
        parentDescriptor: parent.descriptor,
        leafName: leafName,
        identity: socketIdentity
      )
    else { throw ControlServerError.listenerVerificationFailed }
    guard
      ControlSocketFilesystem.publicParentMatches(
        at: url.deletingLastPathComponent(),
        identity: parent.identity
      )
    else { throw ControlServerError.unsafeParent }

    // The public hard link now proved it reaches this listener. Remove the
    // unpredictable staging name through quarantine without ever unlinking a
    // checked public pathname.
    ControlSocketFilesystem.quarantineAndRemoveSocketIfMatches(
      parentDescriptor: parent.descriptor,
      leafName: stagingLeaf,
      identity: socketIdentity
    )

    listenerFD = fd
    parentDirectoryFD = parent.descriptor
    boundLeafIdentity = socketIdentity
    retainListener = true
    retainParent = true
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
    // socket it has to clean up. Remove only the exact socket created by this
    // server, through the verified directory descriptor retained since start.
    if parentDirectoryFD >= 0, let boundLeafIdentity {
      ControlSocketFilesystem.quarantineAndRemoveSocketIfMatches(
        parentDescriptor: parentDirectoryFD,
        leafName: url.lastPathComponent,
        identity: boundLeafIdentity,
        afterQuarantine: filesystemHooks.afterShutdownQuarantine
      )
    }
    boundLeafIdentity = nil
    if parentDirectoryFD >= 0 {
      _ = Darwin.close(parentDirectoryFD)
      parentDirectoryFD = -1
    }
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

  private func verifyListener(
    phase: ControlListenerSelfProofPhase,
    listener: Int32,
    path: String,
    parentDescriptor: Int32,
    leafName: String,
    identity: ControlSocketIdentity
  ) -> Bool {
    if let override = filesystemHooks.selfProofOverride(phase) { return override }
    return Self.listenerSelfProof(
      listener: listener,
      path: path,
      parentDescriptor: parentDescriptor,
      leafName: leafName,
      identity: identity
    )
  }

  /// Connects through the name being proved, then accepts on the actual
  /// listener descriptor. The accepted peer must be this process and the name
  /// must still identify the captured socket after the round trip.
  private nonisolated static func listenerSelfProof(
    listener: Int32,
    path: String,
    parentDescriptor: Int32,
    leafName: String,
    identity: ControlSocketIdentity
  ) -> Bool {
    guard let remainingAttempts = drainListenerSelfProofBacklog(listener: listener) else {
      return false
    }

    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    guard client >= 0 else { return false }
    defer { _ = Darwin.close(client) }
    guard setNonBlocking(client) else { return false }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { source in
      strncpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path) - 1)
    }
    let connected = withUnsafeBytes(of: &address) { raw in
      connect(
        client,
        raw.baseAddress!.assumingMemoryBound(to: sockaddr.self),
        socklen_t(raw.count)
      )
    }
    let connectError = connected == 0 ? 0 : errno
    var readiness = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
    let readinessResult = poll(&readiness, 1, 0)
    var socketError: Int32 = 0
    var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
    guard
      readinessResult >= 0,
      getsockopt(client, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0,
      nonblockingConnectCompleted(
        connectResult: connected,
        connectError: connectError,
        readinessEvents: readiness.revents,
        socketError: socketError
      )
    else { return false }

    var nonceBytes = [UInt8](repeating: 0, count: 32)
    nonceBytes.withUnsafeMutableBytes { bytes in
      arc4random_buf(bytes.baseAddress!, bytes.count)
    }
    let nonce = Data(nonceBytes)
    let sent = nonce.withUnsafeBytes { bytes in
      Darwin.send(client, bytes.baseAddress!, bytes.count, MSG_DONTWAIT)
    }
    guard sent == nonce.count else { return false }

    let provedPeer = runListenerSelfProofAcceptLoop(
      remainingAttempts: remainingAttempts,
      expectedNonce: nonce,
      acceptOne: {
        let candidate = accept(listener, nil, nil)
        return (candidate, candidate >= 0 ? 0 : errno)
      },
      peerIsTrusted: { descriptor in
        guard let peer = peerIdentity(descriptor) else { return false }
        return peer.uid == getuid() && peer.processID == getpid()
      },
      readNonce: { descriptor in
        var received = [UInt8](repeating: 0, count: nonce.count)
        let count = received.withUnsafeMutableBytes { bytes in
          Darwin.recv(descriptor, bytes.baseAddress!, bytes.count, MSG_DONTWAIT)
        }
        guard count == received.count else { return nil }
        return Data(received)
      },
      close: { _ = Darwin.close($0) }
    )
    guard provedPeer else { return false }
    return ControlSocketFilesystem.socketIdentityMatches(
      parentDescriptor: parentDescriptor,
      leafName: leafName,
      identity: identity
    )
  }

  /// Clears only a bounded batch of verified same-user entries before creating
  /// the proof connection. The later nonce match distinguishes the proof client
  /// from any same-process connection that races in after this drain.
  private nonisolated static func drainListenerSelfProofBacklog(
    listener: Int32
  ) -> Int? {
    var remainingAttempts = maximumAcceptAttemptsPerEvent
    while remainingAttempts > 0 {
      remainingAttempts -= 1
      let candidate = accept(listener, nil, nil)
      if candidate >= 0 {
        defer { _ = Darwin.close(candidate) }
        guard let peer = peerIdentity(candidate), peer.uid == getuid() else { return nil }
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        return remainingAttempts
      } else if errno != EINTR {
        return nil
      }
    }
    return nil
  }

  /// Bounded syscall loop for listener self-proof. Every descriptor is closed,
  /// including verified backlog entries and the descriptor that proves the
  /// connection, because none belongs to the public connection lifecycle.
  nonisolated static func runListenerSelfProofAcceptLoop(
    remainingAttempts: Int,
    expectedNonce: Data,
    acceptOne: () -> (descriptor: Int32, error: Int32),
    peerIsTrusted: (Int32) -> Bool,
    readNonce: (Int32) -> Data?,
    close: (Int32) -> Void
  ) -> Bool {
    var remainingAttempts = max(0, remainingAttempts)
    while remainingAttempts > 0 {
      remainingAttempts -= 1
      let result = acceptOne()
      if result.descriptor >= 0 {
        let matches = peerIsTrusted(result.descriptor)
          && readNonce(result.descriptor) == expectedNonce
        close(result.descriptor)
        if matches { return true }
      } else if result.error == EAGAIN || result.error == EWOULDBLOCK {
        return false
      } else if result.error != EINTR {
        return false
      }
    }
    return false
  }

  nonisolated static func nonblockingConnectCompleted(
    connectResult: Int32,
    connectError: Int32,
    readinessEvents: Int16,
    socketError: Int32
  ) -> Bool {
    if connectResult == 0 { return socketError == 0 }
    guard connectError == EINPROGRESS else { return false }
    return readinessEvents & Int16(POLLOUT) != 0 && socketError == 0
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
        requestHandler: requestHandler,
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
  case publicationFailed(Int32)
  case listenerVerificationFailed
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

struct ControlDirectoryIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let owner: uid_t
}

struct OpenedControlSocketParent {
  let descriptor: Int32
  let identity: ControlDirectoryIdentity
}

struct ControlSocketIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
  let owner: uid_t
}

enum ControlSocketFilesystem {
  private static let maximumUniqueNameAttempts = 4

  static func parentStatusIsSafe(_ status: stat, currentUID: uid_t) -> Bool {
    status.st_mode & S_IFMT == S_IFDIR
      && status.st_uid == currentUID
      && status.st_mode & 0o777 == 0o700
  }

  /// Opens the parent once and transfers descriptor ownership to the caller.
  /// Every subsequent leaf operation is relative to this verified directory.
  static func openVerifiedParent(
    at url: URL,
    fileManager: FileManager = .default,
    currentUID: uid_t = getuid()
  ) throws -> OpenedControlSocketParent {
    var status = stat()
    if lstat(url.path, &status) != 0 {
      guard errno == ENOENT else { throw POSIXError(.EIO) }
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
    }

    guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == currentUID else {
      throw POSIXError(.EACCES)
    }

    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
    var keepDescriptor = false
    defer {
      if !keepDescriptor { _ = Darwin.close(descriptor) }
    }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0,
      opened.st_mode & S_IFMT == S_IFDIR,
      opened.st_uid == currentUID,
      opened.st_dev == status.st_dev,
      opened.st_ino == status.st_ino
    else { throw POSIXError(.EACCES) }
    if opened.st_mode & 0o777 != 0o700 {
      guard fchmod(descriptor, 0o700) == 0, fstat(descriptor, &opened) == 0 else {
        throw POSIXError(.EACCES)
      }
    }
    guard parentStatusIsSafe(opened, currentUID: currentUID) else {
      throw POSIXError(.EACCES)
    }

    keepDescriptor = true
    return OpenedControlSocketParent(
      descriptor: descriptor,
      identity: ControlDirectoryIdentity(
        device: opened.st_dev,
        inode: opened.st_ino,
        owner: opened.st_uid
      )
    )
  }

  static func publicParentMatches(
    at url: URL,
    identity: ControlDirectoryIdentity,
    currentUID: uid_t = getuid()
  ) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
      && parentStatusIsSafe(status, currentUID: currentUID)
      && status.st_dev == identity.device
      && status.st_ino == identity.inode
      && status.st_uid == identity.owner
  }

  /// Darwin has no `bindat`. Resolve the currently opened directory's path
  /// from its descriptor immediately before bind, then revalidate the public
  /// parent identity after bind. This avoids process-global `chdir` and fails
  /// closed if the public parent was replaced.
  static func bindingPath(parentDescriptor: Int32, leafName: String) throws -> String {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = path.withUnsafeMutableBufferPointer { buffer in
      fcntl(parentDescriptor, F_GETPATH, buffer.baseAddress!)
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    let directoryPath = String(
      decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    return URL(fileURLWithPath: directoryPath, isDirectory: true)
      .appendingPathComponent(leafName)
      .path
  }

  static func uniqueLeafName(kind: String) -> String {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let prefix = kind == "stage" ? "s" : "q"
    return ".\(prefix)-\(token.prefix(24))"
  }

  static func removeStaleLeaf(
    parentDescriptor: Int32,
    leafName: String,
    currentUID: uid_t = getuid()
  ) throws {
    guard
      let quarantineLeaf = try moveToUniqueQuarantine(
        parentDescriptor: parentDescriptor,
        leafName: leafName
      )
    else { return }
    var needsRestore = true
    defer {
      if needsRestore {
        _ = restoreQuarantinedLeaf(
          parentDescriptor: parentDescriptor,
          quarantineLeaf: quarantineLeaf,
          destinationLeaf: leafName
        )
      }
    }

    var status = stat()
    guard fstatat(parentDescriptor, quarantineLeaf, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw POSIXError(.EIO)
    }
    let type = status.st_mode & S_IFMT
    guard status.st_uid == currentUID, type == S_IFSOCK || type == S_IFREG else {
      throw POSIXError(.EACCES)
    }
    guard unlinkat(parentDescriptor, quarantineLeaf, 0) == 0 else {
      throw POSIXError(.EACCES)
    }
    needsRestore = false
  }

  static func ownedSocketIdentity(
    parentDescriptor: Int32,
    leafName: String,
    currentUID: uid_t = getuid()
  ) -> ControlSocketIdentity? {
    var status = stat()
    guard fstatat(parentDescriptor, leafName, &status, AT_SYMLINK_NOFOLLOW) == 0,
      status.st_uid == currentUID,
      status.st_mode & S_IFMT == S_IFSOCK
    else { return nil }
    return ControlSocketIdentity(
      device: status.st_dev,
      inode: status.st_ino,
      owner: status.st_uid
    )
  }

  static func setPrivateMode(
    parentDescriptor: Int32,
    leafName: String,
    identity: ControlSocketIdentity,
    currentUID: uid_t = getuid()
  ) -> Int32? {
    guard
      socketIdentityMatches(
        parentDescriptor: parentDescriptor,
        leafName: leafName,
        identity: identity,
        currentUID: currentUID
      )
    else { return EACCES }
    guard fchmodat(parentDescriptor, leafName, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
      return errno
    }
    var status = stat()
    guard fstatat(parentDescriptor, leafName, &status, AT_SYMLINK_NOFOLLOW) == 0,
      socketIdentityMatches(status, identity: identity, currentUID: currentUID),
      status.st_mode & 0o777 == 0o600
    else { return EACCES }
    return nil
  }

  /// Hard-link publication is atomic and no-overwrite. The unpredictable
  /// staging name remains available until a filesystem that accepts the link
  /// proves public-name reachability through the actual listener.
  static func publishSocketLeaf(
    parentDescriptor: Int32,
    stagingLeaf: String,
    publicLeaf: String
  ) -> Int32? {
    guard
      linkat(
        parentDescriptor,
        stagingLeaf,
        parentDescriptor,
        publicLeaf,
        AT_SYMLINK_NOFOLLOW_ANY
      ) == 0
    else { return errno }
    return nil
  }

  /// Atomically removes the named entry from its public or staging name before
  /// inspecting it. A mismatch is restored with no-overwrite rename; if a new
  /// public entry appeared concurrently, both inodes remain preserved.
  static func quarantineAndRemoveSocketIfMatches(
    parentDescriptor: Int32,
    leafName: String,
    identity: ControlSocketIdentity,
    currentUID: uid_t = getuid(),
    afterQuarantine: (String) -> Void = { _ in }
  ) {
    guard
      let quarantineLeaf = try? moveToUniqueQuarantine(
        parentDescriptor: parentDescriptor,
        leafName: leafName
      )
    else { return }
    afterQuarantine(quarantineLeaf)
    guard
      socketIdentityMatches(
        parentDescriptor: parentDescriptor,
        leafName: quarantineLeaf,
        identity: identity,
        currentUID: currentUID
      )
    else {
      _ = restoreQuarantinedLeaf(
        parentDescriptor: parentDescriptor,
        quarantineLeaf: quarantineLeaf,
        destinationLeaf: leafName
      )
      return
    }
    guard unlinkat(parentDescriptor, quarantineLeaf, 0) == 0 else {
      _ = restoreQuarantinedLeaf(
        parentDescriptor: parentDescriptor,
        quarantineLeaf: quarantineLeaf,
        destinationLeaf: leafName
      )
      return
    }
  }

  static func socketIdentityMatches(
    parentDescriptor: Int32,
    leafName: String,
    identity: ControlSocketIdentity,
    currentUID: uid_t = getuid()
  ) -> Bool {
    var status = stat()
    return fstatat(parentDescriptor, leafName, &status, AT_SYMLINK_NOFOLLOW) == 0
      && socketIdentityMatches(status, identity: identity, currentUID: currentUID)
  }

  private static func socketIdentityMatches(
    _ status: stat,
    identity: ControlSocketIdentity,
    currentUID: uid_t
  ) -> Bool {
    status.st_mode & S_IFMT == S_IFSOCK
      && status.st_uid == currentUID
      && status.st_uid == identity.owner
      && status.st_dev == identity.device
      && status.st_ino == identity.inode
  }

  private static func moveToUniqueQuarantine(
    parentDescriptor: Int32,
    leafName: String
  ) throws -> String? {
    for _ in 0..<maximumUniqueNameAttempts {
      let quarantineLeaf = uniqueLeafName(kind: "quarantine")
      if renameatx_np(
        parentDescriptor,
        leafName,
        parentDescriptor,
        quarantineLeaf,
        UInt32(RENAME_EXCL)
      ) == 0 {
        return quarantineLeaf
      }
      if errno == ENOENT { return nil }
      if errno != EEXIST {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    throw POSIXError(.EEXIST)
  }

  @discardableResult
  private static func restoreQuarantinedLeaf(
    parentDescriptor: Int32,
    quarantineLeaf: String,
    destinationLeaf: String
  ) -> Bool {
    renameatx_np(
      parentDescriptor,
      quarantineLeaf,
      parentDescriptor,
      destinationLeaf,
      UInt32(RENAME_EXCL)
    ) == 0
  }
}
