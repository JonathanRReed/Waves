import SwiftUI

struct MenuBarHeader: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(spacing: 9) {
      WavesMark(size: 23, live: store.hasLiveAudio)

      VStack(alignment: .leading, spacing: 1) {
        Text("Waves")
          .font(.callout.weight(.semibold))
        Text(statusLine)
          .font(.caption2)
          .foregroundStyle(
            store.hasLiveAudio
              ? (contrast == .increased ? Color.primary : theme.accent)
              : Color.secondary
          )
          .lineLimit(1)
          .contentTransition(.numericText())
      }

      Spacer(minLength: 8)

      Button {
        store.refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.callout)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(.borderless)
      .disabled(store.isRefreshing)
      .accessibilityLabel(
        store.isRefreshing ? "Refreshing app list, in progress" : "Refresh app list"
      )
      .help("Refresh the app list")
      .keyboardShortcut("r", modifiers: [.command])
    }
  }

  private var statusLine: String {
    switch store.menuBarStatus {
    case .setup, .idle:
      "Nothing playing"
    case .muted:
      "Muted"
    case .playing:
      store.actuallyLiveApps.count == 1
        ? "1 app playing"
        : "\(store.actuallyLiveApps.count) apps playing"
    }
  }
}
