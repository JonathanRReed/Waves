import AudioToolbox
import Foundation
import Security
import WavesAudioCore

struct VerifiedRouterDescriptor: Hashable, Sendable {
  let displayName: String
  let bundleIdentifier: String
  let teamIdentifier: String
  let designatedRequirement: String

  static let waveLink3_2_2 = VerifiedRouterDescriptor(
    displayName: "Elgato Wave Link",
    bundleIdentifier: "com.elgato.WaveLink3",
    teamIdentifier: "Y93VXCB8Q5",
    designatedRequirement:
      "anchor apple generic and identifier \"com.elgato.WaveLink3\" and "
      + "(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or "
      + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
      + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "
      + "certificate leaf[subject.OU] = Y93VXCB8Q5)"
  )

  /// Wave Link 1.x and 2.x ship as `com.elgato.WaveLink` under the same Elgato
  /// team. Their loopback control protocol predates the Wave Link 3 bridge, so
  /// recognizing them yields monitoring-only coexistence: no duplicate audio,
  /// with volume and mute staying in Wave Link itself.
  static let waveLinkLegacy = VerifiedRouterDescriptor(
    displayName: "Elgato Wave Link",
    bundleIdentifier: "com.elgato.WaveLink",
    teamIdentifier: "Y93VXCB8Q5",
    designatedRequirement:
      "anchor apple generic and identifier \"com.elgato.WaveLink\" and "
      + "(certificate leaf[field.1.2.840.113635.100.6.1.9] exists or "
      + "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
      + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "
      + "certificate leaf[subject.OU] = Y93VXCB8Q5)"
  )

  static let supported = [waveLink3_2_2, waveLinkLegacy]

  var hasConstructibleRequirement: Bool {
    var requirement: SecRequirement?
    return SecRequirementCreateWithString(
      designatedRequirement as CFString,
      SecCSFlags(),
      &requirement
    ) == errSecSuccess
  }
}

struct VerifiedRouterProcessObject: Hashable, Sendable {
  let id: AudioObjectID
  let pid: pid_t
  let isRunningOutput: Bool
  /// The bundle identifier Core Audio publishes for the process, when it has
  /// one. `nil` means unknown, which keeps the process eligible for the full
  /// Security.framework check rather than silently skipping it.
  var bundleIdentifier: String? = nil

  /// Whether the process could possibly be the router `descriptor` describes.
  /// A process whose published bundle identifier names a different app is
  /// never that router, so it needs no signature validation at all. The
  /// designated requirement pins the code-signing identifier to the same
  /// string, so an unknown bundle identifier still goes through the full check.
  func mayMatch(_ descriptor: VerifiedRouterDescriptor) -> Bool {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return true }
    return bundleIdentifier.caseInsensitiveCompare(descriptor.bundleIdentifier) == .orderedSame
  }
}

struct VerifiedRouterTapDescription: Hashable, Sendable {
  let processObjectIDs: [AudioObjectID]
  let isExclusive: Bool
}

enum VerifiedRouterTapDescriptionRead: Hashable, Sendable {
  case readable(VerifiedRouterTapDescription)
  case privateTap
  case unreadable
}

struct VerifiedRouterTapObservation: Hashable, Sendable {
  let id: AudioObjectID
  let description: VerifiedRouterTapDescriptionRead
}

struct VerifiedRouterObservationSnapshot: Hashable, Sendable {
  let processObjects: [VerifiedRouterProcessObject]
  let taps: [VerifiedRouterTapObservation]
}

struct VerifiedRouterProcessIdentity: Hashable, Sendable {
  static let signingInformationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)

  let pid: pid_t
  let teamIdentifier: String
  let matchesDesignatedRequirement: Bool
}

struct VerifiedRouterConflict: Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case publicTapMembership
    case unattributableTapFallback
    case routerMixedOutput
  }

  let routerName: String
  let kind: Kind
  let detail: String
  /// True only when the active verified router speaks the Wave Link 3 control
  /// protocol, so the backend knows a bridge apply can possibly succeed.
  /// Legacy Wave Link generations coexist as monitoring-only instead.
  var supportsBridgeControl: Bool = false
}

struct VerifiedRouterActivitySnapshot: Sendable {
  private let routers: [VerifiedRouter]
  private let processObjects: [VerifiedRouterProcessObject]
  private let routerBundleIdentifiers: Set<String>

