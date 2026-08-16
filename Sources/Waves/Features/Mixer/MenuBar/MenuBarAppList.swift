import AppKit
import SwiftUI

struct MenuBarAppList: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let snapshot = MenuBarLayout.makeAppList(
      pinned: store.pinnedApps,
      live: store.liveApps,
      recent: store.recentApps,
      includesRecent: store.preferences.showRecentApps,
      isExcluded: store.isExcluded
    )

    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if snapshot.items.isEmpty, !store.isLoading {
          allQuietState
        } else {
          ForEach(snapshot.groups, id: \.self) { group in
            appGroup(group, snapshot: snapshot)
          }

          if snapshot.hiddenCount > 0 {
            overflowButton(snapshot)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: MenuBarLayout.maximumSectionsHeight)
    .fixedSize(horizontal: false, vertical: true)
    .scrollBounceBehavior(.basedOnSize)
  }

  @ViewBuilder
  private func appGroup(
    _ group: MenuBarAppGroup,
    snapshot: MenuBarAppListSnapshot
  ) -> some View {
    let items = snapshot.items(in: group)

    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        if snapshot.groups.count > 1 {
          WavesSectionHeader(
            group.title,
            systemImage: group.systemImage,
            trailing: AnyView(
              Text("\(items.count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(WavesDesign.tertiaryColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            )
          )
        }

        VStack(spacing: 0) {
          ForEach(items) { item in
            MenuBarAppRow(app: item.app)
              .padding(.horizontal, 8)
              .padding(.vertical, 7)

            if item.id != items.last?.id {
              Divider()
                .padding(.leading, 36)
            }
          }
        }
        .wavesCard(cornerRadius: 10)
      }
    }
  }

  private func overflowButton(_ snapshot: MenuBarAppListSnapshot) -> some View {
    Button {
      if let focus = snapshot.overflowFocus {
        store.focusSource(focus)
      }
      openWindow(id: AppSceneID.mainWindow)
      NSApp.activate(ignoringOtherApps: true)
    } label: {
      Label(
        "View \(snapshot.hiddenCount) more in Waves",
        systemImage: "ellipsis.circle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .wavesLinkPointer()
    .accessibilityHint("Opens the main Waves window to show the remaining apps.")
  }

  private var allQuietState: some View {
    VStack(spacing: 8) {
      WavesMark(size: 28)
        .opacity(0.8)
      Text("All quiet")
        .font(.callout.weight(.semibold))
      Text("Play audio in an app and it will appear here.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Refresh") {
        store.refresh()
      }
      .controlSize(.small)
      .accessibilityLabel("Refresh app list")
      .padding(.top, 1)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
    .padding(.horizontal, 12)
  }
}
