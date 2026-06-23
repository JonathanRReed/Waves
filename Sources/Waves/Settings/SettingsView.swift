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

      ProfileSettingsView()
        .tabItem {
          Label("Profiles", systemImage: "rectangle.stack")
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
    .background(WavesBackground())
    .onDisappear {
      store.persistPreferences()
    }
  }
}

private struct GeneralSettingsView: View {
  @Environment(AppStore.self) private var store
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

  var body: some View {
    Form {
      Toggle(
        "Launch at login",
        isOn: Binding(
          get: { store.launchAtLoginEnabled },
          set: { store.launchAtLoginEnabled = $0 }
        ))

      Toggle("Show Waves in the menu bar", isOn: $showMenuBarExtra)
        .help("Shows or hides the Waves icon in the menu bar. The app keeps running either way; reopen this window from the Dock or by relaunching Waves.")

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
        "Pause media when a video-call app is in front",
        isOn: Binding(
          get: { store.preferences.autoPauseMusicForConferencing },
          set: { store.setAutoPauseMusicEnabled($0) }
        ))
        .help("Pauses media-playing apps while a known video-call app is the frontmost app. This is a heuristic based on the foreground app, not actual call state, so browser-based calls are not detected.")

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
        .help("Remembers a separate volume for each output device. Restoring a remembered level when you switch devices also requires “Auto-restore device” to be on. Turning this off stops recording new levels but leaves any already-stored device settings in place.")

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
        .help("Lets other apps and links control Waves through waves:// URLs (set volume, mute, apply profiles). Off by default — enable only if you rely on automation.")

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
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Label("Current output device", systemImage: "hifispeaker.2.fill")
            .font(.headline)
          Text(store.currentDeviceName)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .wavesCard()

        VStack(alignment: .leading, spacing: 10) {
          Label("Managed routing", systemImage: "waveform.path")
            .font(.headline)
          Text(
            "Managed routes use Core Audio process taps to capture selected app audio, apply volume, mute, and boost, then play it back to the current output device. Audio is processed locally on this Mac."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Button {
            store.recoverRoutes()
          } label: {
            Label("Recover Routes", systemImage: "arrow.clockwise")
          }
          .disabled(store.isRecovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .wavesCard()

        Text("Boost controls are available in each mixer row. Use 1× for transparent playback, and reserve 2× to 4× for quiet apps to avoid clipping.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 2)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }
}

private struct ProfileSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Profiles")
            .font(.headline)
          Text("Groups of apps you switch between — optionally with saved levels.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          store.importProfiles()
        } label: {
          Label("Import", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.bordered)
      }

      if store.profiles.isEmpty {
        Text("No profiles yet. Create one with the + button in the main window’s sidebar, or import one.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        List {
          ForEach(store.profiles) { profile in
            HStack(spacing: 10) {
              Image(systemName: profile.carriesLevels ? "slider.horizontal.below.square.filled.and.square" : "square.grid.2x2")
                .foregroundStyle(.secondary)
                .frame(width: 20)

              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(detail(for: profile))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              Button("Export") {
                store.exportProfile(profile)
              }
              .buttonStyle(.borderless)
              .controlSize(.small)
              .accessibilityLabel("Export profile \(profile.name)")

              Button("Delete", role: .destructive) {
                if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
                  store.deleteProfiles(at: IndexSet(integer: index))
                }
              }
              .buttonStyle(.borderless)
              .controlSize(.small)
              .accessibilityLabel("Delete profile \(profile.name)")
            }
          }
          .onDelete(perform: store.deleteProfiles)
        }
      }
    }
    .padding(20)
  }

  private func detail(for profile: Profile) -> String {
    let count = profile.entries.count
    let noun = count == 1 ? "app" : "apps"
    return profile.carriesLevels ? "\(count) \(noun) · saved levels" : "\(count) \(noun) · group"
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
          .disabled(store.diagnostics == nil)
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
            .wavesCard(cornerRadius: 14)
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
    .wavesCard(cornerRadius: 14)
  }
}
