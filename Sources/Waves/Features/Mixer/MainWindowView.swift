import SwiftUI
import WavesAudioCore

struct MainWindowView: View {
  @Environment(AppStore.self) private var store
  @State private var searchText = ""
  // Restored across launches so the user returns to the scope they left.
  @SceneStorage("waves.selectedScope") private var selection: SourceFilter = .running
  @State private var isPresentingSavePreset = false
  @State private var presetName = ""

  var body: some View {
    ZStack(alignment: .top) {
      NavigationSplitView {
        SidebarView(selection: $selection)
          .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
      } detail: {
        SourceListView(
          filter: selection,
          apps: filteredApps,
          searchText: searchText
        )
      }
      .navigationSplitViewStyle(.balanced)
      .searchable(text: $searchText, placement: .sidebar, prompt: "Filter apps")
      .toolbar {
        ToolbarItemGroup {
          Button {
            isPresentingSavePreset = true
          } label: {
            Image(systemName: "plus")
          }
          .help("Save preset")
          .accessibilityLabel("Save preset")
          .accessibilityHint("Opens a sheet to save the current mixer settings as a preset.")
          .keyboardShortcut("s", modifiers: [.command])

          Button {
            store.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("Refresh app list")
          .accessibilityLabel("Refresh app list")
          .accessibilityHint("Refreshes running apps and audio session state.")
          .keyboardShortcut("r", modifiers: [.command])

          Button {
            store.recoverRoutes()
          } label: {
            Image(systemName: "waveform.path")
          }
          .disabled(store.isRecovering)
          .help("Recover managed routes")
          .accessibilityLabel("Recover managed routes")
          .accessibilityHint("Reattaches active per-app audio routes.")
        }
      }

      AppToastStack()
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topTrailing)

      if store.isLoading {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Refreshing")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing, in progress")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(WavesDesign.accent.opacity(0.22))
        )
        .padding(.top, 12)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(isPresented: $isPresentingSavePreset) {
      SavePresetSheet(
        presetName: $presetName,
        onCancel: dismissPresetSheet,
        onSave: savePreset
      )
    }
    .onOpenURL { url in
      store.handleURLScheme(url)
    }
    .task {
      store.start()
    }
    .onAppear {
      store.beginLiveLevels()
      validateSelection()
    }
    .onChange(of: store.preferences.showRecentApps) { _, _ in
      validateSelection()
    }
    .onDisappear { store.endLiveLevels() }
  }

  /// A persisted `.recent` scope (via @SceneStorage) can be restored after the
  /// user has turned "Show recent apps" off, stranding the window on a
  /// permanently-empty, misleadingly-worded Recent view. Fall back to .running
  /// whenever the restored/current scope is unavailable.
  private func validateSelection() {
    if selection == .recent && !store.preferences.showRecentApps {
      selection = .running
    }
  }

  private var scopedApps: [AudioApp] {
    switch selection {
    case .running:
      store.visibleApps
    case .pinned:
      store.pinnedApps
    case .frontmost:
      store.liveApps
    case .recent:
      store.recentApps
    }
  }

  private var filteredApps: [AudioApp] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return scopedApps }

    // Limit search query length to prevent performance issues
    let maxSearchLength = 100
    let boundedQuery = String(query.prefix(maxSearchLength))

    // When searching, look across ALL visible apps rather than just the selected
    // scope, so a query never silently hides a matching app that happens to live
    // in another section.
    return store.visibleApps.filter { app in
      app.displayName.localizedCaseInsensitiveContains(boundedQuery)
        || app.category.displayName.localizedCaseInsensitiveContains(boundedQuery)
    }
  }

  private func dismissPresetSheet() {
    presetName = ""
    isPresentingSavePreset = false
  }

  private func savePreset() {
    let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Validate preset name length
    let maxLength = 100
    guard trimmed.count <= maxLength else { return }

    store.savePreset(named: trimmed)
    dismissPresetSheet()
  }
}

private enum SourceFilter: String, CaseIterable, Identifiable {
  case running
  case pinned
  case frontmost
  case recent

  var id: Self { self }

  var title: String {
    switch self {
    case .running:
      "Running"
    case .pinned:
      "Pinned"
    case .frontmost:
      "Live"
    case .recent:
      "Recent"
    }
  }

