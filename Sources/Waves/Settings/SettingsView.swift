import SwiftUI

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
    List {
      ForEach(store.presets) { preset in
        VStack(alignment: .leading, spacing: 4) {
          Text(preset.name)
          Text("\(preset.entries.count) entries")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .onDelete(perform: store.deletePresets)
    }
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
