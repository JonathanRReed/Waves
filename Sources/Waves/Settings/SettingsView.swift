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
          Label("Setup", systemImage: "checklist")
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
        "Auto-pause music during calls",
        isOn: Binding(
          get: { store.preferences.autoPauseMusicForConferencing },
          set: { store.setAutoPauseMusicEnabled($0) }
        ))

      Toggle(
        "Enable keyboard shortcuts",
        isOn: Binding(
          get: { store.preferences.enableKeyboardShortcuts },
          set: { store.setKeyboardShortcutsEnabled($0) }
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

      Toggle(
        "URL scheme automation",
        isOn: Binding(
          get: { store.preferences.enableURLScheme },
          set: {
            store.preferences.enableURLScheme = $0
            store.preferences.urlSchemeAutomationAcknowledged = true
            store.persistPreferences()
          }
        ))
        .help("Lets other apps and links control Waves through waves:// URLs (set volume, mute, apply presets). Off by default — enable only if you rely on automation.")

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

      Text("Managed routing")
        .font(.headline)
      Text(
        "Managed routes use Core Audio process taps to capture selected app audio, apply volume, mute, and boost, then play it back to the current output device. Audio is processed locally on this Mac."
      )
      .foregroundStyle(.secondary)

      Button("Recover Routes") {
        store.recoverRoutes()
      }

      Text("Boost controls are available in each mixer row. Use 1x for transparent playback, and reserve 2x to 4x for quiet apps to avoid clipping.")
        .font(.caption)
        .foregroundStyle(.secondary)
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
      }

      if store.presets.isEmpty {
        Text("No presets yet. Save a mix from the main window, or import one.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        List {
        ForEach(store.presets) { preset in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(preset.name)
              Text("\(preset.entries.count) \(preset.entries.count == 1 ? "app" : "apps")")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Export") {
              store.exportPreset(preset)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Export preset \(preset.name)")

            Button("Delete", role: .destructive) {
              if let index = store.presets.firstIndex(where: { $0.id == preset.id }) {
                store.deletePresets(at: IndexSet(integer: index))
              }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Delete preset \(preset.name)")
          }
        }
        .onDelete(perform: store.deletePresets)
        }
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
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Running apps")
              .font(.headline)
            Text(store.sourceInventorySummary)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            store.copyDiagnosticsToPasteboard()
          } label: {
            Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
          }
          .help("Copy a plain-text route-health report to the clipboard.")
        }

        if let diagnostics = store.diagnostics {
          ForEach(diagnostics.checks) { check in
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 8) {
                // Shape-differentiated glyph per status so color-blind sighted
                // users can distinguish pass/warn/fail/info by shape, not hue
                // alone. Hidden from VoiceOver; the combined label carries the
                // status word.
                Image(systemName: symbol(for: check.status))
                  .foregroundStyle(color(for: check.status))
                  .accessibilityHidden(true)
                Text(check.title)
                  .font(.headline)
              }
              .accessibilityElement(children: .combine)
              .accessibilityLabel("\(statusLabel(for: check.status)): \(check.title)")
              Text(check.detail)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
              .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
        } else {
          DiagnosticsUnavailableView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      store.refreshDiagnostics()
    }
  }

  private func color(for status: DiagnosticsStatus) -> Color {
    switch status {
    case .passed:
      .green
    case .warning:
      .orange
    case .failed:
      .red
    case .informational:
      .secondary
    }
  }

  private func symbol(for status: DiagnosticsStatus) -> String {
    switch status {
    case .passed:
      "checkmark.circle"
    case .warning:
      "exclamationmark.triangle"
    case .failed:
      "xmark.octagon"
    case .informational:
      "info.circle"
    }
  }

  private func statusLabel(for status: DiagnosticsStatus) -> String {
    switch status {
    case .passed:
      "Passed"
    case .warning:
      "Warning"
    case .failed:
      "Failed"
    case .informational:
      "Info"
    }
  }
}

private struct DiagnosticsUnavailableView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Diagnostics are not loaded", systemImage: "waveform.path.ecg")
        .font(.headline)

      Text(store.session.backendStatus.lastError ?? "Refresh diagnostics to inspect permissions, route recovery, and support coverage.")
        .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        Button {
          store.refreshDiagnostics()
        } label: {
          Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)

        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "waveform.path")
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
