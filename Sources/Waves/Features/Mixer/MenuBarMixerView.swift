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
        MenuBarHeader()

        // The "mixed waves" band — a live visualization of the combined audio
        // energy of everything currently playing. Quiet when silent, alive when
        // sound is flowing. Rendered on a solid content surface (not glass) per
        // Apple's material guidance for real-time graphics.
        HeaderWaveform(height: 40)
          .padding(.horizontal, 4)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color.black.opacity(0.22))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(WavesDesign.stroke)
          )

        OutputDevicePicker()

        if store.isLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Refreshing audio sessions")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Refreshing audio sessions, in progress")
        }

        ProfileQuickPicker()

        // De-duplicate apps across sections: an app pinned by the user renders
        // only under "Pinned", never again under "Live" or "Recent".
        let pinnedIDs = Set(store.pinnedApps.map(\.logicalID))
        let liveApps = store.liveApps.filter { !pinnedIDs.contains($0.logicalID) }
        let recentApps = store.recentApps.filter { !pinnedIDs.contains($0.logicalID) }

        if !store.pinnedApps.isEmpty {
          CompactSection(title: "Pinned", systemImage: "pin.fill", apps: store.pinnedApps)
        }

        CompactSection(title: "Live", systemImage: "waveform", apps: liveApps)

        if store.preferences.showRecentApps {
          CompactSection(title: "Recent", systemImage: "clock", apps: recentApps, maxVisible: 3)
        }

        if !store.isLoading && store.pinnedApps.isEmpty && liveApps.isEmpty && recentApps.isEmpty {
          VStack(spacing: 10) {
            WavesMark(size: 34)
              .opacity(0.85)
            Text("All quiet")
              .font(.callout.weight(.semibold))
            Text("Play audio in an app and it shows up here, ready to mix.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              Button("Refresh") {
                store.refresh()
              }
              Button("Settings") {
                openSettings()
              }
            }
            .controlSize(.small)
            .padding(.top, 2)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 22)
          .padding(.horizontal, 12)
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
          .help("Launch Waves automatically at login")
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
    .onAppear { store.beginLiveLevels() }
    .onDisappear { store.endLiveLevels() }
  }
}

/// The menu-bar panel header: the Waves mark (which gently animates while audio
/// is live), a live-state status line, and a refresh control.
private struct MenuBarHeader: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    HStack(spacing: 10) {
      WavesMark(size: 26, live: !store.liveApps.isEmpty)

      VStack(alignment: .leading, spacing: 1) {
        Text("Waves")
          .font(.headline)
        Text(statusLine)
          .font(.caption2)
          .foregroundStyle(store.liveApps.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(WavesDesign.accent))
          .lineLimit(1)
          .contentTransition(.numericText())
      }

      Spacer()

      Button {
        store.refresh()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.callout)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Refresh app list")
      .help("Refresh the app list")
      .keyboardShortcut("r", modifiers: [.command])
    }
  }

  private var statusLine: String {
    let live = store.liveApps.count
    if store.visibleApps.contains(where: \.isMuted) && live == 0 {
      return "Muted"
    }
    switch live {
    case 0: return "Nothing playing"
    case 1: return "1 app playing"
    default: return "\(live) apps playing"
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

private struct ProfileQuickPicker: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Menu {
      ForEach(store.profiles) { profile in
        Button {
          store.applyProfile(profile)
        } label: {
          if profile.id == store.activeProfileID {
            Label(profile.name, systemImage: "checkmark")
          } else {
            Text(profile.name)
          }
        }
      }
      if store.profiles.isEmpty {
        Text("No profiles yet").foregroundStyle(.secondary)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "rectangle.stack")
          .foregroundStyle(.secondary)
        Text(activeProfileName)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel("Profile")
    .accessibilityValue(activeProfileName)
    .help("Switch profile")
  }

  private var activeProfileName: String {
    guard let id = store.activeProfileID,
          let profile = store.profiles.first(where: { $0.id == id }) else {
      return "Profiles"
    }
    return profile.name
  }
}

private struct CompactSection: View {
  @Environment(\.openWindow) private var openWindow
  let title: String
  var systemImage: String?
  let apps: [AudioApp]
  var maxVisible: Int = 4

  var body: some View {
    if !apps.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        WavesSectionHeader(
          title,
          systemImage: systemImage,
          trailing: AnyView(
            Text("\(apps.count)")
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(.tertiary)
          )
        )

        VStack(spacing: 2) {
          ForEach(apps.prefix(maxVisible)) { app in
            CompactMixerRow(app: app)
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                  .fill(Color.white.opacity(0.04))
              )
          }
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
