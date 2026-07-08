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

/// The leading sidebar of section names. A native `List(selection:)` — exactly
/// the mechanism MainWindowView's own sidebar uses — so arrow-key navigation,
/// VoiceOver row/selection semantics, and standard focus traversal all come
/// for free from the system, while the row's own icon/label colors stay
/// concrete `Color` values (never a hierarchical style erased through
/// `AnyShapeStyle`, see the note in DesignSystem.swift) so the selected state
/// is always `WavesDesign.accent`, never the system accent color.
private struct SettingsSidebar: View {
  @Binding var selection: SettingsPane

  var body: some View {
    List(selection: $selection) {
      ForEach(SettingsPane.allCases) { pane in
        SettingsSidebarRow(pane: pane, isSelected: selection == pane)
          .tag(pane)
      }
    }
    .listStyle(.sidebar)
    // Let the WavesBackground() gradient behind the whole window show through,
    // same as SettingsForm's grouped Form elsewhere in this file, instead of
    // List's own opaque system list background.
    .scrollContentBackground(.hidden)
  }
}

private struct SettingsSidebarRow: View {
  let pane: SettingsPane
  let isSelected: Bool

  var body: some View {
    Label {
      Text(pane.title)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
    } icon: {
      Image(systemName: pane.symbol)
        .foregroundStyle(WavesDesign.accentOrSecondary(isSelected))
    }
    .accessibilityLabel("\(pane.title) settings")
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
        if store.launchAtLoginRequiresApproval {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Needs approval in System Settings > General > Login Items.", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(WavesDesign.warning)
            Button("Open Login Items") {
              store.openLoginItemsSettings()
            }
            .font(.caption)
          }
        }
      }

      Section {
        Toggle(isOn: pref(\.showRecentApps)) {
          Text("Show recent apps")
          Text("Include apps that recently played, not just the live ones.")
        }
        Picker("Keep quiet apps in Live", selection: Binding(
          get: { store.preferences.liveListLinger },
          set: { store.setLiveListLinger($0) }
        )) {
          ForEach(LiveListLinger.allCases) { option in
            Text(option.displayName).tag(option)
          }
        }
        .help("Controls how long a just-silent app stays in Live before moving to Recent.")
        Toggle(isOn: pref(\.showSystemProcesses)) {
          Text("Show system processes")
          Text("Show macOS background audio processes in the mixer.")
        }
        Picker("Sort apps by", selection: pref(\.sortMode)) {
          ForEach(SortMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
      } header: {
        Text("App List")
      } footer: {
        Text("Use Brief if Live feels sticky. Use Relaxed if apps disappear during pauses or track changes.")
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
          Text("Installs a system-wide key listener only while enabled; Waves ignores everything except its ⌘⌥ shortcuts.")
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
          Text("Lets other apps, browsers, and links send supported waves:// commands to Waves.")
        }
      } header: {
        Text("Automation")
      } footer: {
        Text("Off by default. Enable only for automation you trust, then turn it off when you no longer need it.")
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
  @State private var confirmingClearPresets = false

  var body: some View {
    SettingsForm {
      Section("Output") {
        LabeledContent("Current device", value: store.currentDeviceName)
        if let kind = store.session.currentDevice?.kind {
          LabeledContent("Type", value: kind.displayName)
        }
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

      Section {
        LabeledContent("Saved for this device", value: "\(currentDevicePresetCount) \(currentDevicePresetCount == 1 ? "app" : "apps")")
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
          Text("Removes the remembered volume, mute, and boost per app for every output device. This can't be undone.")
        }
      } header: {
        Text("Per-Device Volume Presets")
      } footer: {
        Text("When \"Per-device volume presets\" is on (General), Waves remembers each app's level per output device and reapplies it when you switch back.")
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
}

private struct ProfileSettingsView: View {
  @Environment(AppStore.self) private var store
  // Presenting the same ProfileEditorSheet MainWindowView's sidebar "+"/"Edit
  // Profile…" use — this pane used to only hint at using that sidebar instead
  // of offering the action itself.
  @State private var editorContext: ProfileEditorContext?

  var body: some View {
    SettingsForm {
      Section {
        if store.profiles.isEmpty {
          Text("No profiles yet. Create one below, or import one.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(store.profiles) { profile in
            ProfileRow(profile: profile, onEdit: { presentEditProfile(profile) })
          }
        }
      } header: {
        HStack {
          Text("Profiles")
          Spacer()
          Button {
            presentNewProfile()
          } label: {
            Label("New Profile", systemImage: "plus")
          }
          .buttonStyle(.borderless)
          .textCase(nil)

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
    .sheet(item: $editorContext) { context in
      ProfileEditorSheet(context: context)
        .environment(store)
    }
  }

  private func presentNewProfile() {
    // Mirrors MainWindowView.presentNewProfile: seed with whatever is
    // currently playing, the most common starting set.
    editorContext = ProfileEditorContext(profile: nil, preselectedAppIDs: store.liveApps.map(\.logicalID))
  }

  private func presentEditProfile(_ profile: Profile) {
    editorContext = ProfileEditorContext(profile: profile, preselectedAppIDs: profile.appIDs)
  }
}

private struct ProfileRow: View {
  @Environment(AppStore.self) private var store
  let profile: Profile
  let onEdit: () -> Void
  // Deleting a profile discards a hand-tuned captured mix with no undo, so the
  // one-click borderless button (right beside Export) asks first.
  @State private var confirmingDelete = false

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

      Button("Edit…") { onEdit() }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Edit profile \(profile.name)")

      Button("Export") { store.exportProfile(profile) }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Export profile \(profile.name)")

      Button("Delete…", role: .destructive) {
        confirmingDelete = true
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .accessibilityLabel("Delete profile \(profile.name)")
      .confirmationDialog(
        "Delete “\(profile.name)”?",
        isPresented: $confirmingDelete,
        titleVisibility: .visible
      ) {
        Button("Delete Profile", role: .destructive) {
          if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.deleteProfiles(at: IndexSet(integer: index))
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes \(profile.name)\(profile.carriesLevels ? " and its saved levels" : "") from your profiles. This can't be undone.")
      }
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
      // Settings panes are now switched by destroying/recreating view identity
      // (see SettingsView.paneContent), not by a native TabView that keeps
      // inactive tabs alive — so onAppear fires every time this pane is
      // revisited, not just once. Diagnostics already has its own explicit
      // "Refresh Diagnostics" action for re-probing on demand, so only
      // auto-refresh the first time there's nothing to show yet; don't redo
      // the backend snapshot rebuild + capture-permission re-probe on every
      // tab click.
      if store.diagnostics == nil {
        store.refreshDiagnostics()
      }
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
      Image(systemName: check.status.symbolName)
        .foregroundStyle(check.status.color)
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
    .accessibilityLabel("\(check.status.statusWord): \(check.title). \(check.detail)")
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
