import AudioToolbox
import WavesAudioCore

struct ResolvedProcessObject: Equatable, Sendable {
  let id: AudioObjectID
  let runtimeIdentity: AppRuntimeIdentity?
}

struct ResolvedProcessTarget: Equatable, Sendable {
  let targetRuntimeIdentity: AppRuntimeIdentity?
  let processes: [ResolvedProcessObject]
  let requiresLiveIdentityValidation: Bool

  var processObjectIDs: [AudioObjectID] {
    processes.map(\.id)
  }

  var processLifetimeIdentities: [AppProcessLifetimeIdentity] {
    var identities = processes.compactMap { $0.runtimeIdentity?.lifetime }
    if let targetRuntimeIdentity {
      identities.append(targetRuntimeIdentity.lifetime)
    }
    return Array(Set(identities))
  }

  static func testing(processObjectIDs: [AudioObjectID]) -> ResolvedProcessTarget {
    ResolvedProcessTarget(
      targetRuntimeIdentity: nil,
      processes: processObjectIDs.map { id in
        ResolvedProcessObject(id: id, runtimeIdentity: nil)
      },
      requiresLiveIdentityValidation: false
    )
  }
}

/// The logical app family and the Core Audio process objects a tap was built
/// around. `matches` and `covers` deliberately answer different questions.
///
/// Exact matching includes the logical family, so a reused Core Audio object
/// ID cannot attach a controller to another app. Coverage is directional: a
/// controller may continue to cover a live family after one of its helpers
/// exits, but a newly audible helper needs one intentional rebuild.
struct TargetProcessFamily: Equatable, Sendable {
  let logicalID: String
  let processObjectIDs: Set<AudioObjectID>
  let processLifetimeIdentities: Set<AppProcessLifetimeIdentity>

  init(
    logicalID: String,
    processObjectIDs: [AudioObjectID],
    processLifetimeIdentities: [AppProcessLifetimeIdentity] = []
  ) {
    self.logicalID = logicalID
    self.processObjectIDs = Set(processObjectIDs)
    self.processLifetimeIdentities = Set(processLifetimeIdentities)
  }

  func matches(_ other: TargetProcessFamily) -> Bool {
    logicalID == other.logicalID
      && processObjectIDs == other.processObjectIDs
      && processLifetimeIdentities == other.processLifetimeIdentities
  }

  func covers(_ liveTarget: TargetProcessFamily) -> Bool {
    logicalID == liveTarget.logicalID
      && liveTarget.processObjectIDs.isSubset(of: processObjectIDs)
      && liveTarget.processLifetimeIdentities.isSubset(of: processLifetimeIdentities)
  }
}