  @MainActor
  func count(in store: AppStore) -> Int {
    switch self {
    case .running:
      store.visibleApps.count
    case .pinned:
      store.pinnedApps.count
    case .frontmost:
      store.liveApps.count
    case .recent:
      store.recentApps.count
    }
  }

  func detail(count: Int) -> String {
    let label: String
    switch self {
    case .running:
      label = count == 1 ? "running app" : "running apps"
    case .pinned:
      label = count == 1 ? "pinned app" : "pinned apps"
    case .frontmost:
      label = count == 1 ? "live app" : "live apps"
    case .recent:
      label = count == 1 ? "recent app" : "recent apps"
    }

    return "\(count) \(label)"
  }

  var systemImage: String {
    switch self {
    case .running:
      "square.stack.3d.up.fill"
    case .pinned:
      "pin.fill"
    case .frontmost:
      "waveform"
    case .recent:
      "clock.fill"
    }
  }

  var emptyTitle: String {
    switch self {
    case .running:
      "No Running Apps"
    case .pinned:
      "No Pinned Apps"
    case .frontmost:
      "No Live Apps"
    case .recent:
      "No Recent Apps"
    }
  }

  func emptyMessage(searchText: String) -> String {
    if !searchText.isEmpty {
      return "Try a different search term."
    }

    switch self {
    case .running:
      return "Waves hasn't found any running apps yet."
    case .pinned:
      return "Pin apps from the source list to keep them here."
    case .frontmost:
      return "Start playback in an app, then refresh if it does not appear here."
    case .recent:
      return "Apps appear here when they're not actively playing audio."
    }
  }
}

private struct SidebarView: View {
  @Environment(AppStore.self) private var store
  @Binding var selection: SourceFilter

