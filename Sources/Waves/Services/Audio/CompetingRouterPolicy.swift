import WavesAudioCore

enum CompetingRouterPolicy {
  static func mixedOutputExclusion(for app: AudioApp) -> String? {
    guard AppDiscoveryPolicy.competingAudioRouterName(for: app.bundleID, among: []) != nil else {
      return nil
    }
    return "Elgato Wave Link's mixed output can carry every monitored app. "
      + "Waves leaves this router untouched so one nested route cannot duplicate or silence the whole mix. "
      + "Control the upstream apps inside Elgato Wave Link."
  }

  static func upstreamOwnershipDetail(for app: AudioApp, conflict: VerifiedRouterConflict?) -> String? {
    return conflict?.detail
  }

  static func conflictDetail(for app: AudioApp, conflict: VerifiedRouterConflict?) -> String? {
    mixedOutputExclusion(for: app) ?? upstreamOwnershipDetail(for: app, conflict: conflict)
  }
}
