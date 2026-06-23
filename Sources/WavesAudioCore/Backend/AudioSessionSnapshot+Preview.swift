import Foundation

extension AudioSessionSnapshot {
  public static var preview: AudioSessionSnapshot {
    AudioSessionSnapshot(
      apps: [
        AudioApp(
          id: "com.apple.Safari",
          logicalID: "com.apple.Safari",
          pid: 4101,
          bundleID: "com.apple.Safari",
          displayName: "Safari",
          iconName: "safari",
          category: .browser,
          isActive: true,
          peakLevel: 0.62,
          rmsLevel: 0.48,
          desiredVolume: 0.72,
          appliedVolume: 0.72,
          isMuted: false,
          isPinned: true,
          routingState: .managed,
          compatibility: .supported,
          notes: "Validated in browser category.",
          volumeBoost: 1.0
        ),
        AudioApp(
          id: "us.zoom.xos",
          logicalID: "us.zoom.xos",
          pid: 9032,
          bundleID: "us.zoom.xos",
          displayName: "Zoom",
          iconName: "video.bubble.left.fill",
          category: .conferencing,
          isActive: true,
          peakLevel: 0.87,
          rmsLevel: 0.75,
          desiredVolume: 1,
          appliedVolume: 1,
          isMuted: false,
          isPinned: true,
          routingState: .managed,
          compatibility: .supported,
          notes: "Call apps are highest priority in the support matrix.",
          volumeBoost: 1.0
        ),
        AudioApp(
          id: "com.spotify.client",
          logicalID: "com.spotify.client",
          pid: 3321,
          bundleID: "com.spotify.client",
          displayName: "Spotify",
          iconName: "music.note",
          category: .media,
          isActive: true,
          peakLevel: 0.53,
          rmsLevel: 0.41,
          desiredVolume: 0.35,
          appliedVolume: 0.35,
          isMuted: false,
          isPinned: false,
          routingState: .managed,
          compatibility: .supported,
          notes: "Managed route active.",
          volumeBoost: 1.0
        ),
        AudioApp(
          id: "com.hnc.Discord",
          logicalID: "com.hnc.Discord",
          pid: 7123,
          bundleID: "com.hnc.Discord",
          displayName: "Discord",
          iconName: "message.fill",
          category: .communication,
          isActive: false,
          peakLevel: 0.04,
          rmsLevel: 0.01,
          desiredVolume: 0.6,
          appliedVolume: nil,
          isMuted: false,
          isPinned: false,
          routingState: .monitorOnly,
          compatibility: .validating,
          notes: "Daily-use category included, route support still validating.",
          volumeBoost: 1.0
        ),
      ],
      currentDevice: AudioDevice(
        id: "built-in-output",
        name: "MacBook Pro Speakers",
        kind: .builtInOutput,
        isCurrent: true,
        isManagedRouteAvailable: true,
        volumeControlMode: .software
      ),
      recentDeviceIDs: ["built-in-output", "airpods-pro"],
      supportMatrix: SupportMatrix(
        entries: [
          SupportMatrixEntry(
            appID: "com.apple.Safari", displayName: "Safari", category: .browser, state: .supported),
          SupportMatrixEntry(
            appID: "us.zoom.xos", displayName: "Zoom", category: .conferencing, state: .supported),
          SupportMatrixEntry(
            appID: "com.spotify.client", displayName: "Spotify", category: .media, state: .supported
          ),
          SupportMatrixEntry(
            appID: "com.hnc.Discord", displayName: "Discord", category: .communication,
            state: .validating),
        ]
      ),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: false,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true,
        lastError: "Managed audio component has not been installed in this preview build."
      )
    )
  }
}

extension Profile {
  /// Starter profiles that show the two ends of the feature: "Work" and
  /// "Gaming" are app *groups* (membership-only — they don't fight the user's
  /// own levels), while "Focus" carries a concrete mix. Members are referenced
  /// by bundle ID; any that aren't installed are simply skipped when applied.
  public static var defaults: [Profile] {
    [
      Profile(
        name: "Work",
        entries: [
          ProfileEntry(appID: "com.tinyspeck.slackmacgap"),
          ProfileEntry(appID: "com.microsoft.teams2"),
          ProfileEntry(appID: "com.microsoft.teams"),
          ProfileEntry(appID: "us.zoom.xos"),
          ProfileEntry(appID: "com.apple.Safari"),
          ProfileEntry(appID: "com.google.Chrome"),
        ]
      ),
      Profile(
        name: "Gaming",
        entries: [
          ProfileEntry(appID: "com.hnc.Discord"),
          ProfileEntry(appID: "com.valvesoftware.steam"),
          ProfileEntry(appID: "com.spotify.client"),
        ]
      ),
      Profile(
        name: "Focus",
        entries: [
          ProfileEntry(appID: "com.apple.Safari", desiredVolume: 0.25, isMuted: true),
          ProfileEntry(appID: "us.zoom.xos", desiredVolume: 1, isMuted: false),
          ProfileEntry(appID: "com.spotify.client", desiredVolume: 0.2, isMuted: false),
          ProfileEntry(appID: "com.hnc.Discord", desiredVolume: 0.65, isMuted: false),
        ]
      ),
    ]
  }
}
