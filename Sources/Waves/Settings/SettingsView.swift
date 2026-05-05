import SwiftUI
import WavesAudioCore

struct SettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem {
          Label("General", systemImage: "gearshape")
        }
      OnboardingView()
        .tabItem {
          Label("Onboarding", systemImage: "checklist")
        }

      AudioSettingsView()
        .tabItem {
          Label("Audio", systemImage: "speaker.wave.3")
        }

      PresetSettingsView()
        .tabItem {
          Label("Presets", systemImage: "slider.horizontal.3")
        }

      DiagnosticsSettingsView()
        .tabItem {
          Label("Advanced", systemImage: "waveform.path.ecg")
        }

      HelpView()
        .tabItem {
          Label("Help", systemImage: "questionmark.circle")
        }
    }
    .padding(20)
    .background(WavesDesign.windowGradient)
    .onDisappear {
      store.persistPreferences()
    }
  }
}

private struct GeneralSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Form {
      Toggle(
        "Launch at login",
        isOn: Binding(
          get: { store.launchAtLoginEnabled },
          set: { store.launchAtLoginEnabled = $0 }
        ))

      Toggle(
        "Show recent apps",
        isOn: Binding(
          get: { store.preferences.showRecentApps },
          set: {
            store.preferences.showRecentApps = $0
            store.persistPreferences()
          }
        ))

      Toggle(
        "Show system processes",
        isOn: Binding(
          get: { store.preferences.showSystemProcesses },
          set: {
            store.preferences.showSystemProcesses = $0
            store.persistPreferences()
          }
        ))

      Toggle(
        "Auto-restore device",
        isOn: Binding(
          get: { store.preferences.autoRestoreDevice },
          set: {
            store.preferences.autoRestoreDevice = $0
            store.persistPreferences()
          }
        ))

      Toggle(
        "Auto-pause music during calls",
        isOn: Binding(
          get: { store.preferences.autoPauseMusicForConferencing },
          set: {
            store.preferences.autoPauseMusicForConferencing = $0
            store.persistPreferences()
          }
        ))

      Toggle(
        "Enable keyboard shortcuts",
        isOn: Binding(
          get: { store.preferences.enableKeyboardShortcuts },
          set: {
            store.preferences.enableKeyboardShortcuts = $0
            store.persistPreferences()
          }
        ))

      Toggle(
        "Per-device volume presets",
        isOn: Binding(
          get: { store.preferences.enablePerDeviceVolumePresets },
          set: {
            store.preferences.enablePerDeviceVolumePresets = $0
            store.persistPreferences()
          }
        ))

      if store.preferences.enableKeyboardShortcuts {
        VStack(alignment: .leading, spacing: 8) {
          Text("Keyboard shortcuts")
            .font(.headline)

          HStack {
            Text("Increase volume")
              .foregroundStyle(.secondary)
            Spacer()
            Text("⌘⌥↑")
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Decrease volume")
              .foregroundStyle(.secondary)
            Spacer()
            Text("⌘⌥↓")
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          HStack {
            Text("Toggle mute")
              .foregroundStyle(.secondary)
            Spacer()
            Text("⌘⌥M")
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 8)
      }

      Picker(
        "Sort apps by",
        selection: Binding(
          get: { store.preferences.sortMode },
          set: {
            store.preferences.sortMode = $0
            store.persistPreferences()
          }
        )
      ) {
        ForEach(SortMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct AudioSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Current output device")
        .font(.headline)
      Text(store.currentDeviceName)
        .foregroundStyle(.secondary)

      if let device = store.session.currentDevice {
        VStack(alignment: .leading, spacing: 8) {
          Text("Volume control mode")
            .font(.headline)

          Picker(
            "Volume control mode",
            selection: Binding(
              get: { device.volumeControlMode },
              set: { store.setVolumeControlMode($0) }
            )
          ) {
            ForEach(VolumeControlMode.allCases) { mode in
              VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName)
                Text(mode.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .tag(mode)
            }
          }
          .pickerStyle(.radioGroup)
        }
      }

      Text("Managed routing")
        .font(.headline)
      Text(
        "This scaffold keeps managed route ownership behind the audio backend boundary. The preview backend reports install state, route health, and support coverage without binding the app to a concrete audio component yet."
      )
      .foregroundStyle(.secondary)

      Button("Recover routes now") {
        store.recoverRoutes()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct PresetSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Presets")
          .font(.headline)

        Spacer()

        Button("Import") {
          store.importPreset()
        }
        .buttonStyle(.bordered)

        Button("Export First") {
          if let preset = store.presets.first {
            store.exportPreset(preset)
          }
        }
        .buttonStyle(.bordered)
        .disabled(store.presets.isEmpty)
      }

      List {
        ForEach(store.presets) { preset in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(preset.name)
              Text("\(preset.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Export") {
              store.exportPreset(preset)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
          }
        }
        .onDelete(perform: store.deletePresets)
      }
    }
    .padding(20)
  }
}

private struct DiagnosticsSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Running apps")
          .font(.headline)
        Text(store.sourceInventorySummary)
          .foregroundStyle(.secondary)

        if let diagnostics = store.diagnostics {
          ForEach(diagnostics.checks) { check in
            VStack(alignment: .leading, spacing: 4) {
              Text(check.title)
                .font(.headline)
              Text(check.detail)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
              .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
