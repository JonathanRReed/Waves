import AppKit
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
          Text("Mute media during calls")
          Text("Mutes music and video apps while you're on a call, and unmutes them when it ends.")
        }
        .disabled(!store.isAudioRunning)

        Picker(
          "Detect a call",
          selection: Binding(
            get: { store.preferences.callDetectionMode },
            set: { store.setCallDetectionMode($0) }
          )
        ) {
          ForEach(CallDetectionMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.radioGroup)
        .disabled(!store.isAudioRunning || !store.preferences.autoPauseMusicForConferencing)

        if store.preferences.autoPauseMusicForConferencing,
          store.preferences.callDetectionMode == .microphoneInUse
        {
          CallAppsList()
        }
      } header: {
        Text("Calls")
      } footer: {
        Text(
          "In front: works with Zoom, Teams, Webex, and FaceTime, but media comes back when you switch to another app, and browser calls aren't detected. Microphone: works with any app you choose, including a browser, but any microphone use by that app counts as a call. Waves only asks macOS which apps are using the microphone and never listens to it."
        )
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

/// The apps whose microphone use counts as a call, with Remove buttons and an
/// Add menu offering any app Waves has seen, or any installed app.
private struct CallAppsList: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    let chosen = store.callDetectionAppIDs
    if chosen.isEmpty {
      Text("No apps chosen. Add the app you take calls in.")
        .foregroundStyle(.secondary)
    }
    ForEach(chosen, id: \.self) { appID in
      let name = appName(appID)
      HStack {
        Text(name)
        Spacer()
        Button("Remove") { store.setCallDetectionApp(appID, isChosen: false) }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityLabel("Remove \(name) from call apps")
      }
    }
    Menu {
      ForEach(addableApps) { app in
        Button(app.displayName) { store.setCallDetectionApp(app.logicalID, isChosen: true) }
      }
      if addableApps.isEmpty {
        Text("Every app Waves has seen is already chosen")
      }
      Divider()
      Button("Choose App…") { chooseApp() }
    } label: {
      Label("Add App", systemImage: "plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Add a call app")
    .disabled(!store.isAudioRunning)
  }

  private var addableApps: [AudioApp] {
    let chosen = Set(store.callDetectionAppIDs)
    return store.visibleApps
      .filter { !chosen.contains($0.logicalID) }
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  private func appName(_ appID: String) -> String {
    FriendlyAppName.resolve(appID, in: store.session.apps)
  }

  /// For a call app that hasn't run since Waves started, such as a browser.
  private func chooseApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Choose"
    panel.message = "Pick the app you take calls in."
    guard panel.runModal() == .OK,
      let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else { return }
    store.setCallDetectionApp(bundleID, isChosen: true)
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
              .frame(minWidth: 108)
          } else {
            Text("Test Connection")
              .frame(minWidth: 108)
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
      DisclosureGroup("Wave Link setup and troubleshooting") {
        VStack(alignment: .leading, spacing: 6) {
          Text("1. Open Wave Link 3. Keep compatibility on and select Waves as the per-app controller.")
          Text("2. In Wave Link, give each app its own software channel. Choose Create channel and select the app, then add that channel to the mix you listen to.")
          Text("3. Choose Test Connection here, play sound in the app, then adjust its volume in Waves.")
          Text("If connection fails, restart Wave Link and Waves and test again. Use current versions of both apps. If it still fails, open Settings > Diagnostics to copy the report for support.")
          Text("If a connected app is silent, check its channel and mix mute buttons, mix level, and output device in Wave Link. Boost, EQ, and output routing stay in Wave Link.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var status: WaveLinkBridgeStatus? { store.waveLinkBridgeStatus }

  private var title: String {
    switch status?.phase {
    case .connected: "Wave Link connected"
    case .failed: "Wave Link needs attention"
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
      let mix = channel.mixCount == 0 ? ", not added to a mix" : ""
      return "\(channel.name) (\(apps)\(mix))"
    }
    return "Channels: " + described.joined(separator: ", ")
  }
}
