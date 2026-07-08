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

@Test func logicalAppIDKeepsNonASCIINamedAppsDistinct() {
  // Names with no ASCII alphanumerics (e.g. CJK-only) normalize to empty and
  // must NOT collapse onto a shared id, or persisted volume/mute for one app
  // would be restored onto the other. Only a truly empty name is "unknown-app".
  let first = AppDiscoveryPolicy.logicalAppID(bundleID: nil, displayName: "音楽プレーヤー")
  let second = AppDiscoveryPolicy.logicalAppID(bundleID: nil, displayName: "视频播放器")
  #expect(first != second)
  #expect(first.hasPrefix("unnamed-"))
  #expect(first == AppDiscoveryPolicy.logicalAppID(bundleID: nil, displayName: "音楽プレーヤー"))
  #expect(AppDiscoveryPolicy.logicalAppID(bundleID: nil, displayName: "  ") == "unknown-app")
}

@Test func inferCategoryClassifiesQuickTimeAsMediaNotSystem() {
  // Regression: QuickTime Player must hit the media clause before the
  // com.apple. system fallback, or the default "hide system processes" filter
  // hides it while it is actively playing.
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.apple.quicktimeplayerx", displayName: "QuickTime Player") == .media)
}

@Test func logicalAppIDIsStableAcrossCalls() {
  let first = AppDiscoveryPolicy.logicalAppID(bundleID: "com.foo.Bar", displayName: "Bar")
  let second = AppDiscoveryPolicy.logicalAppID(bundleID: "com.foo.Bar", displayName: "Bar")
  #expect(first == second)
}

// MARK: - Category inference

@Test func inferCategoryClassifiesKnownApps() {
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.apple.Safari", displayName: "Safari") == .browser)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "net.imput.helium", displayName: "Helium") == .browser)
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

@Test func inferCategoryAvoidsShortTokenFalsePositives() {
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.example.meetingnotes", displayName: "Meeting Notes") != .conferencing)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.example.musicality", displayName: "Musicality") != .media)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.example.tvremote", displayName: "TVRemote") != .media)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.example.knowledgebase", displayName: "Knowledge Base") != .browser)
}

@Test func inferCategoryKeepsConcatenatedProductNames() {
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.example.GoogleMeet", displayName: "GoogleMeet") == .conferencing)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: nil, displayName: "MeetInOne") == .conferencing)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: "com.example.YouTubeMusic", displayName: "YouTubeMusic") == .media)
  #expect(AppDiscoveryPolicy.inferCategory(bundleID: nil, displayName: "AppleTV") == .media)
}

@Test func isManageableAppRejectsHelperProcesses() {
  #expect(AppDiscoveryPolicy.isManageableApp(named: "Spotify", bundleID: "com.spotify.client"))
  #expect(!AppDiscoveryPolicy.isManageableApp(named: "Google Chrome Helper (Renderer)", bundleID: "com.google.Chrome.helper.renderer"))
}

@Test func missingAudioProcessIsRetryableForHeliumAndUserFacingApps() {
  #expect(
    !AppDiscoveryPolicy.treatsMissingAudioProcessAsPermanent(
      bundleID: "net.imput.helium",
      displayName: "Helium",
      category: .browser
    )
  )
  #expect(
    !AppDiscoveryPolicy.treatsMissingAudioProcessAsPermanent(
      bundleID: "com.example.CustomPlayer",
      displayName: "Custom Player",
      category: .unknown
    )
  )
}

@Test func missingAudioProcessCanBePermanentForSystemRows() {
  #expect(
    AppDiscoveryPolicy.treatsMissingAudioProcessAsPermanent(
      bundleID: "com.apple.finder",
      displayName: "Finder",
      category: .system
    )
  )
}

// MARK: - Helper-process audio attribution (Chromium / Electron)

@Test func topLevelAppBundlePathResolvesChromiumHelperToParentApp() {
  // A Chromium "Audio Service" helper executable lives inside the parent .app;
  // attribution must resolve back to "Google Chrome.app", not the nested helper.
  let path =
    "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/"
    + "Versions/120.0.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
  #expect(AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: path) == "/Applications/Google Chrome.app")
}

@Test func topLevelAppBundlePathResolvesElectronHelperToParentApp() {
  let path =
    "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
  #expect(AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: path) == "/Applications/Slack.app")
}

@Test func topLevelAppBundlePathReturnsSelfForOrdinaryApp() {
  let path = "/Applications/Spotify.app/Contents/MacOS/Spotify"
  #expect(AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: path) == "/Applications/Spotify.app")
}

@Test func topLevelAppBundlePathReturnsNilForNonBundledExecutable() {
  #expect(AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: "/usr/bin/some-daemon") == nil)
  #expect(AppDiscoveryPolicy.topLevelAppBundlePath(forExecutablePath: "") == nil)
}

@Test func bundleFamilyMatchesChromiumHelperToParent() {
  // The attribution path resolves a helper to the parent .app, whose bundle id
  // must family-match the discovered app so the audio is credited to it.
  #expect(AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: "com.google.Chrome", candidateBundleID: "com.google.Chrome"))
  #expect(AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: "com.google.Chrome", candidateBundleID: "com.google.Chrome.helper"))
  #expect(!AppDiscoveryPolicy.bundleFamilyMatches(appBundleID: "com.google.Chrome", candidateBundleID: "com.apple.Safari"))
}

// MARK: - Mute provenance

@Test func audioAppMuteSourceDefaultsToUserForLegacyDecode() throws {
  // A session file written before muteSource existed must decode as user-muted.
  let legacy = Data(#"{"id":"x","displayName":"X","isMuted":true}"#.utf8)
  let app = try JSONDecoder().decode(AudioApp.self, from: legacy)
  #expect(app.muteSource == .user)
}

@Test func audioAppMuteSourceRoundTrips() throws {
  let app = AudioApp(id: "x", displayName: "X", category: .media, isMuted: true, muteSource: .autoConferencing)
  let decoded = try JSONDecoder().decode(AudioApp.self, from: JSONEncoder().encode(app))
  #expect(decoded.muteSource == .autoConferencing)
}

@Test func emptySnapshotHasNoAppsOrFabricatedState() {
  let snapshot = AudioSessionSnapshot.empty
  #expect(snapshot.apps.isEmpty)
  #expect(snapshot.currentDevice == nil)
  #expect(snapshot.backendStatus.lastError == nil)
  #expect(snapshot.backendStatus.isRouteRecoveryHealthy == false)
}