  init(
    routers: [VerifiedRouter],
    processObjects: [VerifiedRouterProcessObject],
    routerBundleIdentifiers: Set<String>
  ) {
    self.routers = routers
    self.processObjects = processObjects
    self.routerBundleIdentifiers = routerBundleIdentifiers
  }

  func conflict(for app: AudioApp) -> VerifiedRouterConflict? {
    guard let targetPID = app.pid else { return nil }

    if let router = routers.first(where: { $0.pid == targetPID }) {
      return VerifiedRouterConflict(
        routerName: router.descriptor.displayName,
        kind: .routerMixedOutput,
        detail:
          "\(router.descriptor.displayName)'s mixed output can carry every monitored app. "
          + "Waves leaves this router untouched so one nested route cannot duplicate or silence the whole mix. "
          + "Control the upstream apps inside \(router.descriptor.displayName)."
      )
    }

    if let bundleID = app.bundleID, routerBundleIdentifiers.contains(bundleID) {
      return nil
    }

    if let router = routers.sorted(by: { $0.pid < $1.pid }).first {
      let ambiguityDetail =
        routers.count > 1
        ? " Waves found more than one verified routing process, so it cannot narrow the affected app safely."
        : ""
      return VerifiedRouterConflict(
        routerName: router.descriptor.displayName,
        kind: .unattributableTapFallback,
        detail:
          "\(router.descriptor.displayName) is mixing through its Core Audio output, and Core Audio cannot publicly "
          + "attribute its taps to individual apps, so Waves is monitoring only rather than risk a second copy of "
          + "this app's audio. Levels return to Waves when \(router.descriptor.displayName) stops mixing.\(ambiguityDetail)",
        supportsBridgeControl: routers.contains {
          $0.descriptor.bundleIdentifier == VerifiedRouterDescriptor.waveLink3_2_2.bundleIdentifier
        }
      )
    }

    return nil
  }
}

/// Produces route conflicts only from a current Core Audio snapshot and a
/// Security.framework validation of the same running router PID. It is called
/// by backend maintenance and route setup, never by the audio render callback.
final class VerifiedRouterConflictService: @unchecked Sendable {
  typealias SnapshotProvider = @Sendable () -> VerifiedRouterObservationSnapshot
  typealias IdentityVerifier = @Sendable (pid_t, VerifiedRouterDescriptor) -> VerifiedRouterProcessIdentity?
  /// Resolves a process's start time so a cached verification can be bound to
  /// one exact process lifetime. Returning `nil` disables caching for that pid.
  typealias ProcessLifetimeProvider = @Sendable (pid_t) -> AppProcessLifetimeIdentity?

  private let descriptors: [VerifiedRouterDescriptor]
  private let snapshotProvider: SnapshotProvider
  private let identityVerifier: IdentityVerifier
  private let processLifetimeProvider: ProcessLifetimeProvider?
  private let identityCache = VerifiedRouterIdentityCache()

  init(
    descriptors: [VerifiedRouterDescriptor] = VerifiedRouterDescriptor.supported,
    snapshotProvider: @escaping SnapshotProvider = VerifiedRouterObservationSnapshot.live,
    identityVerifier: @escaping IdentityVerifier = VerifiedRouterProcessIdentity.verifyLive,
    processLifetimeProvider: ProcessLifetimeProvider? = nil
  ) {
    self.descriptors = descriptors.filter(\.hasConstructibleRequirement)
    self.snapshotProvider = snapshotProvider
    self.identityVerifier = identityVerifier
    self.processLifetimeProvider = processLifetimeProvider
  }

  /// The production service: live Core Audio snapshots, live Security checks,
  /// and verification results cached per process lifetime. The activity view is
  /// rebuilt several times a second, and a code-signature validation costs on
  /// the order of ten milliseconds per process, so without the cache the
  /// router check alone could occupy a large share of one core whenever audio
  /// was playing.
  static func live() -> VerifiedRouterConflictService {
    VerifiedRouterConflictService(processLifetimeProvider: RuntimeProcessIdentity.processLifetime)
  }

  func conflict(for app: AudioApp) -> VerifiedRouterConflict? {
    activitySnapshot().conflict(for: app)
  }

