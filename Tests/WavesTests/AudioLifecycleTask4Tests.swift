import AudioToolbox
import Testing

@testable import Waves

@Test func targetProcessFamilyRetiresDeadHelpersWithoutRebuildingCoveredRoute() {
  let controllerTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11, 12]
  )
  let liveTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11]
  )

  #expect(!controllerTarget.matches(liveTarget))
  #expect(controllerTarget.covers(liveTarget))
}

@Test func targetProcessFamilyRequiresRebuildForReturningHelperOrDifferentLogicalFamily() {
  let controllerTarget = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11]
  )
  let returningHelper = TargetProcessFamily(
    logicalID: "com.example.browser",
    processObjectIDs: [11, 12]
  )
  let reusedObjectIDFromAnotherFamily = TargetProcessFamily(
    logicalID: "com.example.other-browser",
    processObjectIDs: [11]
  )

  #expect(!controllerTarget.covers(returningHelper))
  #expect(!controllerTarget.matches(reusedObjectIDFromAnotherFamily))
  #expect(!controllerTarget.covers(reusedObjectIDFromAnotherFamily))
}
