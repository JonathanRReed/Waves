import Foundation
import Testing

@testable import WavesAudioCore

@Test func supportMatrixCoverageSummaryCountsSupportedApps() {
  let matrix = SupportMatrix(
    entries: [
      SupportMatrixEntry(
        appID: "safari",
        displayName: "Safari",
        category: .browser,
        state: .supported
      ),
      SupportMatrixEntry(
        appID: "zoom",
        displayName: "Zoom",
        category: .conferencing,
        state: .supported
      ),
      SupportMatrixEntry(
        appID: "discord",
        displayName: "Discord",
        category: .communication,
        state: .validating
      ),
    ]
  )

  #expect(matrix.coverageSummary == "2/3 validated")
}

@Test func profileDefaultsContainDailyUseGroups() {
  let profiles = Profile.defaults

  #expect(profiles.count >= 2)
  #expect(profiles.contains(where: { $0.name == "Work" }))
  #expect(profiles.contains(where: { $0.name == "Gaming" }))
  #expect(profiles.contains(where: { $0.name == "Focus" }))

  // "Work" and "Gaming" are pure groupings (membership-only); "Focus" carries a mix.
  let work = profiles.first { $0.name == "Work" }
  #expect(work?.carriesLevels == false)
  let focus = profiles.first { $0.name == "Focus" }
  #expect(focus?.carriesLevels == true)
}

@Test func profileDecodingRejectsOversizedStructure() throws {
  let longName = String(repeating: "n", count: Profile.maxNameLength + 1)
  let longNameData = try JSONSerialization.data(withJSONObject: [
    "id": UUID().uuidString,
    "name": longName,
    "entries": [],
    "createdAt": 0,
    "updatedAt": 0,
  ])
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(Profile.self, from: longNameData)
  }

  let entries = (0...Profile.maxEntries).map { ["appID": "app.\($0)"] }
  let tooManyEntriesData = try JSONSerialization.data(withJSONObject: [
    "id": UUID().uuidString,
    "name": "Too many entries",
    "entries": entries,
    "createdAt": 0,
    "updatedAt": 0,
  ])
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(Profile.self, from: tooManyEntriesData)
  }
}

@Test func backendStatusDecodeUsesTheBoundedInitializer() throws {
  let data = try JSONSerialization.data(withJSONObject: [
    "isAudioComponentInstalled": true,
    "hasRequiredPermissions": true,
    "isRouteRecoveryHealthy": true,
    "lastError": String(repeating: "x", count: BackendStatus.maxErrorLength + 500),
  ])

  let decoded = try JSONDecoder().decode(BackendStatus.self, from: data)

  #expect(decoded.lastError?.count == BackendStatus.maxErrorLength)
}

@Test func previewSnapshotIncludesCurrentDeviceAndApps() {
  let snapshot = AudioSessionSnapshot.preview

  #expect(snapshot.currentDevice?.name == "MacBook Pro Speakers")
  #expect(snapshot.apps.count == 4)
  #expect(snapshot.apps.contains(where: { $0.routingState == .managed }))
}

@Test func previewBackendAcceptsLogicalIDsForRuntimeAppRows() async throws {
  let app = AudioApp(
    id: "net.imput.helium#63499",
    logicalID: "net.imput.helium",
    pid: 63499,
    bundleID: "net.imput.helium",
    displayName: "Helium",
    category: .browser
  )
  let backend = PreviewAudioControlBackend(
    snapshot: AudioSessionSnapshot(
      apps: [app],
      currentDevice: nil,
      recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: true,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true
      ),
      updatedAt: .now
    )
  )

  try await backend.setDesiredVolume(0.5, forAppID: "net.imput.helium")

  let updatedApp = await backend.currentSnapshot().apps[0]
  #expect(updatedApp.desiredVolume == 0.5)
}