  /// Produces one immutable verified-router activity view for a route setup or
  /// maintenance pass. Consumers must reuse it for every target in that pass.
  func activitySnapshot() -> VerifiedRouterActivitySnapshot {
    let initialSnapshot = snapshotProvider()
    let initialRouters = verifiedRouters(in: initialSnapshot)
    guard !initialRouters.isEmpty else {
      return VerifiedRouterActivitySnapshot(
        routers: [],
        processObjects: initialSnapshot.processObjects,
        routerBundleIdentifiers: Set(descriptors.map(\.bundleIdentifier))
      )
    }

    // Refresh Core Audio after Security checked the guest code. A pid can be
    // recycled, and a process object can disappear between reads. Requiring the
    // same PID plus the same process-object ID in both snapshots turns either
    // condition into a safe no-conflict result.
    let currentSnapshot = snapshotProvider()
    let currentRouters = verifiedRouters(
      in: currentSnapshot,
      constrainedTo: initialRouters
    )
    return VerifiedRouterActivitySnapshot(
      routers: currentRouters,
      processObjects: currentSnapshot.processObjects,
      routerBundleIdentifiers: Set(descriptors.map(\.bundleIdentifier))
    )
  }

  private func verifiedRouters(
    in snapshot: VerifiedRouterObservationSnapshot,
    constrainedTo initialRouters: [VerifiedRouter] = []
  ) -> [VerifiedRouter] {
    let candidates = snapshot.processObjects.filter(\.isRunningOutput)
    identityCache.retain(pids: Set(candidates.map(\.pid)))
    var results: [VerifiedRouter] = []
    for descriptor in descriptors {
      for process in candidates where process.mayMatch(descriptor) {
        let router = VerifiedRouter(descriptor: descriptor, pid: process.pid, processObjectID: process.id)
        // The confirmation pass only re-checks routers the first pass found;
        // everything else is skipped before any Security work happens.
        if !initialRouters.isEmpty, !initialRouters.contains(router) { continue }
        guard let identity = verifiedIdentity(pid: process.pid, descriptor: descriptor) else { continue }
        guard identity.pid == process.pid,
          identity.teamIdentifier == descriptor.teamIdentifier,
          identity.matchesDesignatedRequirement
        else {
          continue
        }
        results.append(router)
      }
    }
    return Array(Set(results))
  }

  /// Verifies through the per-lifetime cache when a lifetime is resolvable.
  /// A pid that cannot be bound to a start time is verified fresh every time,
  /// so a recycled pid can never inherit a previous process's verdict.
  private func verifiedIdentity(
    pid: pid_t,
    descriptor: VerifiedRouterDescriptor
  ) -> VerifiedRouterProcessIdentity? {
    guard let lifetime = processLifetimeProvider?(pid) else {
      return identityVerifier(pid, descriptor)
    }
    let key = VerifiedRouterIdentityCache.Key(pid: pid, descriptorBundleIdentifier: descriptor.bundleIdentifier)
    if let cached = identityCache.identity(for: key, lifetime: lifetime) {
      return cached.identity
    }
    let identity = identityVerifier(pid, descriptor)
    identityCache.store(identity, for: key, lifetime: lifetime)
    return identity
  }

}

/// Verification verdicts keyed by pid and descriptor, valid for exactly one
/// process lifetime. Both positive and negative verdicts are kept: a signature
/// cannot change while the process runs, and re-validating a non-router that
/// happens to publish the router's bundle identifier would cost just as much.
final class VerifiedRouterIdentityCache: @unchecked Sendable {
  struct Key: Hashable, Sendable {
    let pid: pid_t
    let descriptorBundleIdentifier: String
  }

  struct Entry: Sendable {
    let lifetime: AppProcessLifetimeIdentity
    let identity: VerifiedRouterProcessIdentity?
  }

  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]

  func identity(for key: Key, lifetime: AppProcessLifetimeIdentity) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[key], entry.lifetime == lifetime else { return nil }
    return entry
  }

  func store(
    _ identity: VerifiedRouterProcessIdentity?,
    for key: Key,
    lifetime: AppProcessLifetimeIdentity
  ) {
    lock.lock()
    defer { lock.unlock() }
    entries[key] = Entry(lifetime: lifetime, identity: identity)
  }

  /// Drops verdicts for processes that no longer run output, so the cache
  /// tracks the live process list instead of growing for the session.
  func retain(pids: Set<pid_t>) {
    lock.lock()
    defer { lock.unlock() }
    guard !entries.isEmpty else { return }
    entries = entries.filter { pids.contains($0.key.pid) }
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }
}

struct VerifiedRouter: Hashable, Sendable {
  let descriptor: VerifiedRouterDescriptor
  let pid: pid_t
  let processObjectID: AudioObjectID
}

private extension VerifiedRouterObservationSnapshot {
  static func live() -> VerifiedRouterObservationSnapshot {
    let processObjects = readProcessObjects()
    return VerifiedRouterObservationSnapshot(processObjects: processObjects, taps: readTaps())
  }

