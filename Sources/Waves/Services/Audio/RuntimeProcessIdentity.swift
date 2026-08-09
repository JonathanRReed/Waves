import Darwin
import Foundation
import Security
import WavesAudioCore

struct RuntimeProcessProbe: Equatable, Sendable {
  let lifetime: AppProcessLifetimeIdentity
  let executablePath: String
  let outerBundlePath: String
}

enum RuntimeProcessIdentity {
  static func probe(pid: pid_t) -> RuntimeProcessProbe? {
    guard pid > 0,
      let lifetime = processLifetime(pid: pid),
      let executablePath = canonicalExecutablePath(pid: pid),
      let outerBundlePath = canonicalOuterBundlePath(forExecutablePath: executablePath)
    else {
      return nil
    }
    return RuntimeProcessProbe(
      lifetime: lifetime,
      executablePath: executablePath,
      outerBundlePath: outerBundlePath
    )
  }

  static func capture(
    pid: pid_t,
    expectedProbe: RuntimeProcessProbe? = nil
  ) -> AppRuntimeIdentity? {
    guard let initialProbe = expectedProbe ?? probe(pid: pid),
      initialProbe.lifetime.pid == pid,
      let signingIdentity = validatedSigningIdentity(pid: pid),
      probe(pid: pid) == initialProbe
    else {
      return nil
    }

    return AppRuntimeIdentity(
      lifetime: initialProbe.lifetime,
      executablePath: initialProbe.executablePath,
      outerBundlePath: initialProbe.outerBundlePath,
      signingIdentity: signingIdentity
    )
  }

  static func captureLive(pid: pid_t) -> AppRuntimeIdentity? {
    capture(pid: pid)
  }

  private static func processLifetime(pid: pid_t) -> AppProcessLifetimeIdentity? {
    var info = proc_bsdinfo()
    let expectedSize = MemoryLayout<proc_bsdinfo>.size
    let readSize = proc_pidinfo(
      pid,
      PROC_PIDTBSDINFO,
      0,
      &info,
      Int32(expectedSize)
    )
    guard readSize == expectedSize, info.pbi_pid == UInt32(pid) else { return nil }
    return AppProcessLifetimeIdentity(
      pid: pid,
      startTimeSeconds: info.pbi_start_tvsec,
      startTimeMicroseconds: info.pbi_start_tvusec
    )
  }

  private static func canonicalExecutablePath(pid: pid_t) -> String? {
    let maximumPathSize = 4 * 1_024
    var pathBuffer = [CChar](repeating: 0, count: maximumPathSize)
    let length = proc_pidpath(pid, &pathBuffer, UInt32(maximumPathSize))
    guard length > 0 else { return nil }
    let path = pathBuffer.withUnsafeBufferPointer { buffer in
      buffer.baseAddress.map(String.init(cString:))
    }
    guard let path, !path.isEmpty else { return nil }
    return canonicalPath(path)
  }

  private static func canonicalOuterBundlePath(forExecutablePath path: String) -> String? {
    guard let bundlePath = AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: path) else {
      return nil
    }
    return canonicalPath(bundlePath)
  }

  private static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }

  private static func validatedSigningIdentity(pid: pid_t) -> AppCodeSigningIdentity? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
      let code,
      SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    else {
      return nil
    }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }

    let informationFlags = SecCSFlags(
      rawValue: UInt32(kSecCSSigningInformation | kSecCSRequirementInformation)
    )
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, informationFlags, &information) == errSecSuccess,
      let information
    else {
      return nil
    }

    let values = information as NSDictionary
    guard let identifier = values[kSecCodeInfoIdentifier] as? String,
      !identifier.isEmpty,
      let rawRequirement = values[kSecCodeInfoDesignatedRequirement],
      let codeDirectoryHash = values[kSecCodeInfoUnique] as? Data,
      !codeDirectoryHash.isEmpty
    else {
      return nil
    }
    guard CFGetTypeID(rawRequirement as CFTypeRef) == SecRequirementGetTypeID() else {
      return nil
    }
    let requirement = unsafeBitCast(rawRequirement as AnyObject, to: SecRequirement.self)

    var requirementText: CFString?
    guard SecRequirementCopyString(requirement, SecCSFlags(), &requirementText) == errSecSuccess,
      let requirementText
    else {
      return nil
    }

    return AppCodeSigningIdentity(
      identifier: identifier,
      teamIdentifier: values[kSecCodeInfoTeamIdentifier] as? String,
      designatedRequirement: requirementText as String,
      codeDirectoryHash: codeDirectoryHash
    )
  }
}

/// Bounded off-realtime cache for repeated discovery and route-maintenance
/// lookups. A cheap process-lifetime/path probe is performed on every lookup;
/// any PID reuse or path change invalidates the entry before it can be reused.
final class RuntimeProcessIdentityCache: @unchecked Sendable {
  typealias ProbeProvider = @Sendable (pid_t) -> RuntimeProcessProbe?
  typealias CaptureProvider = @Sendable (pid_t, RuntimeProcessProbe) -> AppRuntimeIdentity?

  static let shared = RuntimeProcessIdentityCache()

  private struct Entry {
    let probe: RuntimeProcessProbe
    let identity: AppRuntimeIdentity
    var lastAccess: UInt64
  }

  private let lock = NSLock()
  private let maximumEntryCount: Int
  private let probeProvider: ProbeProvider
  private let captureProvider: CaptureProvider
  private var entries: [pid_t: Entry] = [:]
  private var accessSequence: UInt64 = 0

  init(
    maximumEntryCount: Int = 256,
    probeProvider: @escaping ProbeProvider = RuntimeProcessIdentity.probe,
    captureProvider: @escaping CaptureProvider = { pid, probe in
      RuntimeProcessIdentity.capture(pid: pid, expectedProbe: probe)
    }
  ) {
    self.maximumEntryCount = max(1, maximumEntryCount)
    self.probeProvider = probeProvider
    self.captureProvider = captureProvider
  }

  func identity(pid: pid_t) -> AppRuntimeIdentity? {
    guard let currentProbe = probeProvider(pid) else {
      lock.withLock { _ = entries.removeValue(forKey: pid) }
      return nil
    }

    if let cached = lock.withLock({ () -> AppRuntimeIdentity? in
      guard var entry = entries[pid], entry.probe == currentProbe else {
        entries.removeValue(forKey: pid)
        return nil
      }
      accessSequence &+= 1
      entry.lastAccess = accessSequence
      entries[pid] = entry
      return entry.identity
    }) {
      return cached
    }

    guard let identity = captureProvider(pid, currentProbe),
      identity.lifetime == currentProbe.lifetime,
      identity.executablePath == currentProbe.executablePath,
      identity.outerBundlePath == currentProbe.outerBundlePath
    else {
      return nil
    }

    lock.withLock {
      accessSequence &+= 1
      entries[pid] = Entry(
        probe: currentProbe,
        identity: identity,
        lastAccess: accessSequence
      )
      if entries.count > maximumEntryCount,
        let leastRecentPID = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
      {
        entries.removeValue(forKey: leastRecentPID)
      }
    }
    return identity
  }
}
