import Foundation

/// Locates the loopback control endpoint of the running Wave Link 3 process.
///
/// Wave Link 3 publishes its WebSocket port in `ws-info.json` and picks a new
/// port on every launch, falling back to the 1884-1893 range when nothing is
/// published. Every candidate port must still be owned by the verified Wave
/// Link process before Waves connects, so a stale file or a squatting process
/// can never receive control traffic.
enum WaveLinkEndpointDiscovery {
  typealias IdentityVerifier =
    @Sendable (
      pid_t,
      VerifiedRouterDescriptor
    ) -> VerifiedRouterProcessIdentity?

  struct Listener: Hashable, Sendable {
    let pid: pid_t
    let port: UInt16
  }

  static let fallbackPorts: [UInt16] = Array(1884...1893)

  /// Locations Wave Link 3 uses for `ws-info.json`, most specific first.
  static func wsInfoCandidateURLs(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [URL] {
    let relativePaths = [
      "Library/Containers/com.elgato.WaveLink3/Data/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
      "Library/Application Support/com.elgato.WaveLink3/ws-info.json",
    ]
    return relativePaths.map { homeDirectory.appendingPathComponent($0, isDirectory: false) }
  }

  static func parsePort(fromWSInfo data: Data) -> UInt16? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let portNumber = object["port"] as? NSNumber
    else {
      return nil
    }
    let portValue = portNumber.intValue
    guard (1...Int(UInt16.max)).contains(portValue) else { return nil }
    return UInt16(portValue)
  }

  static func publishedPort(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> UInt16? {
    for url in wsInfoCandidateURLs(homeDirectory: homeDirectory) {
      guard let data = try? Data(contentsOf: url) else { continue }
      if let port = parsePort(fromWSInfo: data) { return port }
    }
    return nil
  }

  /// The published port first, then the documented fallback scan range.
  static func candidatePorts(publishedPort: UInt16?) -> [UInt16] {
    var ports: [UInt16] = []
    if let publishedPort { ports.append(publishedPort) }
    for port in fallbackPorts where !ports.contains(port) {
      ports.append(port)
    }
    return ports
  }

  /// Parses `lsof -Fpn` output into pid/port listener pairs. A `p` line sets
  /// the current process and each `n` line names one bound address.
  static func parseListeners(_ output: String) -> [Listener] {
    var listeners: [Listener] = []
    var currentPID: pid_t?
    for line in output.split(whereSeparator: \.isNewline) {
      switch line.first {
      case "p":
        currentPID = pid_t(line.dropFirst())
      case "n":
        guard
          let currentPID,
          let separatorIndex = line.lastIndex(of: ":"),
          let port = UInt16(line[line.index(after: separatorIndex)...])
        else {
          continue
        }
        listeners.append(Listener(pid: currentPID, port: port))
      default:
        continue
      }
    }
    return Array(Set(listeners)).sorted {
      ($0.port, $0.pid) < ($1.port, $1.pid)
    }
  }

  /// Returns the first candidate port whose loopback listener is the verified
  /// Wave Link process, preserving the candidate priority order.
  static func verifiedEndpoint(
    candidatePorts: [UInt16],
    listeners: [Listener],
    descriptor: VerifiedRouterDescriptor = .waveLink3_2_2,
    identityVerifier: IdentityVerifier
  ) throws -> Listener {
    guard !listeners.isEmpty else {
      throw WaveLinkControlBridgeError.unavailable(
        "Wave Link's control service is not listening on any known loopback port."
      )
    }
    for port in candidatePorts {
      for listener in listeners where listener.port == port {
        guard let identity = identityVerifier(listener.pid, descriptor) else { continue }
        guard identity.pid == listener.pid,
          identity.teamIdentifier == descriptor.teamIdentifier,
          identity.matchesDesignatedRequirement
        else {
          continue
        }
        return listener
      }
    }
    throw WaveLinkControlBridgeError.unverifiedLoopbackPeer
  }

  static func liveListeners(candidatePorts: [UInt16]) throws -> [Listener] {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments =
      ["-nP", "-a"]
      + candidatePorts.map { "-iTCP:\($0)" }
      + ["-sTCP:LISTEN", "-Fpn"]
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
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    // lsof exits nonzero when no candidate port has a listener; report that as
    // an unavailable service rather than a verification failure.
    guard process.terminationStatus == 0 else { return [] }
    guard let output = String(data: data, encoding: .utf8) else {
      throw WaveLinkControlBridgeError.protocolViolation(
        "The loopback listener inspection was not UTF-8."
      )
    }
    return parseListeners(output)
  }
}

/// Resolves and caches the verified Wave Link control endpoint. The cache is
/// reused only while the same verified process is still running; any doubt
/// triggers a full rediscovery, and any failure surfaces as a bridge error so
/// callers keep failing closed.
actor WaveLinkVerifiedEndpointResolver {
  typealias Discover = @Sendable () throws -> WaveLinkEndpointDiscovery.Listener
  typealias RevalidateCached = @Sendable (WaveLinkEndpointDiscovery.Listener) -> Bool

  private let discover: Discover
  private let revalidateCached: RevalidateCached
  private var cached: WaveLinkEndpointDiscovery.Listener?

  init(
    discover: @escaping Discover = WaveLinkVerifiedEndpointResolver.liveDiscovery,
    revalidateCached: @escaping RevalidateCached = WaveLinkVerifiedEndpointResolver.liveRevalidation
  ) {
    self.discover = discover
    self.revalidateCached = revalidateCached
  }

  func verifiedEndpoint() async throws -> WaveLinkEndpointDiscovery.Listener {
    if let cached, revalidateCached(cached) { return cached }
    cached = nil
    let discover = self.discover
    let endpoint = try await Task.detached(priority: .utility) {
      try discover()
    }.value
    cached = endpoint
    return endpoint
  }

  func invalidate() {
    cached = nil
  }

  private static let liveDiscovery: Discover = {
    let candidatePorts = WaveLinkEndpointDiscovery.candidatePorts(
      publishedPort: WaveLinkEndpointDiscovery.publishedPort()
    )
    let listeners = try WaveLinkEndpointDiscovery.liveListeners(candidatePorts: candidatePorts)
    return try WaveLinkEndpointDiscovery.verifiedEndpoint(
      candidatePorts: candidatePorts,
      listeners: listeners,
      identityVerifier: VerifiedRouterProcessIdentity.verifyLive
    )
  }

  private static let liveRevalidation: RevalidateCached = { cached in
    guard
      let identity = VerifiedRouterProcessIdentity.verifyLive(
        pid: cached.pid,
        descriptor: .waveLink3_2_2
      )
    else {
      return false
    }
    return identity.pid == cached.pid
      && identity.teamIdentifier == VerifiedRouterDescriptor.waveLink3_2_2.teamIdentifier
      && identity.matchesDesignatedRequirement
  }
}