@Test func previewBackendAppliesEqualizerAndReportsAdaptiveAnalysis() async throws {
  let backend = PreviewAudioControlBackend()
  let initialSnapshot = await backend.currentSnapshot()
  let app = try #require(initialSnapshot.apps.first { $0.compatibility == .supported })
  var equalizer = EqualizerSettings(isEnabled: true)
  equalizer.applyPreset(.voiceFocus)

  try await backend.setEqualizer(equalizer, forAppID: app.logicalID)
  let updatedSnapshot = await backend.currentSnapshot()
  let updatedApp = try #require(
    updatedSnapshot.apps.first { $0.logicalID == app.logicalID || $0.id == app.logicalID }
  )
  let analysis = await backend.adaptiveAnalysis()

  #expect(updatedApp.routingState == .managed)
  #expect(updatedApp.appliedVolume == updatedApp.desiredVolume)
  #expect(analysis[app.logicalID] != nil)
}

@Test func appDiscoveryMatchesPrefixHelperFamilies() {
  #expect(
    AppDiscoveryPolicy.bundleFamilyMatches(
      appBundleID: "net.imput.helium",
      candidateBundleID: "net.imput.helium.helper.renderer"
    )
  )
}

@Test func appDiscoveryMatchesZenSiblingPluginContainer() {
  #expect(
    AppDiscoveryPolicy.bundleFamilyMatches(
      appBundleID: "app.zen-browser.zen",
      candidateBundleID: "app.zen-browser.plugincontainer"
    )
  )
}

@Test func appDiscoveryDoesNotCollapseUnrelatedAppleApps() {
  #expect(
    !AppDiscoveryPolicy.bundleFamilyMatches(
      appBundleID: "com.apple.Music",
      candidateBundleID: "com.apple.Safari"
    )
  )
}

@Test func appDiscoveryFiltersHelperRowsFromVisibleMixer() {
  #expect(
    !AppDiscoveryPolicy.isManageableApp(
      named: "Zen Plugin Container",
      bundleID: "app.zen-browser.plugincontainer"
    )
  )
  #expect(
    AppDiscoveryPolicy.isManageableApp(
      named: "Zen",
      bundleID: "app.zen-browser.zen"
    )
  )
}

@Test func volumeBoostPersistsAcrossSessions() async throws {
  let app = AudioApp(
    id: "test.app",
    displayName: "Test App",
    category: .media,
    volumeBoost: 2.0
  )

  let backend = PreviewAudioControlBackend(
    snapshot: AudioSessionSnapshot(
      apps: [app],
      currentDevice: nil,
      recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: true,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true
      ),
      updatedAt: .now
    )
  )

  try await backend.setVolumeBoost(3.0, forAppID: "test.app")
  let updatedApp = await backend.currentSnapshot().apps[0]
  #expect(updatedApp.volumeBoost == 3.0)
}

@Test func applyProfileLeavesMembershipOnlyAppsUntouched() async throws {
  let app = AudioApp(
    id: "test.app", logicalID: "test.app", displayName: "Test App",
    category: .media, desiredVolume: 0.4, isMuted: false, volumeBoost: 2.0
  )
  let backend = PreviewAudioControlBackend(
    snapshot: AudioSessionSnapshot(
      apps: [app], currentDevice: nil, recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(isAudioComponentInstalled: true, hasRequiredPermissions: true, isRouteRecoveryHealthy: true)
    )
  )

  // A membership-only entry must not change the app's audio at all.
  let group = Profile(name: "Group", entries: [ProfileEntry(appID: "test.app")])
  _ = try await backend.applyProfile(group)
  let after = await backend.currentSnapshot().apps[0]
  #expect(after.desiredVolume == 0.4)
  #expect(after.isMuted == false)
  #expect(after.volumeBoost == 2.0)
}

@Test func applyProfilePartialEntryOnlyChangesSetFields() async throws {
  let app = AudioApp(
    id: "test.app", logicalID: "test.app", displayName: "Test App",
    category: .media, desiredVolume: 0.4, isMuted: false, volumeBoost: 2.0
  )
  let backend = PreviewAudioControlBackend(
    snapshot: AudioSessionSnapshot(
      apps: [app], currentDevice: nil, recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(isAudioComponentInstalled: true, hasRequiredPermissions: true, isRouteRecoveryHealthy: true)
    )
  )

  // A mute-only entry must mute without disturbing volume or boost.
  let muteOnly = Profile(name: "Mute", entries: [ProfileEntry(appID: "test.app", isMuted: true)])
  _ = try await backend.applyProfile(muteOnly)
  let after = await backend.currentSnapshot().apps[0]
  #expect(after.isMuted == true)
  #expect(after.desiredVolume == 0.4)
  #expect(after.volumeBoost == 2.0)
}

