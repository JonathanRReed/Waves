import AppKit
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
          Text("Waves")
            .font(.headline)
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

        OutputDevicePicker()

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

        CompactSection(title: "Live", apps: store.liveApps)

        if store.preferences.showRecentApps {
          CompactSection(title: "Recent", apps: store.recentApps, maxVisible: 3)
        }

        if store.pinnedApps.isEmpty && store.liveApps.isEmpty && store.recentApps.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: "speaker.slash")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text("No audio apps detected")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(spacing: 8) {
              Button("Refresh") {
                store.refresh()
              }
              Button("Settings") {
                openSettings()
              }
            }
            .controlSize(.small)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 20)
        }

        Divider()

        HStack {
          Button("Open Waves") {
            openWindow(id: AppSceneID.mainWindow)
            NSApp.activate(ignoringOtherApps: true)
          }
          .accessibilityLabel("Open Waves main window")

          Button("Settings") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
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

/// Compact output-device switcher for the menu-bar panel — the most frequent
/// action a menu-bar audio utility performs ("Control Center for app audio").
private struct OutputDevicePicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.availableDevices) { device in
        Button {
          store.selectOutputDevice(device)
        } label: {
          if device.id == store.currentDeviceID {
            Label(device.name, systemImage: "checkmark")
          } else {
            Text(device.name)
          }
        }
      }
      if store.availableDevices.isEmpty {
        Text("No output devices found").foregroundStyle(.secondary)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "hifispeaker.fill")
          .foregroundStyle(.secondary)
        Text(store.currentDeviceName)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Output device")
    .accessibilityValue(store.currentDeviceName)
    .help("Switch the system output device")
    .onAppear { store.refreshOutputDevices() }
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
  @Environment(\.openWindow) private var openWindow
  let title: String
  let apps: [AudioApp]
  var maxVisible: Int = 4

  var body: some View {
    if !apps.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        ForEach(apps.prefix(maxVisible)) { app in
          CompactMixerRow(app: app)
        }

        if apps.count > maxVisible {
          Button {
            openWindow(id: AppSceneID.mainWindow)
            NSApp.activate(ignoringOtherApps: true)
          } label: {
            Label("\(apps.count - maxVisible) more in Waves", systemImage: "ellipsis.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens the main Waves window to show all \(title.lowercased()) apps.")
        }
      }
    }
  }
}
