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
          "Core Audio cannot publicly attribute the system tap list to verified \(router.descriptor.displayName). "
          + "Because its verified routing process owns active Core Audio output, Waves is monitoring only to avoid "
          + "duplicate or silent playback until that router releases the path.\(ambiguityDetail)",
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

  private let descriptors: [VerifiedRouterDescriptor]
  private let snapshotProvider: SnapshotProvider
  private let identityVerifier: IdentityVerifier

  init(
    descriptors: [VerifiedRouterDescriptor] = VerifiedRouterDescriptor.supported,
    snapshotProvider: @escaping SnapshotProvider = VerifiedRouterObservationSnapshot.live,
    identityVerifier: @escaping IdentityVerifier = VerifiedRouterProcessIdentity.verifyLive
  ) {
    self.descriptors = descriptors.filter(\.hasConstructibleRequirement)
    self.snapshotProvider = snapshotProvider
    self.identityVerifier = identityVerifier
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
    var results: [VerifiedRouter] = []
    for descriptor in descriptors {
      for process in candidates {
        guard let identity = identityVerifier(process.pid, descriptor) else { continue }
        guard identity.pid == process.pid,
          identity.teamIdentifier == descriptor.teamIdentifier,
          identity.matchesDesignatedRequirement
        else {
          continue
        }
        let router = VerifiedRouter(descriptor: descriptor, pid: process.pid, processObjectID: process.id)
        if !initialRouters.isEmpty, !initialRouters.contains(router) { continue }
        results.append(router)
      }
    }
    return Array(Set(results))
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
      return VerifiedRouterProcessObject(
        id: processObjectID,
        pid: pid,
        isRunningOutput: readProcessIsRunningOutput(processObjectID)
      )
    }
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