@Test func profileSavesAndAppliesVolumeBoost() async throws {
  let app = AudioApp(
    id: "test.app",
    logicalID: "test.app",
    displayName: "Test App",
    category: .media,
    desiredVolume: 0.4,
    isMuted: false,
    volumeBoost: 3.0
  )

  let backend = PreviewAudioControlBackend(
    snapshot: AudioSessionSnapshot(
      apps: [app],
      currentDevice: nil,
      recentDeviceIDs: [],
      supportMatrix: SupportMatrix(entries: []),
      backendStatus: BackendStatus(
        isAudioComponentInstalled: true,
        hasRequiredPermissions: true,
        isRouteRecoveryHealthy: true
      ),
      updatedAt: .now
    )
  )

  let saved = try await backend.saveCurrentProfile(named: "Boosted")
  #expect(saved.entries[0].volumeBoost == 3.0)

  try await backend.setVolumeBoost(1.0, forAppID: "test.app")
  _ = try await backend.applyProfile(saved)

  let restoredApp = await backend.currentSnapshot().apps[0]
  #expect(restoredApp.volumeBoost == 3.0)
}

@Test func audioAppEncodesAndDecodesCorrectly() throws {
  let app = AudioApp(
    id: "test.app",
    logicalID: "test.app",
    pid: 1234,
    bundleID: "com.test.app",
    displayName: "Test App",
    iconName: "app.fill",
    iconTIFFData: nil,
    category: .media,
    isActive: true,
    peakLevel: 0.5,
    rmsLevel: 0.3,
    desiredVolume: 0.75,
    appliedVolume: 0.75,
    isMuted: false,
    isPinned: true,
    routingState: .managed,
    compatibility: .supported,
    notes: "Test notes",
    volumeBoost: 2.0
  )

  let encoder = JSONEncoder()
  let data = try encoder.encode(app)
  let decoder = JSONDecoder()
  let decoded = try decoder.decode(AudioApp.self, from: data)

  #expect(decoded.id == app.id)
  #expect(decoded.displayName == app.displayName)
  #expect(decoded.desiredVolume == 0.75)
  #expect(decoded.volumeBoost == 2.0)
  #expect(decoded.isPinned == true)
  #expect(decoded.routingState == .managed)
}

@Test func audioSessionSnapshotEncodesAndDecodesCorrectly() throws {
  let snapshot = AudioSessionSnapshot(
    apps: [
      AudioApp(
        id: "app1",
        displayName: "App 1",
        category: .media,
        volumeBoost: 1.0
      ),
      AudioApp(
        id: "app2",
        displayName: "App 2",
        category: .browser,
        volumeBoost: 2.0
      )
    ],
    currentDevice: AudioDevice(
      id: "device1",
      name: "Test Device",
      kind: .builtInOutput
    ),
    recentDeviceIDs: ["device1", "device2"],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    ),
    updatedAt: .now
  )

  let encoder = JSONEncoder()
  let data = try encoder.encode(snapshot)
  let decoder = JSONDecoder()
  let decoded = try decoder.decode(AudioSessionSnapshot.self, from: data)

  #expect(decoded.apps.count == 2)
  #expect(decoded.currentDevice?.name == "Test Device")
  #expect(decoded.recentDeviceIDs.count == 2)
  #expect(decoded.backendStatus.isAudioComponentInstalled == true)
}

