import SwiftUI
import WavesAudioCore

struct MenuBarMixerView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          WavesBrandLogo(size: 16)
          VStack(alignment: .leading, spacing: 2) {
            Text("Waves")
              .font(.headline)
            Text(store.currentDeviceName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            store.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Refresh app list")
          .keyboardShortcut("r", modifiers: [.command])
        }

        if store.isLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Refreshing audio sessions")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        PresetQuickPicker()

        if !store.pinnedApps.isEmpty {
          CompactSection(title: "Pinned", apps: store.pinnedApps)
        }

        CompactSection(title: "Frontmost", apps: store.activeApps)

        if store.preferences.showRecentApps {
          CompactSection(title: "Recent", apps: Array(store.recentApps.prefix(3)))
        }

        if store.pinnedApps.isEmpty && store.activeApps.isEmpty && store.recentApps.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text("No audio apps detected")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 20)
        }

        Divider()

        HStack {
          Button("Open Waves") {
            openWindow(id: AppSceneID.mainWindow)
          }
          .accessibilityLabel("Open Waves main window")

          Button("Settings") {
            openSettings()
          }
          .accessibilityLabel("Open Settings")

          Spacer()
          Toggle(
            isOn: Binding(
              get: { store.launchAtLoginEnabled },
              set: { store.launchAtLoginEnabled = $0 }
            )
          ) {
            Text("Launch at login")
          }
          .toggleStyle(.switch)
          .labelsHidden()
          .accessibilityLabel("Launch at login")
        }
      }
      .padding(14)

      AppToastStack()
        .padding(.top, 10)
        .padding(.trailing, 10)
        .frame(maxWidth: 360)
    }
    .task {
      store.start()
    }
  }
}

private struct PresetQuickPicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.presets) { preset in
        Button(preset.name) {
          store.applyPreset(preset)
        }
      }
    } label: {
      Label("Presets", systemImage: "slider.horizontal.3")
    }
    .menuStyle(.borderlessButton)
  }
}

private struct CompactSection: View {
  let title: String
  let apps: [AudioApp]

  var body: some View {
    if !apps.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        ForEach(apps.prefix(4)) { app in
          CompactMixerRow(app: app)
        }
      }
    }
  }
}
