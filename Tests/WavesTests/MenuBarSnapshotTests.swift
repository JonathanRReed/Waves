import Foundation
import Dispatch
import Testing
import WavesAudioCore

@testable import Waves

/// Opt-in comparison of the actual AppStore derivations used by the menu bar.
/// Timing is evidence for this operation only, never a whole-app CPU claim.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WAVES_MENU_BENCHMARK_OUTPUT"] != nil))
@MainActor func menuBarRosterBenchmark() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = WavesComposition.makeStore(
    environment: ["CFFIXED_USER_HOME": directory.path],
    liveBackendFactory: { PreviewAudioControlBackend(snapshot: .empty) }
  )
  store.preferences.sortMode = .activity
  let iterations = 1000
  var measurements: [[String: Any]] = []
  for appCount in [40, 150] {
    store.session.apps = (0..<appCount).map { index in
      AudioApp(
        id: "app.\(index)", displayName: "App \(index)", category: .media,
        routingState: index.isMultiple(of: 3) ? .live : .recent,
        compatibility: .supported
      )
    }
    store.preferences.pinnedAppIDs = store.session.apps.enumerated().compactMap {
      $0.offset.isMultiple(of: 7) ? $0.element.logicalID : nil
    }
    func previous() -> MenuBarAppListSnapshot {
      MenuBarLayout.makeAppList(
        pinned: store.pinnedApps, live: store.liveApps, recent: store.recentApps,
        includesRecent: store.preferences.showRecentApps, isExcluded: store.isExcluded
      )
    }
    func current() -> MenuBarAppListSnapshot {
      MenuBarLayout.makeAppList(
        visibleApps: store.visibleApps, includesRecent: store.preferences.showRecentApps,
        isRecentlyLive: store.isRecentlyLive, isExcluded: store.isExcluded
      )
    }
    #expect(previous() == current())
    var checksum = 0
    let beforeStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum += previous().hiddenCount }
    let before = DispatchTime.now().uptimeNanoseconds - beforeStart
    let afterStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { checksum += current().hiddenCount }
    let after = DispatchTime.now().uptimeNanoseconds - afterStart
    measurements.append([
      "appCount": appCount, "iterations": iterations,
      "previousNanoseconds": before, "currentNanoseconds": after,
      "checksum": checksum,
    ])
  }
  _ = await store.shutdown()
  let output = try #require(ProcessInfo.processInfo.environment["WAVES_MENU_BENCHMARK_OUTPUT"])
  try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: output), options: .atomic)
}

@Test func singleRosterMenuPreservesSectionPriorityLingerAndExclusions() {
  let apps = (0..<20).map { index in
    AudioApp(
      id: "runtime.\(index)",
      logicalID: "app.\(index)",
      displayName: "App \(index)",
      category: .media,
      isPinned: index.isMultiple(of: 4),
      routingState: index.isMultiple(of: 3) ? .live : .recent,
      compatibility: .supported
    )
  }
  // An already-quiet source remains in Live during its linger window.
  let isRecentlyLive: (AudioApp) -> Bool = { $0.routingState == .live || $0.logicalID == "app.5" }
  let isExcluded: (AudioApp) -> Bool = { $0.logicalID == "app.4" || $0.logicalID == "app.3" }
  for showsRecent in [false, true] {
    let pinned = apps.filter(\.isPinned)
    let live = apps.filter(isRecentlyLive)
    let liveIDs = Set(live.map(\.logicalID))
    let recent = apps.filter { !$0.isPinned && !liveIDs.contains($0.logicalID) }
    let previous = MenuBarLayout.makeAppList(
      pinned: pinned, live: live, recent: recent,
      includesRecent: showsRecent, isExcluded: isExcluded
    )
    let current = MenuBarLayout.makeAppList(
      visibleApps: apps, includesRecent: showsRecent,
      isRecentlyLive: isRecentlyLive, isExcluded: isExcluded
    )
    #expect(current == previous)
  }
}

@Test func singleRosterMenuKeepsPinnedPriorityForDuplicateLogicalIdentities() {
  let ordinary = AudioApp(
    id: "old", logicalID: "shared", displayName: "App", category: .media,
    routingState: .live, compatibility: .supported
  )
  let pinned = AudioApp(
    id: "new", logicalID: "shared", displayName: "App", category: .media,
    isPinned: true, routingState: .live, compatibility: .supported
  )
  let snapshot = MenuBarLayout.makeAppList(
    visibleApps: [ordinary, pinned], isRecentlyLive: { $0.routingState == .live },
    isExcluded: { _ in false }
  )
  #expect(snapshot.items.count == 1)
  #expect(snapshot.items.first?.app.id == "new")
  #expect(snapshot.items.first?.group == .pinned)
}
