import Foundation
import Testing

@testable import WavesAudioCore

private func policyInput(
  _ appID: String,
  contentType: AdaptiveContentType,
  priority: AdaptivePriority,
  rmsDBFS: Double,
  voiceRatio: Double = 0.2
) -> AdaptiveMixInput {
  let rms = pow(10, rmsDBFS / 20)
  return AdaptiveMixInput(
    appID: appID,
    policy: AdaptiveAppPolicy(contentType: contentType, priority: priority),
    isManaged: true,
    isMuted: false,
    rms: Float(rms),
    voiceBandEnergy: Float(rms * rms * voiceRatio)
  )
}

@Test func legacyAdaptiveRolesMigrateToIndependentPolicyFields() {
  #expect(
    AdaptiveAppPolicy.migrating(
      legacyRole: .voice,
      category: .media
    ) == AdaptiveAppPolicy(contentType: .lectureOrVoice, priority: .normal)
  )
  #expect(
    AdaptiveAppPolicy.migrating(
      legacyRole: .media,
      category: .media,
      bundleIdentifier: "com.spotify.client",
      displayName: "Spotify"
    ) == AdaptiveAppPolicy(contentType: .music, priority: .background)
  )
  #expect(
    AdaptiveAppPolicy.migrating(
      legacyRole: .media,
      category: .media,
      bundleIdentifier: "com.apple.TV",
      displayName: "TV"
    ) == AdaptiveAppPolicy(contentType: .videoOrMedia, priority: .background)
  )
  #expect(
    AdaptiveAppPolicy.migrating(
      legacyRole: .ignore,
      category: .conferencing
    ) == AdaptiveAppPolicy(contentType: .other, priority: .neverAdjust)
  )
  #expect(
    AdaptiveAppPolicy.migrating(
      legacyRole: .auto,
      category: .conferencing
    ) == AdaptiveAppPolicy(contentType: .meeting, priority: .normal)
  )
}

@Test func adaptiveStrategiesProduceCuratedPoliciesAndCustomPreservesEdits() {
  let custom = AdaptiveAppPolicy(contentType: .game, priority: .foreground)

  #expect(
    AdaptiveMixing.policy(
      for: .lectureFocus,
      contentType: .lectureOrVoice,
      existingPolicy: custom
    ).priority == .foreground
  )
  #expect(
    AdaptiveMixing.policy(
      for: .lectureFocus,
      contentType: .music,
      existingPolicy: custom
    ).priority == .background
  )
  #expect(
    AdaptiveMixing.policy(
      for: .mediaFirst,
      contentType: .meeting,
      existingPolicy: custom
    ).priority == .background
  )
  #expect(
    AdaptiveMixing.policy(
      for: .balanced,
      contentType: .game,
      existingPolicy: custom
    ) == AdaptiveAppPolicy(contentType: .game, priority: .normal)
  )
  #expect(
    AdaptiveMixing.policy(
      for: .custom,
      contentType: .music,
      existingPolicy: custom
    ) == custom
  )
}

@Test func adaptivePriorityMatrixUsesGentleModerateAndStrongReductions() {
  #expect(
    AdaptiveMixing.priorityAttenuationDB(
      focus: .foreground,
      app: .normal
    ) == AdaptiveMixing.gentlePriorityReductionDB
  )
  #expect(
    AdaptiveMixing.priorityAttenuationDB(
      focus: .foreground,
      app: .background
    ) == AdaptiveMixing.strongPriorityReductionDB
  )
  #expect(
    AdaptiveMixing.priorityAttenuationDB(
      focus: .normal,
      app: .background
    ) == AdaptiveMixing.moderatePriorityReductionDB
  )
  #expect(
    AdaptiveMixing.priorityAttenuationDB(
      focus: .background,
      app: .foreground
    ) == 0
  )
  #expect(
    AdaptiveMixing.priorityAttenuationDB(
      focus: .foreground,
      app: .neverAdjust
    ) == 0
  )
}

@Test func foregroundLectureDucksBackgroundMusicAfterSpeechActivation() {
  var engine = AdaptivePolicyEngine(usesLoudnessCorrection: false)
  let lecture = policyInput(
    "lecture",
    contentType: .lectureOrVoice,
    priority: .foreground,
    rmsDBFS: -24,
    voiceRatio: 0.8
  )
  let music = policyInput(
    "music",
    contentType: .music,
    priority: .background,
    rmsDBFS: -20
  )

  let first = engine.update(inputs: [lecture, music], elapsed: 0.12)
  #expect(first["music"] == 0)

  let second = engine.update(inputs: [lecture, music], elapsed: 0.12)
  #expect(second["lecture"] == 0)
  #expect(second["music"] == Float(AdaptiveMixing.strongPriorityReductionDB))
}

@Test func foregroundMediaCannotBeDuckedByBackgroundMeeting() {
  var engine = AdaptivePolicyEngine(usesLoudnessCorrection: false)
  let media = policyInput(
    "media",
    contentType: .videoOrMedia,
    priority: .foreground,
    rmsDBFS: -18
  )
  let meeting = policyInput(
    "meeting",
    contentType: .meeting,
    priority: .background,
    rmsDBFS: -24,
    voiceRatio: 0.8
  )

  _ = engine.update(inputs: [media, meeting], elapsed: 0.12)
  let gains = engine.update(inputs: [media, meeting], elapsed: 0.12)

  #expect(gains["media"] == 0)
  #expect(gains["meeting"] == Float(AdaptiveMixing.strongPriorityReductionDB))
}

@Test func neverAdjustIsImmuneToPriorityAndLoudnessGain() {
  var engine = AdaptivePolicyEngine()
  let focus = policyInput(
    "focus",
    contentType: .videoOrMedia,
    priority: .foreground,
    rmsDBFS: -18
  )
  let protected = policyInput(
    "protected",
    contentType: .music,
    priority: .neverAdjust,
    rmsDBFS: -40
  )

  let gains = engine.update(inputs: [focus, protected], elapsed: 10)
  #expect(gains["protected"] == 0)
}

@Test func adaptiveGainUsesSmoothedAttackAndRelease() {
  var state = AdaptivePolicyGainState()

  let halfwayDown = state.update(targetGainDB: -10, elapsed: 0.06)
  #expect(abs(halfwayDown - (-5)) < 0.000_001)
  let fullyDown = state.update(targetGainDB: -10, elapsed: 0.06)
  #expect(abs(fullyDown - (-10)) < 0.000_001)

  let halfwayUp = state.update(targetGainDB: 0, elapsed: 0.45)
  #expect(abs(halfwayUp - (-5)) < 0.000_001)
  let fullyUp = state.update(targetGainDB: 0, elapsed: 0.45)
  #expect(abs(fullyUp) < 0.000_001)
}

@Test func positiveLoudnessCorrectionCannotOverridePriorityReduction() {
  #expect(
    AdaptiveMixing.combinedPolicyGainDB(
      priorityAttenuationDB: -6,
      loudnessTrimDB: 3
    ) == -6
  )
  #expect(
    AdaptiveMixing.combinedPolicyGainDB(
      priorityAttenuationDB: -6,
      loudnessTrimDB: -2
    ) == -8
  )
}
