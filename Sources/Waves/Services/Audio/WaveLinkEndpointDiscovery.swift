import AppKit
import Darwin
import Foundation

/// Locates the loopback control endpoint of the running Wave Link 3 process.
///
/// Wave Link 3 opens its JSON-RPC WebSocket on an ephemeral port chosen at
/// every launch (real installs have been seen on 50845, 53832, and similar)
/// and publishes it in a `ws-info.json` whose macOS location Elgato has never
/// documented. Guessing ports or file paths therefore cannot be the primary
/// strategy. Instead, Waves asks the kernel which TCP ports the *verified*
/// Wave Link process itself is listening on, and uses any published port only
/// to order those candidates. Every candidate is still confirmed by a protocol
/// handshake before it carries a control command.
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

  /// Locations Wave Link 3 has used for `ws-info.json`. Releases before 3.2
  /// ran inside the App Sandbox container; 3.2 left the sandbox, so the plain
  /// Application Support path is expected on current installs. Both are read
  /// and every parsable port becomes an ordering hint.
  static func wsInfoCandidateURLs(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [URL] {
    let relativePaths = [
      "Library/Application Support/com.elgato.WaveLink3/ws-info.json",
      "Library/Containers/com.elgato.WaveLink3/Data/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
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

  /// Every port a readable `ws-info.json` names, most likely location first.
  /// A stale file left behind by an earlier launch is normal and harmless: a
  /// hint that names a port nobody listens on simply orders nothing.
  static func publishedPorts(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [UInt16] {
    var ports: [UInt16] = []
    for url in wsInfoCandidateURLs(homeDirectory: homeDirectory) {
      guard let data = try? Data(contentsOf: url), let port = parsePort(fromWSInfo: data) else { continue }
      if !ports.contains(port) { ports.append(port) }
    }
    return ports
  }

  /// Orders the verified process's listeners: published ports first, in the
  /// order they were published, then everything else ascending so the result
  /// is deterministic for a given process state.
  static func orderedCandidates(
    listeners: [Listener],
    publishedPorts: [UInt16]
  ) -> [Listener] {
    let unique = Array(Set(listeners)).sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    var ordered: [Listener] = []
    for port in publishedPorts {
      for listener in unique where listener.port == port && !ordered.contains(listener) {
        ordered.append(listener)
      }
    }
    for listener in unique where !ordered.contains(listener) {
      ordered.append(listener)
    }
    return ordered
  }

  /// The pids among `runningPIDs` that are the signed Wave Link 3 process.
  /// The verifier is the only authority here: a pid is accepted solely on its
  /// dynamic code signature matching the router's designated requirement.
  static func verifiedProcessIdentifiers(
    runningPIDs: [pid_t],
    descriptor: VerifiedRouterDescriptor = .waveLink3_2_2,
    identityVerifier: IdentityVerifier
  ) -> [pid_t] {
    runningPIDs.filter { pid in
      guard let identity = identityVerifier(pid, descriptor) else { return false }
      return identity.pid == pid
        && identity.teamIdentifier == descriptor.teamIdentifier
        && identity.matchesDesignatedRequirement
    }
    .sorted()
  }

  /// TCP ports `pid` is listening on, read straight from the kernel through
  /// libproc. Same-user processes are inspectable without privileges, which is
  /// exactly the case for the user's own Wave Link. This replaces spawning
  /// `lsof`, which cost a process launch and a system-wide socket scan per
  /// discovery.
  static func listeningTCPPorts(ofPID pid: pid_t) -> [UInt16] {
    let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bufferSize > 0 else { return [] }
    let stride = MemoryLayout<proc_fdinfo>.stride
    // A little headroom: the process may open descriptors between the two
    // calls, and a short read is handled by the length libproc reports back.
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 8)
    let capacity = Int32(descriptors.count * stride)
    let read = descriptors.withUnsafeMutableBytes {
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, capacity)
    }
    guard read > 0 else { return [] }

    var ports = Set<UInt16>()
    for descriptor in descriptors.prefix(Int(read) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
        continue
      }
      guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
      // `insi_lport` is the port in network byte order stored in an int.
      let rawPort = UInt16(truncatingIfNeeded: UInt32(bitPattern: tcp.tcpsi_ini.insi_lport))
      let port = UInt16(bigEndian: rawPort)
      if port != 0 { ports.insert(port) }
    }
    return ports.sorted()
  }

  /// The production candidate list: verified Wave Link 3 processes, their
  /// listening ports, ordered by any published port. Throws a bridge error
  /// that names the exact stage that failed, since that text is what a user
  /// reads in a row note or in Settings.
  static func liveCandidates(
    descriptor: VerifiedRouterDescriptor = .waveLink3_2_2,
    identityVerifier: IdentityVerifier = VerifiedRouterProcessIdentity.verifyLive
  ) throws -> [Listener] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.bundleIdentifier)
      .map(\.processIdentifier)
    guard !running.isEmpty else {
      throw WaveLinkControlBridgeError.unavailable("Wave Link 3 is not running.")
    }
    let verified = verifiedProcessIdentifiers(
      runningPIDs: running,
      descriptor: descriptor,
      identityVerifier: identityVerifier
    )
    guard !verified.isEmpty else {
      throw WaveLinkControlBridgeError.unverifiedLoopbackPeer
    }
    var listeners: [Listener] = []
    for pid in verified {
      for port in listeningTCPPorts(ofPID: pid) {
        listeners.append(Listener(pid: pid, port: port))
      }
    }
    guard !listeners.isEmpty else {
      throw WaveLinkControlBridgeError.unavailable(
        "Wave Link 3 is running but has not opened its control port yet. If it just launched, try again in a moment."
      )
    }
    return orderedCandidates(listeners: listeners, publishedPorts: publishedPorts())
  }
}