  var body: some View {
    List(selection: $selection) {
      Section("Sources") {
        ForEach(availableFilters) { filter in
          SourceFilterRow(
            filter: filter,
            countText: filter.detail(count: filter.count(in: store))
          )
          .tag(filter)
        }
      }

      if !store.presets.isEmpty {
        Section("Presets") {
          ForEach(store.presets) { preset in
            Button {
              store.applyPreset(preset)
            } label: {
              HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3")
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                  Text(preset.name)
                    .lineLimit(1)
                  Text("\(preset.entries.count) \(preset.entries.count == 1 ? "app" : "apps")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Delete Preset", role: .destructive) {
                if let index = store.presets.firstIndex(where: { $0.id == preset.id }) {
                  store.deletePresets(at: IndexSet(integer: index))
                }
              }
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Waves")
  }

  /// Mirrors the menu bar: the Recent scope is only offered when the user has
  /// opted into recent apps, so the sidebar never shows a permanently-empty,
  /// non-selectable Recent row.
  private var availableFilters: [SourceFilter] {
    SourceFilter.allCases.filter { filter in
      filter != .recent || store.preferences.showRecentApps
    }
  }
}

private struct SourceFilterRow: View {
  let filter: SourceFilter
  let countText: String

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: filter.systemImage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text(filter.title)
          .lineLimit(1)
        Text(countText)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

private struct SourceListView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openSettings) private var openSettings
  @State private var selectedAppID: AudioApp.ID?
  let filter: SourceFilter
  let apps: [AudioApp]
  let searchText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      OutputSummaryView(filter: filter, visibleCount: apps.count)

      // Suppress the empty state during the first scan so the window never
      // tells the user it is "Refreshing" (the pill in MainWindowView) and that
      // nothing was found at the same time. Mirrors the menu bar's gating.
      if apps.isEmpty && !store.isLoading {
        VStack(spacing: 14) {
          ContentUnavailableView(
            emptyTitle,
            systemImage: "speaker.slash",
            description: Text(emptyMessage)
          )

          HStack(spacing: 10) {
            Button {
              store.refresh()
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)

            Button {
              openSettings()
            } label: {
              Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
          }
        }
        Spacer(minLength: 0)
      } else {
        List(selection: $selectedAppID) {
          ForEach(apps) { app in
            MixerRowView(app: app)
              .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18))
              .listRowBackground(Color.clear)
              .tag(app.id)
          }
          .onMove { source, destination in
            // Only reorder against the full unfiltered list; a search shows a
            // subset whose indices would not map back correctly. Shares the same
            // trimmed condition as `isReorderable` so the guard and the affordance
            // gating never disagree.
            if isReorderable {
              store.reorderApps(from: source, to: destination)
            }
          }
          .moveDisabled(!isReorderable)
        }
        .listStyle(.inset)
        // Keyboard operation: arrow keys move the selection (List), and these
        // keys act on the selected row so the mixer is fully drivable without a
        // mouse — including muting, which the borderless button can't reach.
        .onKeyPress(.space) { handleKey { store.setMuted(!$0.isMuted, for: $0) } }
        .onKeyPress("m") { handleKey { store.setMuted(!$0.isMuted, for: $0) } }
        .onKeyPress("=") { handleKey { nudgeVolume($0, by: 0.05) } }
        .onKeyPress("-") { handleKey { nudgeVolume($0, by: -0.05) } }
        .onKeyPress("b") { handleKey { cycleBoost($0) } }
        .onKeyPress("p") { handleKey { store.togglePinned($0) } }
        // Jump straight to playing apps or apps needing attention.
        .accessibilityRotor("Playing apps") {
          ForEach(apps.filter { store.liveApps.contains($0) }) { app in
            AccessibilityRotorEntry(app.displayName, id: app.id)
          }
        }
        .accessibilityRotor("Needs attention") {
          // Stay within the rendered rows (current scope + active search), like
          // the sibling "Playing apps" rotor. Enumerating cross-scope apps would
          // yield entries whose ids have no rendered row, so selecting them would
          // move VoiceOver focus to a nonexistent element (a silent no-op).
          ForEach(apps.filter { $0.routingState == .error }) { app in
            AccessibilityRotorEntry(app.displayName, id: app.id)
          }
        }
      }

      DiagnosticsPanel()
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  /// True when the Running scope is empty only because system processes are
  /// being filtered out (apps were detected, just hidden by the preference).
  private var systemProcessesHidden: Bool {
    filter == .running
      && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !store.preferences.showSystemProcesses
      && store.session.apps.contains { $0.category == .system }
  }

  private var emptyTitle: String {
    systemProcessesHidden ? "System Processes Hidden" : filter.emptyTitle
  }

  private var emptyMessage: String {
    if systemProcessesHidden {
      return "System processes are hidden. Enable Show system processes in Settings to see them."
    }
    return filter.emptyMessage(searchText: searchText)
  }

  /// True whenever a drag would map back to the full list correctly, so the OS
  /// never presents a drag handle that would silently snap back elsewhere.
  /// Deliberately does NOT require `.manual` sort: a first drag from Name/
  /// Activity/Category is a documented way to convert the list to manual
  /// ordering (reorderApps auto-switches sortMode and snapshots the displayed
  /// order before switching, so the dragged row still lands correctly). Only
  /// scope and an active search block reorder, because a search shows a subset
  /// whose indices would not map back to the unfiltered list.
  /// Uses the trimmed query to match `filteredApps`, so a whitespace-only
  /// search (which filters nothing) does not block reorder.
  private var isReorderable: Bool {
    filter == .running
      && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Runs `action` on the currently selected row, if any.
  ///
  /// These are focused-window "app shortcuts," which the Help copy promises
  /// always work while a Waves window is focused. They are intentionally NOT
  /// gated on `preferences.enableKeyboardShortcuts` — that toggle governs the
  /// global ⌘⌥ hotkeys (the NSEvent monitor), not in-list keys. Gating here
  /// would silently strip keyboard control of the mixer (including the only
  /// keyboard mute path) whenever a user disables global hotkeys.
  private func handleKey(_ action: (AudioApp) -> Void) -> KeyPress.Result {
    guard let id = selectedAppID, let app = apps.first(where: { $0.id == id }) else {
      return .ignored
    }
    action(app)
    return .handled
  }

  private func nudgeVolume(_ app: AudioApp, by delta: Float) {
    let next = max(0, min(1, app.desiredVolume + delta))
    store.setDesiredVolume(next, for: app)
    store.commitDesiredVolume(for: app)
  }

  private func cycleBoost(_ app: AudioApp) {
    let next = app.volumeBoost >= 4 ? 1 : (app.volumeBoost + 1).rounded()
    store.setVolumeBoost(next, for: app)
  }
}

private struct OutputSummaryView: View {
  @Environment(AppStore.self) private var store
  let filter: SourceFilter
  let visibleCount: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "speaker.wave.2.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .background(.tertiary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 1) {
        Text(store.currentDeviceName)
          .font(.headline.weight(.semibold))
          .lineLimit(1)

        HStack(spacing: 8) {
          Text(filter.detail(count: visibleCount))
            .foregroundStyle(.secondary)

          if let liveSummary {
            Label(liveSummary, systemImage: "waveform")
              .foregroundStyle(WavesDesign.accent)
          }
        }
        .font(.caption)
        .lineLimit(1)
      }

      Spacer(minLength: 12)

      RouteHealthBadge()
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(Divider(), alignment: .bottom)
  }

  private var liveSummary: String? {
    let liveApps = store.liveApps.prefix(3).map(\.displayName)
    guard !liveApps.isEmpty else { return nil }

    let names = liveApps.joined(separator: ", ")
    let overflow = store.liveApps.count - liveApps.count
    return overflow > 0 ? "\(names) +\(overflow) playing" : "\(names) playing"
  }
}

private struct RouteHealthBadge: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
      .help(helpText)
      .accessibilityLabel(helpText)
  }

