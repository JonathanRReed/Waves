import AudioToolbox

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

  init(logicalID: String, processObjectIDs: [AudioObjectID]) {
    self.logicalID = logicalID
    self.processObjectIDs = Set(processObjectIDs)
  }

  func matches(_ other: TargetProcessFamily) -> Bool {
    logicalID == other.logicalID && processObjectIDs == other.processObjectIDs
  }

  func covers(_ liveTarget: TargetProcessFamily) -> Bool {
    logicalID == liveTarget.logicalID
      && liveTarget.processObjectIDs.isSubset(of: processObjectIDs)
  }
}
