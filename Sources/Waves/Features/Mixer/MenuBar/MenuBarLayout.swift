import CoreGraphics
import WavesAudioCore

enum MenuBarAppGroup: String, Hashable, Sendable {
  case pinned
  case live
  case recent

  var title: String {
    switch self {
    case .pinned: "Pinned"
    case .live: "Live"
    case .recent: "Recent"
    }
  }

  var systemImage: String {
    switch self {
    case .pinned: "pin.fill"
    case .live: "waveform"
    case .recent: "clock"
    }
  }

  var sourceFilter: SourceFilter {
    switch self {
    case .pinned: .pinned
    case .live: .frontmost
    case .recent: .recent
    }
  }
}

struct MenuBarAppItem: Identifiable, Hashable, Sendable {
  let app: AudioApp
  let group: MenuBarAppGroup

  var id: String { app.logicalID }
}

struct MenuBarAppListSnapshot: Equatable, Sendable {
  let items: [MenuBarAppItem]
  let hiddenCount: Int
  let overflowFocus: SourceFilter?

  var groups: [MenuBarAppGroup] {
    var seen = Set<MenuBarAppGroup>()
    return items.compactMap { item in
      seen.insert(item.group).inserted ? item.group : nil
    }
  }

  func items(in group: MenuBarAppGroup) -> [MenuBarAppItem] {
    items.filter { $0.group == group }
  }
}

enum MenuBarLayout {
  static let panelWidth: CGFloat = 372
  static let maximumVisibleApps = 7
  static let maximumSectionsHeight: CGFloat = 420
  static let liveWaveformHeight: CGFloat = 28

  /// Partitions one sorted roster instead of sorting independently for each
  /// section. The shared builder still owns deduplication and overflow rules.
  static func makeAppList(
    visibleApps: [AudioApp],
    includesRecent: Bool = true,
    isRecentlyLive: (AudioApp) -> Bool,
    isExcluded: (AudioApp) -> Bool
  ) -> MenuBarAppListSnapshot {
    var pinned: [AudioApp] = []
    var live: [AudioApp] = []
    var recent: [AudioApp] = []
    for app in visibleApps where !isExcluded(app) {
      if app.isPinned {
        pinned.append(app)
      } else if isRecentlyLive(app) {
        live.append(app)
      } else if includesRecent {
        recent.append(app)
      }
    }
    return makeAppList(
      pinned: pinned,
      live: live,
      recent: recent,
      includesRecent: includesRecent,
      isExcluded: { _ in false }
    )
  }

  static func makeAppList(
    pinned: [AudioApp],
    live: [AudioApp],
    recent: [AudioApp],
    includesRecent: Bool = true,
    isExcluded: (AudioApp) -> Bool
  ) -> MenuBarAppListSnapshot {
    var seen = Set<String>()
    var all: [MenuBarAppItem] = []

    func append(_ apps: [AudioApp], group: MenuBarAppGroup) {
      for app in apps where !isExcluded(app) && seen.insert(app.logicalID).inserted {
        all.append(MenuBarAppItem(app: app, group: group))
      }
    }

    append(pinned, group: .pinned)
    append(live, group: .live)
    if includesRecent {
      append(recent, group: .recent)
    }

    let visible = Array(all.prefix(maximumVisibleApps))
    let hiddenCount = max(0, all.count - visible.count)
    let hiddenGroups = Set(all.dropFirst(visible.count).map(\.group))
    let overflowFocus: SourceFilter? =
      if hiddenGroups.count > 1 {
        .running
      } else {
        hiddenGroups.first?.sourceFilter
      }

    return MenuBarAppListSnapshot(
      items: visible,
      hiddenCount: hiddenCount,
      overflowFocus: hiddenCount == 0 ? nil : overflowFocus
    )
  }
}