@Test func profileEncodesAndDecodesCorrectly() throws {
  let profile = Profile(
    id: UUID(),
    name: "Test Profile",
    entries: [
      ProfileEntry(appID: "app1", desiredVolume: 0.5, isMuted: false),
      ProfileEntry(appID: "app2", desiredVolume: 0.75, isMuted: true, volumeBoost: 2.0)
    ],
    createdAt: .now,
    updatedAt: .now
  )

  let encoder = JSONEncoder()
  let data = try encoder.encode(profile)
  let decoder = JSONDecoder()
  let decoded = try decoder.decode(Profile.self, from: data)

  #expect(decoded.name == "Test Profile")
  #expect(decoded.entries.count == 2)
  #expect(decoded.entries[0].desiredVolume == 0.5)
  #expect(decoded.entries[1].isMuted == true)
  #expect(decoded.entries[1].volumeBoost == 2.0)
}

@Test func profileEntryDecodesLegacyEntryAndClampsImportedValues() throws {
  // A legacy preset entry carried concrete levels: it must decode into a
  // level-bearing profile entry (clamped), not a membership-only one.
  let legacyJSON = #"{"appID":"legacy.app","desiredVolume":1.5,"isMuted":false}"#.data(using: .utf8)!
  let legacyEntry = try JSONDecoder().decode(ProfileEntry.self, from: legacyJSON)

  #expect(legacyEntry.appID == "legacy.app")
  #expect(legacyEntry.hasLevels)
  #expect(legacyEntry.desiredVolume == 1.0)
  #expect(legacyEntry.isMuted == false)
  // Boost was absent in the legacy entry, so it stays unset (membership for boost).
  #expect(legacyEntry.volumeBoost == nil)

  let boostedJSON = #"{"appID":"boosted.app","desiredVolume":0.5,"isMuted":true,"volumeBoost":12}"#.data(using: .utf8)!
  let boostedEntry = try JSONDecoder().decode(ProfileEntry.self, from: boostedJSON)
  #expect(boostedEntry.volumeBoost == 4.0)
}

@Test func profileEntryMembershipOnlyHasNoLevels() throws {
  let entry = ProfileEntry(appID: "group.member")
  #expect(!entry.hasLevels)

  // Round-trips without fabricating level keys.
  let data = try JSONEncoder().encode(entry)
  let json = String(decoding: data, as: UTF8.self)
  #expect(!json.contains("desiredVolume"))
  let decoded = try JSONDecoder().decode(ProfileEntry.self, from: data)
  #expect(!decoded.hasLevels)
}

@Test func routingStateHasAllExpectedCases() {
  #expect(RoutingState.allCases.count == 5)
  #expect(RoutingState.allCases.contains(.live))
  #expect(RoutingState.allCases.contains(.recent))
  #expect(RoutingState.allCases.contains(.managed))
  #expect(RoutingState.allCases.contains(.monitorOnly))
  #expect(RoutingState.allCases.contains(.error))
}

@Test func appCategoryHasAllExpectedCases() {
  #expect(AppCategory.allCases.count == 6)
  #expect(AppCategory.allCases.contains(.browser))
  #expect(AppCategory.allCases.contains(.conferencing))
  #expect(AppCategory.allCases.contains(.media))
  #expect(AppCategory.allCases.contains(.communication))
  #expect(AppCategory.allCases.contains(.system))
  #expect(AppCategory.allCases.contains(.unknown))
}

@Test func compatibilityStateHasAllExpectedCases() {
  #expect(CompatibilityState.allCases.count == 4)
  #expect(CompatibilityState.allCases.contains(.supported))
  #expect(CompatibilityState.allCases.contains(.validating))
  #expect(CompatibilityState.allCases.contains(.planned))
  #expect(CompatibilityState.allCases.contains(.unsupported))
}

@Test func deviceKindHasAllExpectedCases() {
  #expect(DeviceKind.allCases.count == 6)
  #expect(DeviceKind.allCases.contains(.builtInOutput))
  #expect(DeviceKind.allCases.contains(.bluetooth))
  #expect(DeviceKind.allCases.contains(.display))
  #expect(DeviceKind.allCases.contains(.virtual))
  #expect(DeviceKind.allCases.contains(.aggregate))
  #expect(DeviceKind.allCases.contains(.unknown))
}
