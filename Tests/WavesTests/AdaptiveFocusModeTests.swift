import Foundation
import Testing

@testable import WavesAudioCore

private func focusInput(
  _ appID: String,
  contentType: AdaptiveContentType = .music,
  priority: AdaptivePriority,
  rmsDBFS: Double = -20,
  voiceRatio: Double = 0.2,
  isManaged: Bool = true,
  isFrontmost: Bool = false
) -> AdaptiveMixInput {
  let rms = pow(10, rmsDBFS / 20)
  return AdaptiveMixInput(
    appID: appID,
    policy: AdaptiveAppPolicy(contentType: contentType, priority: priority),
    isManaged: isManaged,
    isMuted: false,
    rms: Float(rms),
    voiceBandEnergy: Float(rms * rms * voiceRatio),
    isFrontmost: isFrontmost
  )
}

@Test func adaptiveFocusModesAreCodableAndUseRequestedDisplayNames() throws {
  #expect(AdaptiveFocusMode.assignedPriorities.displayName == "Assigned Priorities")
  #expect(AdaptiveFocusMode.followFrontApp.displayName == "Follow Front App")
  #expect(AdaptiveFocusMode.smartHybrid.displayName == "Smart Hybrid")

  for mode in AdaptiveFocusMode.allCases {
    let data = try JSONEncoder().encode(mode)
    #expect(try JSONDecoder().decode(AdaptiveFocusMode.self, from: data) == mode)
  }

  #expect(AdaptivePolicyEngine().focusMode == .smartHybrid)
}

@Test func assignedPrioritiesIgnoresFrontmostPromotion() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .assignedPriorities
  )
  let frontmostBackground = focusInput(
    "front",
    priority: .background,
    isFrontmost: true
  )
  let normal = focusInput("normal", priority: .normal)

  let gains = engine.update(
    inputs: [frontmostBackground, normal],
    elapsed: 0.12
  )

  #expect(gains["front"] == Float(AdaptiveMixing.moderatePriorityReductionDB))
  #expect(gains["normal"] == 0)
}

@Test func followFrontAppPromotesAudibleFrontmostSourceToForeground() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .followFrontApp
  )
  let frontmostBackground = focusInput(
    "front",
    priority: .background,
    isFrontmost: true
  )
  let normal = focusInput("normal", priority: .normal)

  let gains = engine.update(
    inputs: [frontmostBackground, normal],
    elapsed: 0.12
  )

  #expect(gains["front"] == 0)
  #expect(gains["normal"] == Float(AdaptiveMixing.gentlePriorityReductionDB))
}

@Test func smartHybridPromotesAudibleFrontmostSourceExactlyOneTier() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .smartHybrid
  )
  let frontmostBackground = focusInput(
    "front",
    priority: .background,
    isFrontmost: true
  )
  let normal = focusInput("normal", priority: .normal)

  let gains = engine.update(
    inputs: [frontmostBackground, normal],
    elapsed: 0.12
  )

  #expect(gains["front"] == 0)
  #expect(gains["normal"] == 0)
}

@Test func smartHybridPromotesFrontmostNormalSourceToForeground() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .smartHybrid
  )
  let frontmostNormal = focusInput(
    "front",
    priority: .normal,
    isFrontmost: true
  )
  let normal = focusInput("normal", priority: .normal)

  let gains = engine.update(inputs: [frontmostNormal, normal], elapsed: 0.12)

  #expect(gains["front"] == 0)
  #expect(gains["normal"] == Float(AdaptiveMixing.gentlePriorityReductionDB))
}

@Test func smartHybridLeavesFrontmostForegroundSourceAtForeground() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .smartHybrid
  )
  let frontmostForeground = focusInput(
    "front",
    priority: .foreground,
    isFrontmost: true
  )
  let normal = focusInput("normal", priority: .normal)

  let gains = engine.update(inputs: [frontmostForeground, normal], elapsed: 0.12)

  #expect(gains["front"] == 0)
  #expect(gains["normal"] == Float(AdaptiveMixing.gentlePriorityReductionDB))
}

@Test func silentFrontmostAppDoesNotEstablishFocus() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .followFrontApp
  )
  let silentFrontmost = focusInput(
    "silent",
    priority: .normal,
    rmsDBFS: -80,
    isFrontmost: true
  )
  let audibleBackground = focusInput("audible", priority: .background)

  let gains = engine.update(
    inputs: [silentFrontmost, audibleBackground],
    elapsed: 0.12
  )

  #expect(gains["silent"] == 0)
  #expect(gains["audible"] == 0)
}

@Test func neverAdjustFrontmostAppIsNeverPromotedOrAdjusted() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .followFrontApp
  )
  let protectedFrontmost = focusInput(
    "protected",
    priority: .neverAdjust,
    isFrontmost: true
  )
  let audibleBackground = focusInput("audible", priority: .background)

  let gains = engine.update(
    inputs: [protectedFrontmost, audibleBackground],
    elapsed: 10
  )

  #expect(gains["protected"] == 0)
  #expect(gains["audible"] == 0)
}

@Test func smartHybridBackgroundMeetingCannotLeapfrogForegroundMedia() {
  var engine = AdaptivePolicyEngine(
    usesLoudnessCorrection: false,
    focusMode: .smartHybrid
  )
  let meeting = focusInput(
    "meeting",
    contentType: .meeting,
    priority: .background,
    rmsDBFS: -24,
    voiceRatio: 0.8,
    isFrontmost: true
  )
  let inactiveMedia = focusInput(
    "media",
    contentType: .videoOrMedia,
    priority: .foreground,
    isManaged: false
  )
  _ = engine.update(inputs: [meeting, inactiveMedia], elapsed: 0.12)

  let activeMedia = focusInput(
    "media",
    contentType: .videoOrMedia,
    priority: .foreground
  )
  let gains = engine.update(inputs: [meeting, activeMedia], elapsed: 0.12)

  #expect(gains["media"] == 0)
  #expect(gains["meeting"] == Float(AdaptiveMixing.gentlePriorityReductionDB))
}
