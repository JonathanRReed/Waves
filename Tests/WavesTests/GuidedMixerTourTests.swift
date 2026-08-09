import CoreGraphics
import Testing

@testable import Waves

@MainActor
@Test func guidedMixerTourHasFourFocusedMoments() {
  #expect(
    GuidedMixerTourMoment.allCases
      == [.chooseSound, .setLevel, .muteAndRestore, .goFurther]
  )
}

@Test func tourOverlayChoosesTheOppositeVerticalEdgeFromItsTarget() {
  #expect(
    GuidedTourOverlayPlacement.resolve(
      targetFrame: CGRect(x: 0, y: 80, width: 600, height: 60),
      containerHeight: 760
    ) == .bottomTrailing
  )
  #expect(
    GuidedTourOverlayPlacement.resolve(
      targetFrame: CGRect(x: 0, y: 620, width: 600, height: 60),
      containerHeight: 760
    ) == .topTrailing
  )
  #expect(
    GuidedTourOverlayPlacement.resolve(
      targetFrame: nil,
      containerHeight: 760
    ) == .bottomTrailing
  )
}

@MainActor
@Test func guidedMixerTourAdvancesAndCompletesWithoutMutatingAudio() {
  let coordinator = GuidedMixerTourCoordinator()
  coordinator.start(appID: "com.example.player")

  #expect(coordinator.state == .active(moment: .chooseSound, appID: "com.example.player"))
  #expect(coordinator.advance() == .advanced(.setLevel))
  #expect(coordinator.advance() == .advanced(.muteAndRestore))
  #expect(coordinator.advance() == .advanced(.goFurther))
  #expect(coordinator.advance() == .completed)
  #expect(coordinator.state == .inactive)
}

@MainActor
@Test func endTourIsImmediateAndIdempotentFromEveryMoment() {
  for moment in GuidedMixerTourMoment.allCases {
    let coordinator = GuidedMixerTourCoordinator()
    coordinator.start(appID: "com.example.player", at: moment)

    #expect(coordinator.end(reason: .escape))
    #expect(!coordinator.end(reason: .button))
    #expect(coordinator.state == .inactive)
  }
}

@MainActor
@Test func tourRestartReplacesPriorStateWithoutRetainedWork() {
  let coordinator = GuidedMixerTourCoordinator()
  coordinator.start(appID: "first")
  _ = coordinator.advance()
  coordinator.start(appID: "second")

  #expect(coordinator.state == .active(moment: .chooseSound, appID: "second"))
  #expect(coordinator.lifecycleSnapshot.isIdle)
}

@MainActor
@Test func onlyAcceptedTargetChangesAdvanceInteractiveMoments() {
  let coordinator = GuidedMixerTourCoordinator()
  coordinator.start(
    appID: "player",
    originalVolume: 0.7,
    originalMuted: false,
    at: .setLevel
  )

  coordinator.observe(.acceptedIntent(appID: "other", desiredVolume: 0.4, isMuted: false))
  #expect(coordinator.state == .active(moment: .setLevel, appID: "player"))

  coordinator.observe(.acceptedIntent(appID: "player", desiredVolume: 0.4, isMuted: false))
  #expect(coordinator.state == .active(moment: .muteAndRestore, appID: "player"))

  coordinator.observe(.acceptedIntent(appID: "player", desiredVolume: 0.4, isMuted: true))
  #expect(coordinator.state == .active(moment: .muteAndRestore, appID: "player"))

  coordinator.observe(.acceptedIntent(appID: "player", desiredVolume: 0.4, isMuted: false))
  #expect(coordinator.state == .active(moment: .goFurther, appID: "player"))
}
