import Testing
import WavesAudioCore

@testable import Waves

@Test func menuBarLayoutUsesApprovedCompactMetrics() {
  #expect(MenuBarLayout.panelWidth == 372)
  #expect(MenuBarLayout.maximumVisibleApps == 7)
}

@Test func menuBarListOrdersDeduplicatesExcludesAndCapsGlobally() {
  let pinned = [
    menuBarApp("pinned-a", name: "Pinned A", pinned: true),
    menuBarApp("shared", name: "Shared", pinned: true),
  ]
  let live = [
    menuBarApp("shared", name: "Shared", state: .live),
    menuBarApp("live-a", name: "Live A", state: .live),
    menuBarApp("excluded", name: "Excluded", state: .live),
  ]
  let recent = (1...8).map {
    menuBarApp("recent-\($0)", name: "Recent \($0)", state: .recent)
  }

  let snapshot = MenuBarLayout.makeAppList(
    pinned: pinned,
    live: live,
    recent: recent,
    isExcluded: { $0.logicalID == "excluded" }
  )

  #expect(
    snapshot.items.map(\.app.logicalID) == [
      "pinned-a", "shared", "live-a", "recent-1", "recent-2", "recent-3", "recent-4",
    ])
  #expect(
    snapshot.items.map(\.group) == [
      .pinned, .pinned, .live, .recent, .recent, .recent, .recent,
    ])
  #expect(snapshot.hiddenCount == 4)
  #expect(snapshot.overflowFocus == .recent)
}

@Test func menuBarListOmitsRecentWhenDisabled() {
  let snapshot = MenuBarLayout.makeAppList(
    pinned: [],
    live: [menuBarApp("live", name: "Live", state: .live)],
    recent: [menuBarApp("recent", name: "Recent", state: .recent)],
    includesRecent: false,
    isExcluded: { _ in false }
  )

  #expect(snapshot.items.map(\.app.logicalID) == ["live"])
  #expect(snapshot.hiddenCount == 0)
  #expect(snapshot.overflowFocus == nil)
}

@Test func overflowFocusUsesTheFirstHiddenGroup() {
  let pinned = (1...7).map {
    menuBarApp("p\($0)", name: "Pinned \($0)", pinned: true)
  }
  let live = [menuBarApp("live", name: "Live", state: .live)]

  let snapshot = MenuBarLayout.makeAppList(
    pinned: pinned,
    live: live,
    recent: [],
    isExcluded: { _ in false }
  )

  #expect(snapshot.hiddenCount == 1)
  #expect(snapshot.overflowFocus == .frontmost)
}

private func menuBarApp(
  _ id: String,
  name: String,
  pinned: Bool = false,
  state: RoutingState = .managed
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: id,
    pid: 42,
    bundleID: "test.\(id)",
    displayName: name,
    category: .media,
    desiredVolume: 0.5,
    appliedVolume: 0.5,
    isPinned: pinned,
    routingState: state,
    compatibility: .supported
  )
}