  private var title: String {
    if store.session.backendStatus.isRouteRecoveryHealthy {
      return "Ready"
    }
    if store.session.backendStatus.lastError != nil {
      return "Needs attention"
    }
    return "Limited"
  }

  private var systemImage: String {
    if store.session.backendStatus.isRouteRecoveryHealthy {
      return "checkmark.circle.fill"
    }
    if store.session.backendStatus.lastError != nil {
      return "exclamationmark.triangle.fill"
    }
    return "exclamationmark.circle"
  }

  private var color: Color {
    if store.session.backendStatus.isRouteRecoveryHealthy {
      return .green
    }
    if store.session.backendStatus.lastError != nil {
      return .red
    }
    return .secondary
  }

  private var helpText: Text {
    Text("Routing status: \(title)")
  }
}

private struct DiagnosticsPanel: View {
  @Environment(AppStore.self) private var store
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()

      DisclosureGroup(isExpanded: $expanded) {
        if let diagnostics = store.diagnostics {
          VStack(alignment: .leading, spacing: 10) {
            Text(diagnostics.summary)
              .font(.caption)
              .foregroundStyle(.secondary)

            ForEach(diagnostics.checks) { check in
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                  // Shape-differentiated glyph per status so color-blind sighted
                  // users can distinguish pass/warn/fail/info by shape, not hue
                  // alone. Still hidden from VoiceOver; the combined label below
                  // carries the status word.
                  Image(systemName: symbol(for: check.status))
                    .font(.caption)
                    .foregroundStyle(color(for: check.status))
                    .accessibilityHidden(true)
                  Text(check.title)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(statusLabel(for: check.status)): \(check.title)")

                Text(check.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.leading, 15)
              }
            }
          }
          .padding(.top, 10)
        } else {
          Text("Diagnostics not available yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 10)
        }
      } label: {
        Text("Diagnostics")
          .font(.callout.weight(.semibold))
      }
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

private struct SavePresetSheet: View {
  // Shared with AppStore.savePreset()'s defensive length guard. Mirrored in the
  // Save button's .disabled() so an over-length name (easy via paste) disables
  // the control instead of leaving a silent no-op Save.
  static let maxNameLength = 100

  @Binding var presetName: String
  let onCancel: () -> Void
  let onSave: () -> Void

  private var trimmedName: String {
    presetName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isTooLong: Bool {
    trimmedName.count > Self.maxNameLength
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Save Preset")
        .font(.title3.weight(.semibold))

      TextField("Preset name", text: $presetName)
        .textFieldStyle(.roundedBorder)

      if isTooLong {
        Text("Name too long (max \(Self.maxNameLength) characters)")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()

        Button("Cancel", action: onCancel)

        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
          .disabled(trimmedName.isEmpty || isTooLong)
      }
    }
    .padding(20)
    .frame(width: 320)
  }
}
