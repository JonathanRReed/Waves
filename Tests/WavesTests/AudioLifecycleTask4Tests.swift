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

@Test func callbackRenderStateUsesPreallocatedAtomicValuesAndCoalescesGeometryRecovery() {
  let state = TapRenderStateBox(
    initialState: TapRenderState(
      volume: 0.5,
      volumeBoost: 2,
      isMuted: 0,
      isActive: 1,
      peakLevel: 0,
      rmsLevel: 0,
      analysisRMS: 0,
      voiceBandEnergy: 0,
      renderTick: 0
    )
  )

  state.markRenderTick()
  state.writeLevels(peakLevel: 0.8, rmsLevel: 0.4, analysisRMS: 0.3, voiceBandEnergy: 0.2)
  state.flagGeometryMismatch()
  state.flagGeometryMismatch()
  state.setInactive()

  #expect(state.read().renderTick == 1)
  #expect(state.read().peakLevel == 0.8)
  #expect(state.read().isActive == 0)
  #expect(state.consumeGeometryMismatch())
  #expect(!state.consumeGeometryMismatch())
}