  private static func readProcessObjects() -> [VerifiedRouterProcessObject] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount
      ) == noErr,
      byteCount % UInt32(MemoryLayout<AudioObjectID>.size) == 0
    else {
      return []
    }
    var objectIDs = [AudioObjectID](
      repeating: AudioObjectID(kAudioObjectUnknown),
      count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
    )
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount,
        &objectIDs
      ) == noErr
    else {
      return []
    }
    return objectIDs.compactMap { processObjectID in
      guard processObjectID != AudioObjectID(kAudioObjectUnknown),
        let pid = readProcessPID(processObjectID)
      else {
        return nil
      }
      let isRunningOutput = readProcessIsRunningOutput(processObjectID)
      return VerifiedRouterProcessObject(
        id: processObjectID,
        pid: pid,
        isRunningOutput: isRunningOutput,
        // Only running-output processes are verification candidates, so only
        // they need the bundle identifier that lets the service skip them.
        bundleIdentifier: isRunningOutput ? readProcessBundleID(processObjectID) : nil
      )
    }
  }

  private static func readProcessBundleID(_ processObjectID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let expectedSize = UInt32(MemoryLayout<CFString?>.size)
    var readSize = expectedSize
    var rawBundleID: CFString?
    let status = withUnsafeMutablePointer(to: &rawBundleID) {
      AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &readSize, $0)
    }
    guard status == noErr, readSize == expectedSize, let rawBundleID else { return nil }
    let bundleID = rawBundleID as String
    return bundleID.isEmpty ? nil : bundleID
  }

  private static func readTaps() -> [VerifiedRouterTapObservation] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTapList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount
      ) == noErr,
      byteCount % UInt32(MemoryLayout<AudioObjectID>.size) == 0
    else {
      return []
    }
    var tapIDs = [AudioObjectID](
      repeating: AudioObjectID(kAudioObjectUnknown),
      count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
    )
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount,
        &tapIDs
      ) == noErr
    else {
      return []
    }
    return tapIDs.compactMap { tapID in
      guard tapID != AudioObjectID(kAudioObjectUnknown) else { return nil }
      return VerifiedRouterTapObservation(id: tapID, description: readTapDescription(tapID))
    }
  }

  private static func readProcessPID(_ processObjectID: AudioObjectID) -> pid_t? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var pid = pid_t()
    var byteCount = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &byteCount, &pid) == noErr,
      byteCount == UInt32(MemoryLayout<pid_t>.size)
    else {
      return nil
    }
    return pid
  }

  private static func readProcessIsRunningOutput(_ processObjectID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningOutput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var isRunningOutput: UInt32 = 0
    var byteCount = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(
      processObjectID,
      &address,
      0,
      nil,
      &byteCount,
      &isRunningOutput
    ) == noErr && byteCount == UInt32(MemoryLayout<UInt32>.size) && isRunningOutput != 0
  }

  private static func readTapDescription(_ tapID: AudioObjectID) -> VerifiedRouterTapDescriptionRead {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyDescription,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var description: Unmanaged<CFTypeRef>?
    var byteCount = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
    guard
      AudioObjectGetPropertyData(
        tapID,
        &address,
        0,
        nil,
        &byteCount,
        &description
      ) == noErr,
      byteCount == UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size),
      let description
    else {
      return .unreadable
    }
    let tapDescription = description.takeRetainedValue() as! CATapDescription
    if tapDescription.isPrivate { return .privateTap }
    return .readable(
      VerifiedRouterTapDescription(
        processObjectIDs: tapDescription.processes.map { $0 },
        isExclusive: tapDescription.isExclusive
      ))
  }
}

extension VerifiedRouterProcessIdentity {
  static func verifyLive(
    pid: pid_t,
    descriptor: VerifiedRouterDescriptor
  ) -> VerifiedRouterProcessIdentity? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
      let code
    else {
      return nil
    }
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        descriptor.designatedRequirement as CFString,
        SecCSFlags(),
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return nil
    }
    let requirementMatches = SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        signingInformationFlags,
        &information
      ) == errSecSuccess,
      let information,
      let teamIdentifier = (information as NSDictionary)[kSecCodeInfoTeamIdentifier] as? String
    else {
      return nil
    }
    return VerifiedRouterProcessIdentity(
      pid: pid,
      teamIdentifier: teamIdentifier,
      matchesDesignatedRequirement: requirementMatches
    )
  }
}
