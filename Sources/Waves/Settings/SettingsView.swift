import SwiftUI
import WavesAudioCore

/// One case per settings pane. Order here drives the sidebar's top-to-bottom
/// order, so reordering panes is a one-line change.
private enum SettingsPane: String, CaseIterable, Identifiable {
  case general, mixer, profiles, control, setup, advanced, help

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .mixer: "Mixer"
    case .profiles: "Profiles"
    case .control: "Shortcuts"
    case .setup: "Setup"
    case .advanced: "Advanced"
    case .help: "Help"
    }
  }

  /// One-line answer to "what's in here", shown under the title in the
  /// sidebar so nobody has to click through panes to find a setting.
  var subtitle: String {
    switch self {
    case .general: "Appearance, menu bar, updates"
    case .mixer: "App list and volume memory"
    case .profiles: "Saved mixes and startup"
    case .control: "Keys and automation"
    case .setup: "Permissions and repair"
    case .advanced: "Diagnostics"
    case .help: "Guide"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .mixer: "slider.horizontal.3"
    case .profiles: "rectangle.stack"
    case .control: "keyboard"
    case .setup: "checklist"
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
  @Environment(\.wavesTheme) private var theme
  @State private var selection: SettingsPane = .general

  var body: some View {
    HStack(spacing: 0) {
      SettingsSidebar(selection: $selection)
        .frame(width: 200)

      Divider()

      paneContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    // One cyan accent everywhere — toggles, pickers, sidebar selection, primary
    // buttons — so the Settings chrome matches the app instead of rendering in
    // the user's (often clashing) system accent.
    .tint(theme.accent)
    .background(WavesBackground())
    .onDisappear {
      store.persistPreferences()
    }
  }

  @ViewBuilder
  private var paneContent: some View {
    switch selection {
    case .general: GeneralSettingsView()
    case .mixer: MixerSettingsView()
    case .profiles: ProfileSettingsView()
    case .control: ControlSettingsView()
    case .setup: SetupRepairView()
    case .advanced: DiagnosticsSettingsView(onOpenSetup: { selection = .setup })
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
  @Environment(\.wavesTheme) private var theme
  let pane: SettingsPane
  let isSelected: Bool

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(pane.title)
          .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        Text(pane.subtitle)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: pane.symbol)
        .foregroundStyle(theme.accentOrSecondary(isSelected))
    }
    .accessibilityLabel("\(pane.title) settings, \(pane.subtitle)")
  }
}

/// Shared chrome for every settings pane: a grouped form whose section cards sit
/// on the Waves backdrop (hidden scroll background), so all tabs read as one
/// coherent, native settings surface instead of different layouts.
private struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
  }
}

// MARK: - General

private struct GeneralSettingsView: View {
  @Environment(AppStore.self) private var store
  @Environment(UpdaterService.self) private var updaterService
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

  var body: some View {
    SettingsForm {
      Section("Appearance") {
        Picker("Appearance", selection: pref(\.appearance)) {
          ForEach(WavesAppearance.allCases) { appearance in
            Text(appearance.displayName).tag(appearance)
          }
        }

        Picker("Palette", selection: pref(\.palette)) {
          ForEach(WavesPalette.allCases) { palette in
            Text(palette.displayName).tag(palette)
          }
        }
        .help("The color family Waves uses. Both palettes work in light and dark appearance.")
      }

      Section("Menu Bar & Login") {
        Toggle(isOn: $showMenuBarExtra) {
          Text("Show Waves in the menu bar")
          Text("Waves keeps running either way. Reopen this window from the Dock.")
        }
        Toggle(
          isOn: Binding(
            get: { store.launchAtLoginEnabled },
            set: { store.launchAtLoginEnabled = $0 }
          )
        ) {
          Text("Launch at login")
          Text("Start Waves automatically when you log in.")
        }
        if store.launchAtLoginRequiresApproval {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
              "Needs your approval in System Settings > General > Login Items.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(WavesDesign.warning)
            Button("Open Login Items") {
              store.openLoginItemsSettings()
            }
            .font(.caption)
          }
        }
      }

      SettingsUpdatesSection()
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

/// The Updates section, shared verbatim between Settings > General and the
/// About window so version and update state read the same everywhere.
struct SettingsUpdatesSection: View {
  @Environment(UpdaterService.self) private var updaterService

  var body: some View {
    Section {
      LabeledContent("Version") {
        HStack(spacing: 10) {
          Text(AppVersion.display)
            .foregroundStyle(.secondary)
          Button("Check for Updates…") {
            updaterService.checkForUpdates()
          }
          .disabled(!updaterService.canCheckForUpdates)
        }
      }

      Toggle(
        isOn: Binding(
          get: { updaterService.automaticallyChecksForUpdates },
          set: { updaterService.automaticallyChecksForUpdates = $0 }
        )
      ) {
        Text("Check for updates automatically")
        Text("Sparkle asks once before the first automatic check.")
      }

      LabeledContent("Release notes") {
        Link("waves.jonathanrreed.com", destination: URL(string: "https://waves.jonathanrreed.com")!)
          .font(.callout)
      }
    } header: {
      Text("Updates")
    } footer: {
      Text(
        "A check downloads the signed update feed from waves.jonathanrreed.com and nothing else. Waves makes no network requests until you check or turn on automatic checks."
      )
    }
  }
}

/// Reads the app's version once. "1.3.0 (6)" in a packaged build,
/// "Development" from `swift run`.
enum AppVersion {
  static var short: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  static var build: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
  }

  static var display: String {
    if let build { return "\(short) (\(build))" }
    return short
  }
}

// MARK: - Mixer

private struct MixerSettingsView: View {
  @Environment(AppStore.self) private var store
  @State private var confirmingClearPresets = false

