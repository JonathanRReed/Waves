import Testing
import WavesAudioCore

@testable import Waves

@Test func menuBarRowAccessibilityNamesTheAppAndReportsVolume() {
  let app = AudioApp(
    id: "keyboard.runtime",
    logicalID: "keyboard",
    pid: 42,
    bundleID: "test.keyboard",
    displayName: "Keyboard Player",
    category: .media,
    desiredVolume: 0.62,
    appliedVolume: 0.62,
    routingState: .managed,
    compatibility: .supported
  )

  #expect(MenuBarRowAccessibility.moreActionsLabel(for: app) == "More actions for Keyboard Player")
  #expect(MenuBarRowAccessibility.volumeValue(for: app) == "62%")
}
