import Testing
import WavesAudioCore

@testable import Waves

@Test func presentationCoordinatorRepeatsTokensAndConsumesTheLatestSourceOnce() {
  var coordinator = AppStorePresentationCoordinator()

  coordinator.focusSource(.running)
  coordinator.focusSource(.recent)

  #expect(coordinator.sourceFocusToken == 2)
  #expect(coordinator.sourceFocusRequest == .recent)
  #expect(coordinator.consumeSourceFocusRequest() == .recent)
  #expect(coordinator.consumeSourceFocusRequest() == nil)
}

@Test func presentationCoordinatorKeepsIndependentEqualizerSettingsAndShortcutRequests() {
  var coordinator = AppStorePresentationCoordinator()

  coordinator.focusEqualizer(appID: "player", source: .frontmost)
  coordinator.requestSettingsPane(.diagnostics)
  coordinator.requestMuteShortcut(appID: "player")

  #expect(coordinator.equalizerFocusToken == 1)
  #expect(
    coordinator.consumeEqualizerFocusRequest()
      == EqualizerFocusRequest(appID: "player", source: .frontmost)
  )
  #expect(coordinator.settingsPaneToken == 1)
  #expect(coordinator.consumeSettingsPaneRequest() == .diagnostics)
  #expect(coordinator.muteShortcutToken == 1)
  #expect(coordinator.consumeMuteShortcutRequest() == "player")

  #expect(coordinator.consumeEqualizerFocusRequest() == nil)
  #expect(coordinator.consumeSettingsPaneRequest() == nil)
  #expect(coordinator.consumeMuteShortcutRequest() == nil)
}

@Test func presentationCoordinatorTracksTransientOnboardingFlagsAndProfileFocus() {
  var coordinator = AppStorePresentationCoordinator()

  coordinator.acknowledgeInstallationAdvisory()
  coordinator.requestSetupReplay()
  coordinator.requestWhatsNew()
  coordinator.signalProfileFocus()
  coordinator.signalProfileFocus()

  #expect(coordinator.installationAdvisoryAcknowledged)
  #expect(coordinator.requestedSetupReplay)
  #expect(coordinator.requestedWhatsNew)
  #expect(coordinator.profileFocusToken == 2)

  coordinator.cancelSetupReplay()
  coordinator.clearWhatsNew()

  #expect(!coordinator.requestedSetupReplay)
  #expect(!coordinator.requestedWhatsNew)
}

@MainActor
@Test func appStorePresentationForwardingPreservesTheExistingPublicContract() async {
  let store = await makeControlStoreFixture()
  let app = try #require(store.session.apps.first)

  store.focusSource(.recent)
  store.focusEqualizer(for: app, source: .running)
  store.requestSettingsPane(.help)
  store.requestMuteShortcutAssignment(for: app)
  store.runRequiredSetupReplay()
  store.showWhatsNew()

  #expect(store.sourceFocusToken == 1)
  #expect(store.consumeSourceFocusRequest() == .recent)
  #expect(store.equalizerFocusToken == 1)
  #expect(
    store.consumeEqualizerFocusRequest()
      == EqualizerFocusRequest(appID: app.logicalID, source: .running)
  )
  #expect(store.settingsPaneToken == 1)
  #expect(store.consumeSettingsPaneRequest() == .help)
  #expect(store.muteShortcutToken == 1)
  #expect(store.consumeMuteShortcutRequest() == app.logicalID)
  #expect(store.requestedSetupReplay)
  #expect(store.requestedWhatsNew)

  store.cancelRequiredSetupReplay()
  store.dismissWhatsNew()

  #expect(!store.requestedSetupReplay)
  #expect(!store.requestedWhatsNew)
}
