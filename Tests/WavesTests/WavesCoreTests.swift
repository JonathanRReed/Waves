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

@Test func presetDefaultsContainDailyUseProfiles() {
  let presets = Preset.defaults

  #expect(presets.count >= 2)
  #expect(presets.contains(where: { $0.name == "Focus" }))
  #expect(presets.contains(where: { $0.name == "Meeting" }))
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

@Test func presetEncodesAndDecodesCorrectly() throws {
  let preset = Preset(
    id: UUID(),
    name: "Test Preset",
    entries: [
      PresetEntry(appID: "app1", desiredVolume: 0.5, isMuted: false),
      PresetEntry(appID: "app2", desiredVolume: 0.75, isMuted: true)
    ],
    createdAt: .now,
    updatedAt: .now
  )

  let encoder = JSONEncoder()
  let data = try encoder.encode(preset)
  let decoder = JSONDecoder()
  let decoded = try decoder.decode(Preset.self, from: data)

  #expect(decoded.name == "Test Preset")
  #expect(decoded.entries.count == 2)
  #expect(decoded.entries[0].desiredVolume == 0.5)
  #expect(decoded.entries[1].isMuted == true)
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
