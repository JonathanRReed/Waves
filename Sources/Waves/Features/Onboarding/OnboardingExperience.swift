enum OnboardingExperience {
  static let currentVersion = 1
}

enum GuidedSetupPhase: Equatable, Sendable {
  case welcome
  case permissionPreflight
  case waitingForMacOS
  case readiness
  case ready
}

enum InstallLocationClassification: Equatable, Sendable {
  case applications
  case mountedDiskImage
  case readOnlyExternal
  case ordinaryWritable

  var needsAdvisory: Bool {
    switch self {
    case .mountedDiskImage, .readOnlyExternal:
      true
    case .applications, .ordinaryWritable:
      false
    }
  }

  var finderActionTitle: String {
    switch self {
    case .mountedDiskImage:
      "Open This Disk Image in Finder"
    case .readOnlyExternal, .applications, .ordinaryWritable:
      "Show Waves in Finder"
    }
  }
}
