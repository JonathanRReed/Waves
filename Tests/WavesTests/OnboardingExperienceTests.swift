import Foundation
import Testing

@testable import Waves

@Test func raw144PreferencesMigrateWithoutReplayingRequiredSetup() throws {
  let sourceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/Waves-1.4.4", isDirectory: true)
  let data = try Data(contentsOf: sourceDirectory.appendingPathComponent("preferences.json"))
  let decoded = try PersistedSchema.decode(
    UserPreferences.self,
    from: data,
    using: JSONDecoder()
  )

  #expect(decoded.requiredSetupVersion == OnboardingExperience.currentVersion)
  #expect(decoded.guidedTourCompletedVersion == 0)
  #expect(decoded.guidedTourDismissedVersion == 0)
  #expect(decoded.whatsNewDismissedVersion == 0)
  #expect(decoded.deferredTourVersion == 0)
}

@Test func newInstallStartsAtWelcomeWithoutOptionalPrompts() {
  let preferences = UserPreferences()
  let decision = OnboardingLaunchPolicy.decide(
    OnboardingLaunchContext(
      preferences: preferences,
      installLocation: .applications
    )
  )

  #expect(decision == .requiredSetup(.welcome))
}

@Test func requiredSetupVersionNeverBypassesMissingPrivacyConsent() {
  var preferences = UserPreferences()
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion
  preferences.hasCompletedGuidedSetup = true

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications
      )
    ) == .requiredSetup(.welcome)
  )
}

@Test func requiredSetupVersionNeverBypassesIncompleteGuidedSetup() {
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications
      )
    ) == .requiredSetup(.readiness)
  )
}

@Test func legacyIncompleteInstallResumesReadinessAfterAcceptedPrivacy() throws {
  let data = Data(
    """
    {
      "hasCompletedPrivacySetup": true,
      "hasCompletedGuidedSetup": false
    }
    """.utf8
  )
  let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

  #expect(preferences.requiredSetupVersion == 0)
  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications
      )
    ) == .requiredSetup(.readiness)
  )
}

@Test func upgradedCompleteInstallOpensMixerWithOneWhatsNewOffer() throws {
  let data = Data(
    """
    {
      "hasCompletedPrivacySetup": true,
      "hasCompletedGuidedSetup": true
    }
    """.utf8
  )
  let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications
      )
    ) == .mixer(showWhatsNew: true, showTourTip: false)
  )
}

@Test func dismissedTourNeverStartsAutomatically() {
  var preferences = completedPreferences()
  preferences.guidedTourDismissedVersion = OnboardingExperience.currentVersion
  preferences.whatsNewDismissedVersion = OnboardingExperience.currentVersion
  preferences.deferredTourVersion = OnboardingExperience.currentVersion

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications,
        hasEligibleTourApp: true
      )
    ) == .mixer(showWhatsNew: false, showTourTip: false)
  )
}

@Test func deferredTourOffersOneTipWhenAnEligibleAppAppears() {
  var preferences = completedPreferences()
  preferences.whatsNewDismissedVersion = OnboardingExperience.currentVersion
  preferences.deferredTourVersion = OnboardingExperience.currentVersion

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications,
        hasEligibleTourApp: true
      )
    ) == .mixer(showWhatsNew: false, showTourTip: true)
  )
}

@Test func manualSetupReplayRemainsSeparate() {
  let preferences = completedPreferences()

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .applications,
        requestedSetupReplay: true
      )
    ) == .requiredSetup(.welcome)
  )
}

@Test func mountedDiskImageAdvisoryPrecedesSetupUntilAcknowledged() {
  let preferences = UserPreferences()

  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .mountedDiskImage
      )
    ) == .installationAdvisory(.mountedDiskImage)
  )
  #expect(
    OnboardingLaunchPolicy.decide(
      OnboardingLaunchContext(
        preferences: preferences,
        installLocation: .mountedDiskImage,
        installationAdvisoryAcknowledged: true
      )
    ) == .requiredSetup(.welcome)
  )
}

@Test func onboardingExperienceVersionsRoundTripAdditively() throws {
  var preferences = UserPreferences()
  preferences.requiredSetupVersion = 1
  preferences.guidedTourCompletedVersion = 1
  preferences.guidedTourDismissedVersion = 1
  preferences.whatsNewDismissedVersion = 1
  preferences.deferredTourVersion = 1

  let encoded = try JSONEncoder().encode(preferences)
  let decoded = try JSONDecoder().decode(UserPreferences.self, from: encoded)

  #expect(decoded.requiredSetupVersion == 1)
  #expect(decoded.guidedTourCompletedVersion == 1)
  #expect(decoded.guidedTourDismissedVersion == 1)
  #expect(decoded.whatsNewDismissedVersion == 1)
  #expect(decoded.deferredTourVersion == 1)
}

private func completedPreferences() -> UserPreferences {
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion
  return preferences
}
