import SwiftUI
import WavesAudioCore

/// One case per settings pane. Order here drives the sidebar's top-to-bottom
/// order, so reordering panes is a one-line change.
/// Internal (not private) so another scene can ask Settings to open on a
/// specific pane — the Help menu item in particular, which used to open this
/// window on General and leave the user to find Help themselves.
enum SettingsPane: String, CaseIterable, Identifiable {
  case general, mixer, profiles, control, setup, diagnostics, help

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .mixer: "Mixer"
    case .profiles: "Profiles"
    case .control: "Shortcuts & Automation"
    case .setup: "Setup"
    case .diagnostics: "Diagnostics"
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
    case .diagnostics: "Diagnostics"
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
    case .diagnostics: "waveform.path.ecg"
    case .help: "questionmark.circle"
    }
  }

  var accessibilityLabel: String {
    "\(title) settings, \(subtitle)"
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
  @State private var workspace = SettingsWorkspace()

  init(initialPane: SettingsPane = .general) {
    _workspace = State(initialValue: SettingsWorkspace(selection: initialPane))
  }

  init(workspace: SettingsWorkspace) {
    _workspace = State(initialValue: workspace)
  }

  var body: some View {
    @Bindable var workspace = workspace
    HStack(spacing: 0) {
      SettingsSidebar(selection: $workspace.selection)
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
    // Covers the case where this window had to be created by the request (it
    // was closed), so the `onChange` below never sees the token move.
    .onAppear { applyRequestedPaneIfAny() }
    .onChange(of: store.settingsPaneToken) { _, _ in
      applyRequestedPaneIfAny()
    }
    .onChange(of: workspace.selection) { oldPane, newPane in
      if oldPane == .control, newPane != .control {
        workspace.controlDraft.beginPaneReplacement()
      }
    }
    .onDisappear {
      if workspace.controlDraft.cancelRecording() {
        store.setHotkeysSuspended(false)
      }
      store.persistPreferences()
    }
  }

  private func applyRequestedPaneIfAny() {
    if let pane = store.consumeSettingsPaneRequest() {
      workspace.selection = pane
    }
  }

  @ViewBuilder
  private var paneContent: some View {
    switch workspace.selection {
    case .general: GeneralSettingsView()
    case .mixer: MixerSettingsView()
    case .profiles: ProfileSettingsView()
    case .control: ControlSettingsView(draft: workspace.controlDraft)
    case .setup: SetupRepairView()
    case .diagnostics: DiagnosticsSettingsView(onOpenSetup: { workspace.selection = .setup })
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
struct SettingsSidebar: View {
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
    .focusable()
    .onKeyPress(.downArrow) { moveSelection(by: 1) }
    .onKeyPress(.upArrow) { moveSelection(by: -1) }
  }

  private func moveSelection(by offset: Int) -> KeyPress.Result {
    guard let index = SettingsPane.allCases.firstIndex(of: selection) else { return .ignored }
    let nextIndex = min(max(index + offset, SettingsPane.allCases.startIndex), SettingsPane.allCases.index(before: SettingsPane.allCases.endIndex))
    guard nextIndex != index else { return .ignored }
    selection = SettingsPane.allCases[nextIndex]
    return .handled
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
    .accessibilityLabel(pane.accessibilityLabel)
  }
}

/// Shared chrome for every settings pane: a grouped form whose section cards sit
/// on the Waves backdrop (hidden scroll background), so all tabs read as one
/// coherent, native settings surface instead of different layouts.
struct SettingsForm<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
  }
}
