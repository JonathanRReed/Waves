import Foundation
import Testing

@testable import WavesAudioCore

// MARK: - Logical app identity

@Test func logicalAppIDPrefersBundleIDForOrdinaryApps() {
  let id = AppDiscoveryPolicy.logicalAppID(bundleID: "com.apple.Safari", displayName: "Safari")
  #expect(id == "com.apple.Safari")
}

@Test func logicalAppIDFallsBackToNameWhenBundleIDMissing() {
  let id = AppDiscoveryPolicy.logicalAppID(bundleID: nil, displayName: "Some App")
  #expect(id == "name-some-app")
}

@Test func logicalAppIDDistinguishesCompanionHelperProcesses() {
  // Helper/companion audio processes keep a per-process identity so they don't
  // collapse onto the parent app's logical id.
  let helper = AppDiscoveryPolicy.logicalAppID(
    bundleID: "com.google.Chrome.helper",
    displayName: "Google Chrome Helper",
    pid: 4242
  )
  #expect(helper.contains("pid-4242"))
  #expect(helper != "com.google.Chrome.helper")
}

@Test func logicalAppIDIsStableAcrossCalls() {
  let first = AppDiscoveryPolicy.logicalAppID(bundleID: "com.foo.Bar", displayName: "Bar")
  let second = AppDiscoveryPolicy.logicalAppID(bundleID: "com.foo.Bar", displayName: "Bar")
  #expect(first == second)
}

// MARK: - Category inference

@Test func inferCategoryClassifiesKnownApps() {
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.apple.Safari", displayName: "Safari") == .browser)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "us.zoom.xos", displayName: "zoom.us") == .conferencing)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.spotify.client", displayName: "Spotify") == .media)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.hnc.Discord", displayName: "Discord") == .communication)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.apple.finder", displayName: "Finder") == .system)
}

@Test func inferCategoryMatchesArcBrowserButNotArchiveUtility() {
  // Regression: the "arc" token must match the Arc browser as a whole word and
  // not misclassify "Archive Utility" or "Monarch" as a browser.
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "company.thebrowser.Browser", displayName: "Arc") == .browser)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.apple.archiveutility", displayName: "Archive Utility") != .browser)
}

@Test func isManageableAppRejectsHelperProcesses() {
  #expect(AppDiscoveryPolicy.isManageableApp(named: "Spotify", bundleID: "com.spotify.client"))
  #expect(!AppDiscoveryPolicy.isManageableApp(named: "Google Chrome Helper (Renderer)", bundleID: "com.google.Chrome.helper.renderer"))
}

// MARK: - Snapshot

@Test func emptySnapshotHasNoAppsOrFabricatedState() {
  let snapshot = AudioSessionSnapshot.empty
  #expect(snapshot.apps.isEmpty)
  #expect(snapshot.currentDevice == nil)
  #expect(snapshot.backendStatus.lastError == nil)
  #expect(snapshot.backendStatus.isRouteRecoveryHealthy == false)
}
