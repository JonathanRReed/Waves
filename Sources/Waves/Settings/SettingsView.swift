import SwiftUI
import WavesAudioCore

/// One case per settings pane. Order here drives the sidebar's top-to-bottom
/// order, so reordering panes is a one-line change.
private enum SettingsPane: String, CaseIterable, Identifiable {
  case general, setup, audio, profiles, advanced, help

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .setup: "Setup"
    case .audio: "Audio"
    case .profiles: "Profiles"
    case .advanced: "Advanced"
    case .help: "Help"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .setup: "checklist"
    case .audio: "speaker.wave.3"
    case .profiles: "rectangle.stack"
    case .advanced: "waveform.path.ecg"
    case .help: "questionmark.circle"
    }
  }
}

/// A modern System Settings-style preferences window: a fixed leading sidebar
/// of section names (own color control, never the native icon-tab chrome) with
/// the active pane's content to the right.
///
/// This replaces a prior `TabView { ... }.tabItem { ... }` implementation. That
/// native icon-style TabView's selected-tab indicator pill always renders in
/// the *system* accent color (NSColor.controlAccentColor) and ignores SwiftUI's
/// `.tint()` modifier entirely — a confirmed AppKit-level limitation on this
/// platform, not something fixable with more TabView styling. On a Mac whose
/// system accent isn't blue/cyan (e.g. Red), that made the very first thing
/// shown in this window render in a jarringly wrong color. Building the nav row
/// ourselves means the selected-state color is always `WavesDesign.accent`,
/// full stop — never delegated to a native control that can fall back to the
/// system preference.
struct SettingsView: View {
  @Environment(AppStore.self) private var store
  @State private var selection: SettingsPane = .general

  var body: some View {
    HStack(spacing: 0) {
      SettingsSidebar(selection: $selection)
        .frame(width: 190)

      Divider()

      paneContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    // One cyan accent everywhere — toggles, pickers, sidebar selection, primary
    // buttons — so the Settings chrome matches the app instead of rendering in
    // the user's (often clashing) system accent.
    .tint(WavesDesign.accent)
    .background(WavesBackground())
    .onDisappear {
      store.persistPreferences()
    }
  }

  @ViewBuilder
  private var paneContent: some View {
    switch selection {
    case .general: GeneralSettingsView()
    case .setup: OnboardingView()
    case .audio: AudioSettingsView()
    case .profiles: ProfileSettingsView()
    case .advanced: DiagnosticsSettingsView()
    case .help: HelpView()
    }
  }
}

/// The leading sidebar of section names. Fully custom-drawn so the selected
/// row's highlight is guaranteed to be `WavesDesign.accent`, never delegated to
/// a native list/tab control that reads the system accent color instead.
private struct SettingsSidebar: View {
  @Binding var selection: SettingsPane

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(SettingsPane.allCases) { pane in
        SettingsSidebarRow(pane: pane, isSelected: selection == pane) {
          selection = pane
        }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

private struct SettingsSidebarRow: View {
  let pane: SettingsPane
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: pane.symbol)
          .frame(width: 18)
          // Concrete Color on both arms — never wrap `.secondary` in
          // AnyShapeStyle next to a concrete color (see DesignSystem.swift);
          // that erasure silently falls back to the system accent color.
          .foregroundStyle(isSelected ? WavesDesign.accent : Color.secondary)
        Text(pane.title)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: WavesDesign.chipCornerRadius, style: .continuous)
          .fill(isSelected ? WavesDesign.accent.opacity(0.16) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    // The native TabView this replaced announced "tab, N of 6" for free;
    // restore equivalent VoiceOver discoverability on the custom row.
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityLabel("\(pane.title) settings")
    .accessibilityHint(isSelected ? "" : "Shows \(pane.title) settings.")
  }
}

/// Shared chrome for every settings pane: a grouped form whose section cards sit
/// on the Waves backdrop (hidden scroll background), so all six tabs read as one
/// coherent, native settings surface instead of six different layouts.
private struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
  }
}

private struct GeneralSettingsView: View {
  @Environment(AppStore.self) private var store
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

