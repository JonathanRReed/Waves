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
      } header: {
        Text("Wave Link")
      } footer: {
        Text(
          store.preferences.waveLinkCompatibilityEnabled
            ? "Do not assign the same app through both mixers. Doing so can create duplicate audio."
            : "Compatibility is off. Waves will not avoid Wave Link routes or its mixed output, which can cause duplicate or silent audio."
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
      return "Waves controls each app. Route apps to Wave Link virtual channels when Wave Link should decide what the monitor or stream hears."
    case .waveLink:
      return "Wave Link controls app levels while it is active. Waves monitors affected apps without creating a second route."
    }
  }

}
