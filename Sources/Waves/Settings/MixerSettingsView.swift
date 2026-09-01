import SwiftUI
import WavesAudioCore

struct MixerSettingsView: View {
  @Environment(AppStore.self) private var store
  @State private var confirmingClearPresets = false

  var body: some View {
    SettingsForm {
      Section {
        Toggle(
          "Wave Link compatibility",
          isOn: Binding(
            get: { store.preferences.waveLinkCompatibilityEnabled },
            set: { store.setWaveLinkCompatibilityEnabled($0) }
          )
        )
        Picker(
          "Per-app controller",
          selection: Binding(
            get: { store.preferences.perAppAudioController },
            set: { store.setPerAppAudioController($0) }
          )
        ) {
          ForEach(PerAppAudioController.allCases) { controller in
            Text(controller.displayName).tag(controller)
          }
        }
        .pickerStyle(.radioGroup)
        .disabled(!store.preferences.waveLinkCompatibilityEnabled)

        Text(waveLinkControllerDescription)
          .font(.callout)
          .foregroundStyle(.secondary)

        if store.preferences.waveLinkCompatibilityEnabled,
          store.preferences.perAppAudioController == .waves
        {
          WaveLinkBridgeStatusRow()
        }
      } header: {
        Text("Wave Link")
      } footer: {
        Text(
          store.preferences.waveLinkCompatibilityEnabled
            ? "Only one app renders each audio path. With Waves selected, volume and mute use a dedicated Wave Link software channel."
            : "Compatibility is off. Use this only after your custom Wave Link routing prevents a second monitored copy."
        )
      }

      Section {
        Toggle(isOn: PreferenceBinding.durable(store: store, \.showRecentApps)) {
          Text("Show recent apps")
          Text("Keep apps that recently played in the list, not just the ones playing now.")
        }
        Picker(
          "Keep quiet apps in Live",
          selection: Binding(
            get: { store.preferences.liveListLinger },
            set: { store.setLiveListLinger($0) }
          )
        ) {
          ForEach(LiveListLinger.allCases) { option in
            Text(option.displayName).tag(option)
          }
        }
        .help("How long an app stays in Live after its audio stops.")
        Toggle(isOn: PreferenceBinding.durable(store: store, \.showSystemProcesses)) {
          Text("Show system processes")
          Text("Include macOS background audio processes in the mixer.")
        }
        Picker("Sort apps by", selection: PreferenceBinding.durable(store: store, \.sortMode)) {
          ForEach(SortMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
      } header: {
        Text("App List")
      } footer: {
        Text(
          "If apps disappear during short pauses or track changes, set Keep quiet apps in Live to Relaxed. If the Live list feels sticky, set it to Brief."
        )
      }

      Section {
        Toggle(isOn: PreferenceBinding.durable(store: store, \.enablePerDeviceVolumePresets)) {
          Text("Remember levels per output device")
          Text("Keep a separate volume, mute, and boost for each app on each output device.")
        }
        .disabled(!store.isAudioRunning)
        Toggle(
          isOn: Binding(
            get: { store.preferences.autoRestoreDevice },
            set: { store.setAutoRestoreDeviceEnabled($0) }
          )
        ) {
          Text("Restore levels when devices switch")
          Text("Apply the remembered levels automatically when you change output devices.")
        }
        .disabled(!store.isAudioRunning)

        LabeledContent(
          "Saved for this device",
          value: "\(currentDevicePresetCount) \(currentDevicePresetCount == 1 ? "app" : "apps")")
        LabeledContent("Devices with saved levels", value: "\(devicesWithPresetsCount)")

        Button("Clear All Saved Levels…", role: .destructive) {
          confirmingClearPresets = true
        }
        .disabled(!hasAnyPresets)
        .confirmationDialog(
          "Clear all saved per-device levels?",
          isPresented: $confirmingClearPresets,
          titleVisibility: .visible
        ) {
          Button("Clear Saved Levels", role: .destructive) {
            store.clearDeviceVolumePresets()
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "Removes the remembered volume, mute, and boost per app for every output device. This can't be undone."
          )
        }
      } header: {
        Text("Volume Memory")
      } footer: {
        Text(
          "Example: headphones at 40% for Spotify, speakers at 80%. Waves switches between them with the device."
        )
      }

      Section {
        Toggle(
          isOn: Binding(
            get: { store.preferences.autoPauseMusicForConferencing },
            set: { store.setAutoPauseMusicEnabled($0) }
          )
        ) {
          Text("Mute media during video calls")
          Text("Mutes media apps while a known video call app is in front. Calls in a browser aren't detected.")
        }
        .disabled(!store.isAudioRunning)
      } header: {
        Text("Calls")
      } footer: {
        Text("Adaptive Mix, Sidechain Focus, and equalizers live in the main window under Sound.")
      }
    }
  }

  private var currentDevicePresetCount: Int {
    guard let id = store.currentDeviceID else { return 0 }
    return store.deviceVolumePresets.deviceVolumes[id]?.count ?? 0
  }

  private var devicesWithPresetsCount: Int {
    store.deviceVolumePresets.deviceVolumes.filter { !$0.value.isEmpty }.count
  }

  private var hasAnyPresets: Bool {
    devicesWithPresetsCount > 0
  }

  private var waveLinkControllerDescription: String {
    guard store.preferences.waveLinkCompatibilityEnabled else {
      return "Waves applies normal per-app routing and ignores Wave Link-specific conflicts."
    }
    switch store.preferences.perAppAudioController {
    case .waves:
      return "Waves stays your per-app mixer. While Wave Link is mixing, Waves sends each app's volume and mute to its own Wave Link software channel so audio is never doubled. Boost, EQ, and output routing stay in Wave Link for those apps."
    case .waveLink:
      return "Wave Link controls app levels while it is active. Waves monitors affected apps without creating a second route."
    }
  }

}

/// Shows what the Wave Link control bridge last saw and offers a read-only
/// connection test, so a user can tell "Wave Link is not running" from "the
/// channel layout leaves no room" without reading logs.
private struct WaveLinkBridgeStatusRow: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: symbolName)
          .foregroundStyle(symbolColor)
          .accessibilityHidden(true)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button {
          store.testWaveLinkConnection()
        } label: {
          if store.isTestingWaveLinkConnection {
            ProgressView()
              .controlSize(.small)
              .frame(width: 96)
          } else {
            Text("Test Connection")
              .frame(width: 96)
          }
        }
        .buttonStyle(.bordered)
        .disabled(!store.isAudioRunning || store.isTestingWaveLinkConnection)
        .help("Connects to Wave Link and lists its channels without changing anything.")
      }
      if let status = store.waveLinkBridgeStatus, status.phase == .connected, !status.channels.isEmpty {
        Text(channelLayout(status))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title). \(detail)")
  }

  private var status: WaveLinkBridgeStatus? { store.waveLinkBridgeStatus }

  private var title: String {
    switch status?.phase {
    case .connected: "Wave Link connected"
    case .failed: "Wave Link not reachable"
    case .idle, nil: "Wave Link connection"
    }
  }

  private var detail: String {
    guard let status else { return "Not checked yet. Test the connection to see Wave Link's channels." }
    switch status.phase {
    case .idle:
      return "Not checked yet. Test the connection to see Wave Link's channels."
    case .connected, .failed:
      return status.summaryLine
    }
  }

  private var symbolName: String {
    switch status?.phase {
    case .connected: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .idle, nil: "link.circle"
    }
  }

  private var symbolColor: Color {
    switch status?.phase {
    case .connected: .green
    case .failed: .orange
    case .idle, nil: .secondary
    }
  }

  private func channelLayout(_ status: WaveLinkBridgeStatus) -> String {
    let software = status.channels.filter(\.isSoftware)
    guard !software.isEmpty else { return "No software channels reported." }
    let described = software.map { channel -> String in
      let apps = channel.appIdentifiers.isEmpty ? "free" : "\(channel.appIdentifiers.count) app\(channel.appIdentifiers.count == 1 ? "" : "s")"
      return "\(channel.name) (\(apps))"
    }
    return "Channels: " + described.joined(separator: ", ")
  }
}