  var body: some View {
    SettingsForm {
      Section("Menu Bar") {
        Toggle(isOn: $showMenuBarExtra) {
          Text("Show Waves in the menu bar")
          Text("Waves keeps running either way — reopen this window from the Dock.")
        }
        Toggle(isOn: Binding(
          get: { store.launchAtLoginEnabled },
          set: { store.launchAtLoginEnabled = $0 }
        )) {
          Text("Launch at login")
          Text("Start Waves automatically when you log in.")
        }
      }

      Section("App List") {
        Toggle(isOn: pref(\.showRecentApps)) {
          Text("Show recent apps")
          Text("Include apps that recently played, not just the live ones.")
        }
        Toggle(isOn: pref(\.showSystemProcesses)) {
          Text("Show system processes")
          Text("Show macOS background audio processes in the mixer.")
        }
        Picker("Sort apps by", selection: pref(\.sortMode)) {
          ForEach(SortMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
      }

      Section("Playback") {
        Toggle(isOn: Binding(
          get: { store.preferences.autoPauseMusicForConferencing },
          set: { store.setAutoPauseMusicEnabled($0) }
        )) {
          Text("Pause media during video calls")
          Text("Mutes media apps while a known video-call app is frontmost. A heuristic — browser calls aren't detected.")
        }
        Toggle(isOn: pref(\.enablePerDeviceVolumePresets)) {
          Text("Per-device volume presets")
          Text("Remember a separate volume for each output device.")
        }
        .help("Restoring a remembered level when you switch devices also requires “Auto-restore device” to be on. Turning this off stops recording new levels but leaves any already-stored device settings in place.")
        Toggle(isOn: Binding(
          get: { store.preferences.autoRestoreDevice },
          set: { store.setAutoRestoreDeviceEnabled($0) }
        )) {
          Text("Auto-restore device")
          Text("Apply the remembered volume automatically when you switch output devices.")
        }
      }

      Section("Keyboard Shortcuts") {
        Toggle(isOn: Binding(
          get: { store.preferences.enableKeyboardShortcuts },
          set: { store.setKeyboardShortcutsEnabled($0) }
        )) {
          Text("Enable keyboard shortcuts")
          Text("Global ⌘⌥ hotkeys for the frontmost app's volume and mute.")
        }
        if store.preferences.enableKeyboardShortcuts {
          shortcutRow("Increase volume", "⌘⌥↑")
          shortcutRow("Decrease volume", "⌘⌥↓")
          shortcutRow("Toggle mute", "⌘⌥M")
        }
      }

      Section {
        Toggle(isOn: Binding(
          get: { store.preferences.enableURLScheme },
          set: {
            store.preferences.enableURLScheme = $0
            store.preferences.urlSchemeAutomationAcknowledged = true
            store.persistPreferences()
          }
        )) {
          Text("URL scheme automation")
          Text("Let other apps and links control Waves through waves:// URLs.")
        }
      } header: {
        Text("Automation")
      } footer: {
        Text("Off by default — enable only if you rely on automation.")
      }
    }
  }

  private func shortcutRow(_ title: String, _ keys: String) -> some View {
    LabeledContent(title) {
      Text(keys)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }

  /// A persisted-preference toggle/picker binding that writes the value and saves.
  private func pref<Value>(_ keyPath: WritableKeyPath<UserPreferences, Value>) -> Binding<Value> {
    Binding(
      get: { store.preferences[keyPath: keyPath] },
      set: {
        store.preferences[keyPath: keyPath] = $0
        store.persistPreferences()
      }
    )
  }
}

private struct AudioSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    SettingsForm {
      Section("Output") {
        LabeledContent("Current device", value: store.currentDeviceName)
      }

      Section {
        Text("Managed routes use Core Audio process taps to capture selected app audio, apply volume, mute, and boost, then play it back to the current output device. Audio is processed locally on this Mac.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRecovering)
      } header: {
        Text("Managed Routing")
      } footer: {
        Text("Boost is set per row in the mixer. Use 1× for transparent playback; reserve 2×–4× for quiet apps to avoid clipping.")
      }
    }
  }
}

private struct ProfileSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    SettingsForm {
      Section {
        if store.profiles.isEmpty {
          Text("No profiles yet. Create one with the + button in the main window's sidebar, or import one.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.profiles) { profile in
            ProfileRow(profile: profile)
          }
        }
      } header: {
        HStack {
          Text("Profiles")
          Spacer()
          Button {
            store.importProfiles()
          } label: {
            Label("Import", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(.borderless)
          .textCase(nil)
        }
      } footer: {
        Text("Groups of apps you switch between — optionally with saved levels.")
      }
    }
  }
}

private struct ProfileRow: View {
  @Environment(AppStore.self) private var store
  let profile: Profile

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: profile.carriesLevels ? "slider.horizontal.below.square.filled.and.square" : "square.grid.2x2")
        .foregroundStyle(WavesDesign.accent)
        .frame(width: 22)

      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Export") { store.exportProfile(profile) }
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

  private var detail: String {
    let count = profile.entries.count
    let noun = count == 1 ? "app" : "apps"
    return profile.carriesLevels ? "\(count) \(noun) · saved levels" : "\(count) \(noun) · group"
  }
}

private struct DiagnosticsSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    SettingsForm {
      Section {
        LabeledContent("Running apps", value: store.sourceInventorySummary)
        Button {
          store.copyDiagnosticsToPasteboard()
        } label: {
          Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
        }
        .disabled(store.diagnostics == nil)
        .help("Copy a plain-text route-health report to the clipboard.")
      }

      if let diagnostics = store.diagnostics {
        Section("Checks") {
          ForEach(diagnostics.checks) { check in
            DiagnosticsCheckRow(check: check)
          }
        }
      } else {
        Section {
          DiagnosticsUnavailableView()
        }
      }
    }
    .onAppear {
      store.refreshDiagnostics()
    }
  }
}

private struct DiagnosticsCheckRow: View {
  let check: DiagnosticsCheck

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Shape-differentiated glyph per status so color-blind sighted users can
      // distinguish pass/warn/fail/info by shape, not hue alone. Hidden from
      // VoiceOver; the combined label below carries the status word.
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(check.title)
        Text(check.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(statusLabel): \(check.title). \(check.detail)")
  }

  private var color: Color {
    switch check.status {
    case .passed: WavesDesign.success
    case .warning: WavesDesign.warning
    case .failed: WavesDesign.error
    case .informational: .secondary
    }
  }

  private var symbol: String {
    switch check.status {
    case .passed: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .failed: "xmark.octagon"
    case .informational: "info.circle"
    }
  }

  private var statusLabel: String {
    switch check.status {
    case .passed: "Passed"
    case .warning: "Warning"
    case .failed: "Failed"
    case .informational: "Info"
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
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Button {
          store.refreshDiagnostics()
        } label: {
          Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
        }
        .wavesGlassProminentButton()

        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "waveform.path")
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}
