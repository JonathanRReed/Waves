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

  static func conflict(
    for app: AudioApp,
    verifiedConflict: VerifiedRouterConflict?,
    controller: PerAppAudioController,
    compatibilityEnabled: Bool
  ) -> VerifiedRouterConflict? {
    guard compatibilityEnabled else { return nil }
    if let detail = mixedOutputExclusion(for: app) {
      return VerifiedRouterConflict(
        routerName: "Elgato Wave Link",
        kind: .routerMixedOutput,
        detail: detail
      )
    }
    guard let verifiedConflict else { return nil }
    return verifiedConflict
  }

  static func conflictDetail(
    for app: AudioApp,
    conflict: VerifiedRouterConflict?,
    controller: PerAppAudioController,
    compatibilityEnabled: Bool
  ) -> String? {
    self.conflict(
      for: app,
      verifiedConflict: conflict,
      controller: controller,
      compatibilityEnabled: compatibilityEnabled
    )?.detail
  }
}

enum CompetingRouterRouteDisposition: Equatable, Sendable {
  case none
  case monitorOnly
}

struct CompetingRouterConflictDecision: Equatable, Sendable {
  let routeDisposition: CompetingRouterRouteDisposition
  let detail: String

  static func make(routerName: String, isVerified: Bool) -> Self {
    guard isVerified else {
      return Self(routeDisposition: .none, detail: "")
    }
    return Self(
      routeDisposition: .monitorOnly,
      detail: "\(routerName) is routing this app's audio. Waves is monitoring only until that router releases the route."
    )
  }
}
