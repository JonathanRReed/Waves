struct OnboardingLaunchContext: Sendable {
  let preferences: UserPreferences
  let installLocation: InstallLocationClassification
  let installationAdvisoryAcknowledged: Bool
  let requestedSetupReplay: Bool
  let hasEligibleTourApp: Bool

  init(
    preferences: UserPreferences,
    installLocation: InstallLocationClassification,
    installationAdvisoryAcknowledged: Bool = false,
    requestedSetupReplay: Bool = false,
    hasEligibleTourApp: Bool = false
  ) {
    self.preferences = preferences
    self.installLocation = installLocation
    self.installationAdvisoryAcknowledged = installationAdvisoryAcknowledged
    self.requestedSetupReplay = requestedSetupReplay
    self.hasEligibleTourApp = hasEligibleTourApp
  }
}

enum OnboardingLaunchDecision: Equatable, Sendable {
  case installationAdvisory(InstallLocationClassification)
  case requiredSetup(GuidedSetupPhase)
  case mixer(showWhatsNew: Bool, showTourTip: Bool)
}

enum OnboardingLaunchPolicy {
  static func decide(_ context: OnboardingLaunchContext) -> OnboardingLaunchDecision {
    let preferences = context.preferences
    let version = OnboardingExperience.currentVersion

    if context.installLocation.needsAdvisory,
      !context.installationAdvisoryAcknowledged
    {
      return .installationAdvisory(context.installLocation)
    }

    if context.requestedSetupReplay {
      return .requiredSetup(.welcome)
    }

    guard preferences.hasCompletedPrivacySetup,
      preferences.hasCompletedGuidedSetup,
      preferences.requiredSetupVersion >= version
    else {
      return .requiredSetup(
        preferences.hasCompletedPrivacySetup ? .readiness : .welcome
      )
    }

    let tourWasCompleted = preferences.guidedTourCompletedVersion >= version
    let tourWasDismissed = preferences.guidedTourDismissedVersion >= version
    let showTourTip =
      preferences.deferredTourVersion == version
      && context.hasEligibleTourApp
      && !tourWasCompleted
      && !tourWasDismissed

    return .mixer(
      showWhatsNew: preferences.whatsNewDismissedVersion < version,
      showTourTip: showTourTip
    )
  }
}