  var body: some View {
    SettingsForm {
      Section {
        Toggle(isOn: pref(\.showRecentApps)) {
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
        Toggle(isOn: pref(\.showSystemProcesses)) {
          Text("Show system processes")
          Text("Include macOS background audio processes in the mixer.")
        }
        Picker("Sort apps by", selection: pref(\.sortMode)) {
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
        Toggle(isOn: pref(\.enablePerDeviceVolumePresets)) {
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

// MARK: - Profiles

private struct ProfileSettingsView: View {
  @Environment(AppStore.self) private var store
  // Presenting the same ProfileEditorSheet MainWindowView's sidebar "+"/"Edit
  // Profile…" use — this pane used to only hint at using that sidebar instead
  // of offering the action itself.
  @State private var editorContext: ProfileEditorContext?

  var body: some View {
    SettingsForm {
      Section {
        Picker(
          "Apply at startup",
          selection: Binding(
            get: { store.preferences.defaultProfileID },
            set: { id in
              store.setDefaultProfile(id.flatMap { id in store.profiles.first { $0.id == id } })
            }
          )
        ) {
          Text("None").tag(UUID?.none)
          ForEach(store.profiles.filter(\.carriesLevels)) { profile in
            Text(profile.name).tag(UUID?.some(profile.id))
          }
        }
        .disabled(!store.profiles.contains(where: \.carriesLevels))
      } header: {
        Text("Startup")
      } footer: {
        Text(
          store.profiles.contains(where: \.carriesLevels)
            ? "Waves applies this profile's saved levels every time it starts, so your baseline mix is always in place."
            : "Save a profile with captured levels first, then pick it here to have Waves apply it at startup."
        )
      }

      Section {
        if store.profiles.isEmpty {
          Text("No profiles yet. Create one here, or import one.")
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
        Text(
          "A profile is a group of apps, optionally with saved levels. Apply one before a meeting or a game, then use Reset Mix in the main window to put everything back."
        )
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
    editorContext = ProfileEditorContext(
      profile: nil, preselectedAppIDs: store.liveApps.map(\.logicalID))
  }

  private func presentEditProfile(_ profile: Profile) {
    editorContext = ProfileEditorContext(profile: profile, preselectedAppIDs: profile.appIDs)
  }
}

private struct ProfileRow: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  let profile: Profile
  let onEdit: () -> Void
  // Deleting a profile discards a hand-tuned captured mix with no undo, so the
  // one-click borderless button (right beside Export) asks first.
  @State private var confirmingDelete = false

  var body: some View {
    HStack(spacing: 10) {
      Image(
        systemName: profile.carriesLevels
          ? "slider.horizontal.below.square.filled.and.square" : "square.grid.2x2"
      )
      .foregroundStyle(theme.accent)
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
        Text(
          "This removes \(profile.name)\(profile.carriesLevels ? " and its saved levels" : "") from your profiles. This can't be undone."
        )
      }
    }
  }

  private var detail: String {
    let count = profile.entries.count
    let noun = count == 1 ? "app" : "apps"
    var text = profile.carriesLevels ? "\(count) \(noun) · saved levels" : "\(count) \(noun) · group"
    if store.preferences.defaultProfileID == profile.id {
      text += " · applied at startup"
    }
    return text
  }
}

// MARK: - Shortcuts & automation

private struct ControlSettingsView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    SettingsForm {
      Section {
        Toggle(
          isOn: Binding(
            get: { store.preferences.enableKeyboardShortcuts },
            set: { store.setKeyboardShortcutsEnabled($0) }
          )
        ) {
          Text("Enable keyboard shortcuts")
          Text("Control the app in front from anywhere, no need to open Waves first.")
        }
        .disabled(!store.isAudioRunning)
        if store.preferences.enableKeyboardShortcuts {
          shortcutRow("Increase volume", "⌘⌥↑")
          shortcutRow("Decrease volume", "⌘⌥↓")
          shortcutRow("Toggle mute", "⌘⌥M")
        }
      } header: {
        Text("Global Shortcuts")
      } footer: {
        Text(
          "These shortcuts act on the frontmost app. The key listener only exists while this is on, and Waves ignores every key except its own ⌘⌥ shortcuts."
        )
      }

      Section {
        Toggle(
          isOn: Binding(
            get: { store.preferences.enableURLScheme },
            set: {
              store.preferences.enableURLScheme = $0
              store.preferences.urlSchemeAutomationAcknowledged = true
              store.persistPreferences()
            }
          )
        ) {
          Text("URL scheme automation")
          Text("Lets other apps and links send waves:// commands, like setting a volume or applying a profile.")
        }
        .disabled(!store.isAudioRunning)
      } header: {
        Text("Automation")
      } footer: {
        Text(
          "Off by default. Turn it on only for automation you trust, and turn it back off when you're done. In the main window, keyboard control also works without this: arrow keys select an app, Space mutes, = and - adjust volume."
        )
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
}

// MARK: - Advanced

private struct DiagnosticsSettingsView: View {
  @Environment(AppStore.self) private var store
  let onOpenSetup: () -> Void

  var body: some View {
    SettingsForm {
      Section {
        LabeledContent("Current device", value: store.currentDeviceName)
        if let kind = store.session.currentDevice?.kind {
          LabeledContent("Device type", value: kind.displayName)
        }
        LabeledContent("Running apps", value: store.sourceInventorySummary)
      } header: {
        Text("Audio")
      } footer: {
        Text(
          "Waves captures each managed app's audio with a Core Audio process tap, applies your volume, mute, boost, and EQ, and plays it to the output device. Everything is processed on this Mac."
        )
      }

      Section {
        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "arrow.clockwise")
        }
        .disabled(!store.isAudioRunning || store.isRecovering)
        .help("Reattaches per-app audio routes. Try this if volume or mute stops working for an app.")
        Button {
          onOpenSetup()
        } label: {
          Label("Open Setup & Repair", systemImage: "wrench.and.screwdriver")
        }
        Button {
          store.copyDiagnosticsToPasteboard()
        } label: {
          Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
        }
        .disabled(store.diagnostics == nil)
        .help("Copies a plain-text route health report for a bug report.")
      } header: {
        Text("Repair")
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
      // Settings panes are switched by destroying/recreating view identity
      // (see SettingsView.paneContent), not by a native TabView that keeps
      // inactive tabs alive — so onAppear fires every time this pane is
      // revisited, not just once. Diagnostics already has its own explicit
      // "Refresh Diagnostics" action for re-probing on demand, so only
      // auto-refresh the first time there's nothing to show yet; don't redo
      // the backend snapshot rebuild + capture-permission re-probe on every
      // tab click.
      if store.isAudioRunning, store.diagnostics == nil {
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

      Text(
        store.session.backendStatus.lastError
          ?? "Refresh diagnostics to check permissions, route recovery, and app support."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        Button {
          store.refreshDiagnostics()
        } label: {
          Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
        }
        .wavesGlassProminentButton()
        .disabled(!store.isAudioRunning)

        Button {
          store.recoverRoutes()
        } label: {
          Label("Recover Routes", systemImage: "waveform.path")
        }
        .buttonStyle(.bordered)
        .disabled(!store.isAudioRunning || store.isRecovering)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }
}
