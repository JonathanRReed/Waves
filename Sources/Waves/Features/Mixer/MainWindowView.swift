import SwiftUI
import WavesAudioCore

struct MainWindowView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @State private var searchText = ""
  // Restored across launches so the user returns to the scope they left.
  @SceneStorage("waves.selectedScope") private var selection: MixerScope = .source(.running)
  @State private var editorContext: ProfileEditorContext?

  var body: some View {
    ZStack(alignment: .top) {
      primarySurface

      AppToastStack()
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .topTrailing)

      if store.isLoading && store.privacySetupPresentationState == .hidden {
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.22)))
        .padding(.top, 12)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
    .background(WavesBackground())
    .sheet(item: $editorContext) { context in
      ProfileEditorSheet(context: context)
        .environment(store)
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
      // Covers the case where the menu bar's "N more in Waves" link had to
      // create this window from scratch (it was closed): the request was
      // already made before openWindow, so this fresh view's onChange below
      // never sees it change. If the window was already open and alive, this
      // is a no-op (onChange already consumed it).
      if let filter = store.consumeSourceFocusRequest() {
        selection = .source(filter)
      }
      handleEqualizerFocusRequest()
    }
    .onChange(of: store.preferences.showRecentApps) { _, _ in
      validateSelection()
    }
    .onChange(of: store.profiles.map(\.id)) { _, _ in
      // The profile currently shown in the detail pane may have just been
      // deleted or renamed; fall back to Running if the selection no longer
      // resolves rather than stranding an empty, mislabeled pane.
      validateSelection()
    }
    .onChange(of: store.profileFocusToken) { _, _ in
      // Applying or selecting a profile (including re-applying the already-active
      // one from the menu bar) brings that group into focus in the main window.
      if let id = store.activeProfileID, store.profiles.contains(where: { $0.id == id }) {
        selection = .profile(id)
      }
    }
    .onChange(of: store.sourceFocusToken) { _, _ in
      // The menu bar's "N more in Waves" overflow link asked to show a specific
      // scope (Pinned/Live/Recent) right before opening this window — honor it,
      // so the window shows the apps the link promised instead of whatever
      // scope it happened to already be on. This fires when the window was
      // already open (see onAppear above for the window-was-closed case).
      if let filter = store.consumeSourceFocusRequest() {
        selection = .source(filter)
      }
    }
    .onChange(of: store.equalizerFocusToken) { _, _ in
      handleEqualizerFocusRequest()
    }
    .onDisappear { store.endLiveLevels() }
  }

  @ViewBuilder
  private var primarySurface: some View {
    if store.privacySetupPresentationState != .hidden {
      PrivacySetupSurface()
    } else if !store.preferences.hasCompletedGuidedSetup {
      OnboardingView()
    } else {
      mixerNavigation
    }
  }

  private var mixerNavigation: some View {
    NavigationSplitView {
      SidebarView(
        selection: $selection,
        onNewProfile: presentNewProfile,
        onEditProfile: presentEditProfile
      )
      .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
    } detail: {
      if selection == .sound {
        SoundWorkspaceView()
      } else {
        SourceListView(
          scope: selection,
          apps: filteredApps,
          searchText: searchText,
          onEditProfile: presentEditProfile
        )
      }
    }
    .navigationSplitViewStyle(.balanced)
    .searchable(text: $searchText, placement: .sidebar, prompt: "Filter apps")
    .toolbar { mixerToolbar }
  }

  @ToolbarContentBuilder
  private var mixerToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      // Appears only while there's a mix to go back to: after a profile with
      // saved levels is applied, one click returns every app to its
      // pre-profile volume, mute, and boost.
      if store.mixRestorePoint != nil {
        Button {
          store.resetMix()
        } label: {
          Label("Reset Mix", systemImage: "arrow.uturn.backward.circle")
        }
        .help(resetMixHelp)
        .accessibilityLabel("Reset mix")
        .accessibilityHint("Returns every app to the levels it had before the last profile.")
      }

      Menu {
        ForEach(AdaptiveMixMode.allCases, id: \.self) { mode in
          Button {
            store.setAdaptiveMixMode(mode)
          } label: {
            if store.preferences.adaptiveMixMode == mode {
              Label(mode.displayName, systemImage: "checkmark")
            } else {
              Text(mode.displayName)
            }
          }
        }
      } label: {
        Image(systemName: "waveform.badge.plus")
          .foregroundStyle(theme.accentOrSecondary(store.preferences.adaptiveMixMode != .off))
      }
      .help("Adaptive Mix: \(store.preferences.adaptiveMixMode.displayName)")
      .accessibilityLabel("Adaptive Mix")
      .accessibilityValue(store.preferences.adaptiveMixMode.displayName)

      Button {
        store.refresh()
      } label: {
        if store.isRefreshing {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "arrow.clockwise")
        }
      }
      .disabled(store.isRefreshing)
      .help("Refresh App List (⌘R)")
      .accessibilityLabel(store.isRefreshing ? "Refreshing app list, in progress" : "Refresh app list")
      .accessibilityHint("Refreshes running apps and audio session state.")
      .keyboardShortcut("r", modifiers: [.command])
    }
  }

  private var resetMixHelp: String {
    guard let restorePoint = store.mixRestorePoint else { return "Reset mix" }
    return "Put every app back to how it was before \(restorePoint.profileName)."
  }

  /// Per-app EQ lives in the Sound workspace now (one EQ surface, no side
  /// panel), so an equalizer request just switches this window there — the
  /// workspace itself consumes the request to select the right app.
  private func handleEqualizerFocusRequest() {
    guard store.equalizerFocusRequest != nil else { return }
    selection = .sound
  }

  /// A persisted scope can become invalid: a `.recent` source after the user
  /// turned recent apps off, or a profile that was since deleted. Fall back to
  /// Running whenever the restored/current scope no longer resolves.
  private func validateSelection() {
    switch selection {
    case .source(.recent) where !store.preferences.showRecentApps:
      selection = .source(.running)
    case .profile(let id) where !store.profiles.contains(where: { $0.id == id }):
      selection = .source(.running)
    default:
      break
    }
  }

  private func presentNewProfile() {
    // Seed a new profile with whatever is currently playing — the most common
    // starting set — and default to capturing the current mix.
    editorContext = ProfileEditorContext(
      profile: nil,
      preselectedAppIDs: store.liveApps.map(\.logicalID)
    )
  }

  private func presentEditProfile(_ profile: Profile) {
    editorContext = ProfileEditorContext(profile: profile, preselectedAppIDs: profile.appIDs)
  }

  private var scopedApps: [AudioApp] {
    switch selection {
    case .sound:
      return []
    case .source(.running):
      return store.visibleApps
    case .source(.pinned):
      return store.pinnedApps
    case .source(.frontmost):
      return store.liveApps
    case .source(.recent):
      return store.recentApps
    case .profile(let id):
      guard let profile = store.profiles.first(where: { $0.id == id }) else { return [] }
      return store.apps(in: profile)
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
}

// MARK: - Scope

/// What the main window is currently showing: one of the built-in sources, or a
/// user profile (an app group). Persisted via `@SceneStorage` as a string.
enum MixerScope: Hashable, RawRepresentable {
  case sound
  case source(SourceFilter)
  case profile(UUID)

  var rawValue: String {
    switch self {
    case .sound:
      return "sound"
    case .source(let filter):
      return "source:\(filter.rawValue)"
    case .profile(let id):
      return "profile:\(id.uuidString)"
    }
  }

  init?(rawValue: String) {
    if rawValue == "sound" {
      self = .sound
    } else if rawValue.hasPrefix("source:"),
       let filter = SourceFilter(rawValue: String(rawValue.dropFirst("source:".count))) {
      self = .source(filter)
    } else if rawValue.hasPrefix("profile:"),
              let id = UUID(uuidString: String(rawValue.dropFirst("profile:".count))) {
      self = .profile(id)
    } else {
      return nil
    }
  }
}

enum SourceFilter: String, CaseIterable, Identifiable {
  case running
  case pinned
  case frontmost
  case recent

  var id: Self { self }

  var title: String {
    switch self {
    case .running: "Running"
    case .pinned: "Pinned"
    case .frontmost: "Live"
    case .recent: "Recent"
    }
  }

  @MainActor
  func count(in store: AppStore) -> Int {
    switch self {
    case .running: store.visibleApps.count
    case .pinned: store.pinnedApps.count
    case .frontmost: store.liveApps.count
    case .recent: store.recentApps.count
    }
  }

  func detail(count: Int) -> String {
    let label: String
    switch self {
    case .running: label = count == 1 ? "running app" : "running apps"
    case .pinned: label = count == 1 ? "pinned app" : "pinned apps"
    case .frontmost: label = count == 1 ? "live app" : "live apps"
    case .recent: label = count == 1 ? "recent app" : "recent apps"
    }
    return "\(count) \(label)"
  }

  var systemImage: String {
    switch self {
    case .running: "square.stack.3d.up.fill"
    case .pinned: "pin.fill"
    case .frontmost: "waveform"
    case .recent: "clock.fill"
    }
  }

  var emptyTitle: String {
    switch self {
    case .running: "No Running Apps"
    case .pinned: "No Pinned Apps"
    case .frontmost: "No Live Apps"
    case .recent: "No Recent Apps"
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
      return "Pin apps from the list to keep them here and at the top of the menu bar."
    case .frontmost:
      return "Start playback in an app, then refresh if it does not appear here."
    case .recent:
      return "Apps appear here when they're not actively playing audio."
    }
  }
}

private struct SidebarView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Binding var selection: MixerScope
  let onNewProfile: () -> Void
  let onEditProfile: (Profile) -> Void
  // Deleting a profile discards a hand-tuned captured mix with no undo, so the
  // context menu's Delete asks first instead of firing on a single misclick.
  @State private var profilePendingDeletion: Profile?

  var body: some View {
    List(selection: $selection) {
      Section("Sound") {
        Label {
          VStack(alignment: .leading, spacing: 1) {
            Text("Sound")
            Text("EQ and Adaptive Mix")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "waveform.and.magnifyingglass")
            .foregroundStyle(theme.accentOrSecondary(selection == .sound))
        }
        .tag(MixerScope.sound)
      }

      Section("Sources") {
        ForEach(availableFilters) { filter in
          SourceFilterRow(
            filter: filter,
            countText: filter.detail(count: filter.count(in: store)),
            // The Live row's waveform comes alive whenever something is playing.
            isLive: filter == .frontmost && !store.liveApps.isEmpty
          )
          .tag(MixerScope.source(filter))
        }
      }

      Section {
        if store.profiles.isEmpty {
          Text("No profiles yet. Group apps with +")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        ForEach(store.profiles) { profile in
          ProfileSidebarRow(profile: profile)
            .tag(MixerScope.profile(profile.id))
            .contextMenu {
              if profile.carriesLevels {
                Button("Apply Levels") { store.applyProfile(profile) }
                if store.preferences.defaultProfileID == profile.id {
                  Button("Don't Apply at Startup") { store.setDefaultProfile(nil) }
                } else {
                  Button("Apply at Startup") { store.setDefaultProfile(profile) }
                }
              }
              Button("Edit Profile…") { onEditProfile(profile) }
              Button("Export…") { store.exportProfile(profile) }
              Divider()
              Button("Delete Profile…", role: .destructive) {
                profilePendingDeletion = profile
              }
            }
        }
      } header: {
        HStack {
          Text("Profiles")
          Spacer()
          Button(action: onNewProfile) {
            Image(systemName: "plus")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("New Profile (⌘N)")
          .accessibilityLabel("New profile")
          .keyboardShortcut("n", modifiers: [.command])
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Waves")
    .confirmationDialog(
      "Delete “\(profilePendingDeletion?.name ?? "")”?",
      isPresented: Binding(
        get: { profilePendingDeletion != nil },
        set: { if !$0 { profilePendingDeletion = nil } }
      ),
      titleVisibility: .visible,
      presenting: profilePendingDeletion
    ) { profile in
      Button("Delete Profile", role: .destructive) {
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
          store.deleteProfiles(at: IndexSet(integer: index))
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { profile in
      Text("This removes \(profile.name)\(profile.carriesLevels ? " and its saved levels" : "") from your profiles. This can't be undone.")
    }
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.wavesTheme) private var theme
  let filter: SourceFilter
  let countText: String
  var isLive: Bool = false

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(filter.title)
          .lineLimit(1)
        Text(countText)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: filter.systemImage)
        .foregroundStyle(theme.accentOrSecondary(filter == .frontmost))
        .symbolEffect(.variableColor.iterative, isActive: isLive && !reduceMotion)
    }
  }
}

private struct ProfileSidebarRow: View {
  @Environment(AppStore.self) private var store
  let profile: Profile

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(profile.name)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    } icon: {
      Image(systemName: profile.carriesLevels ? "slider.horizontal.below.square.filled.and.square" : "square.grid.2x2")
        .foregroundStyle(.secondary)
    }
  }

  private var subtitle: String {
    let count = profile.entries.count
    let noun = count == 1 ? "app" : "apps"
    var text = profile.carriesLevels ? "\(count) \(noun) · levels" : "\(count) \(noun)"
    if store.preferences.defaultProfileID == profile.id {
      text += " · startup"
    }
    return text
  }
}

private struct SourceListView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openSettings) private var openSettings
  @Environment(\.wavesTheme) private var theme
  @State private var selectedAppID: AudioApp.ID?
  let scope: MixerScope
  let apps: [AudioApp]
  let searchText: String
  let onEditProfile: (Profile) -> Void

  private var profile: Profile? {
    guard case .profile(let id) = scope else { return nil }
    return store.profiles.first { $0.id == id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let profile {
        ProfileHeaderView(profile: profile, visibleCount: apps.count, isSearching: isSearching, onEdit: { onEditProfile(profile) })
      } else {
        OutputSummaryView(scope: scope, visibleCount: apps.count, isSearching: isSearching)
      }

      // The live "mixed waves" band: every playing app as a thin component
      // wave summing into the bright mixed wave, on a solid content surface
      // beneath the header.
      HeaderWaveform(height: 48)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(theme.contentFill)
        .overlay(Divider(), alignment: .bottom)

      if !unroutableApps.isEmpty {
        UnroutableAppsBanner(apps: unroutableApps) {
          store.excludeUnroutableApps(unroutableApps)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
      }

      // Suppress the empty state during the first scan so the window never
      // tells the user it is "Refreshing" (the pill in MainWindowView) and that
      // nothing was found at the same time. Mirrors the menu bar's gating.
      if apps.isEmpty && !store.isLoading {
        VStack(spacing: 14) {
          ContentUnavailableView(
            emptyTitle,
            systemImage: profile == nil ? "speaker.slash" : "square.grid.2x2",
            description: Text(emptyMessage)
          )

          // Each empty scope gets the one action that actually resolves it —
          // a generic Refresh/Settings pair here used to show for every scope
          // even when neither button did anything for that scope (e.g. Settings
          // has no toggle relevant to "no pinned apps").
          if systemProcessesHidden {
            // Apps are hidden by the system-processes filter, so a Refresh is a
            // no-op — the remedy is the Settings toggle.
            Button {
              openSettings()
            } label: {
              Label("Open Settings", systemImage: "gearshape")
            }
            .wavesGlassProminentButton()
          } else if case .source(.pinned) = scope, !isSearching {
            // Pinning only happens from the Running list, never from here.
            Button {
              store.focusSource(.running)
            } label: {
              Label("Go to Running Apps", systemImage: "square.stack.3d.up.fill")
            }
            .wavesGlassProminentButton()
          } else {
            Button {
              store.refresh()
            } label: {
              Label("Refresh", systemImage: "arrow.clockwise")
            }
            .wavesGlassProminentButton()
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $selectedAppID) {
          ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
            MixerRowView(app: app)
              .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18))
              .listRowBackground(selectedAppID == app.id ? theme.selectionFill : Color.clear)
              .tag(app.id)
              // Drag-and-drop reordering (.onMove below) has no VoiceOver
              // equivalent on its own — these actions are the accessible path
              // to the same store.reorderApps the drag handle uses. Only
              // offered when the list is actually reorderable (Running scope,
              // no active search) and there's somewhere to move to, mirroring
              // .moveDisabled's gating below.
              .accessibilityActions {
                if isReorderable {
                  if index > 0 {
                    Button("Move Up") {
                      store.reorderApps(from: IndexSet(integer: index), to: index - 1)
                    }
                  }
                  if index < apps.count - 1 {
                    Button("Move Down") {
                      store.reorderApps(from: IndexSet(integer: index), to: index + 2)
                    }
                  }
                }
              }
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
        .wavesSoftScrollEdge()
        // Keyboard operation: arrow keys move the selection (List), and these
        // keys act on the selected row so the mixer is fully drivable without a
        // mouse — including muting, which the borderless button can't reach.
        .onKeyPress(.space) { handleKey { store.setMuted(!$0.isMuted, for: $0) } }
        .onKeyPress("m") { handleKey { store.setMuted(!$0.isMuted, for: $0) } }
        .onKeyPress("=") { handleKey { nudgeVolume($0, by: 0.05) } }
        // Also accept the shifted "+" so a user reaching for the obvious "louder"
        // key isn't met with silence (the hint still reads "equals or minus").
        .onKeyPress("+") { handleKey { nudgeVolume($0, by: 0.05) } }
        .onKeyPress("-") { handleKey { nudgeVolume($0, by: -0.05) } }
        .onKeyPress("b") { handleKey { cycleBoost($0) } }
        .onKeyPress("p") { handleKey { store.togglePinned($0) } }
        // Surface the otherwise-undocumented in-row keys: without this hint a
        // user can only discover them by reading source. Mirrors the toolbar
        // controls, which advertise their shortcuts via help/accessibility text.
        .accessibilityHint(
          "Use arrow keys to select an app. On the selected app, press Space or M to mute, "
            + "equals or minus to adjust volume, B to cycle boost, and P to pin."
        )
        .help(
          "Select an app with the arrow keys, then: Space or M mute, = / - volume, B boost, P pin."
        )
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
    .background(WavesBackground())
  }

  /// Apps in the current scope that do not expose a manageable audio stream (see
  /// `AudioApp.hasNoAudioCapability`) — summarized once in `UnroutableAppsBanner`
  /// instead of repeating the same explanation on every such row.
  private var unroutableApps: [AudioApp] {
    apps.filter { $0.routingState == .error && $0.hasNoAudioCapability }
  }

  /// True when the user has an active (non-whitespace) search query. Search
  /// looks across ALL visible apps regardless of the selected scope, so any
  /// scope-specific noun ("pinned apps", "running apps") would mislabel the
  /// cross-scope result set. Mirrors `filteredApps`' trimmed-query check.
  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// True when the Running scope is empty only because system processes are
  /// being filtered out (apps were detected, just hidden by the preference).
  private var systemProcessesHidden: Bool {
    scope == .source(.running)
      && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !store.preferences.showSystemProcesses
      && store.session.apps.contains { $0.category == .system }
  }

  private var emptyTitle: String {
    if systemProcessesHidden { return "System Processes Hidden" }
    // While searching, "No <profile> Apps Running" would be a false claim — the
    // emptiness is just a non-matching query.
    if let profile { return isSearching ? "No Results" : "No \(profile.name) Apps Running" }
    if case .source(let filter) = scope { return filter.emptyTitle }
    return "Nothing Here"
  }

  private var emptyMessage: String {
    if systemProcessesHidden {
      return "System processes are hidden. Turn on Show system processes in Settings > Mixer to see them."
    }
    if let profile {
      // A search spans all visible apps, so an empty result here just means the
      // query matched nothing — not that the profile's apps aren't running.
      if isSearching { return "Try a different search term." }
      return "None of \(profile.name)'s \(profile.entries.count) \(profile.entries.count == 1 ? "app" : "apps") are running right now. Launch one to control it here."
    }
    if case .source(let filter) = scope {
      return filter.emptyMessage(searchText: searchText)
    }
    return ""
  }

  /// True whenever a drag would map back to the full list correctly, so the OS
  /// never presents a drag handle that would silently snap back elsewhere.
  /// Only the Running scope (no active search) is reorderable; profile and other
  /// scopes show a subset whose indices would not map back to the stored order.
  private var isReorderable: Bool {
    scope == .source(.running)
      && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Runs `action` on the currently selected row, if any.
  ///
  /// These are focused-window keys that work while the mixer window (this
  /// list) is focused, like the Help copy's ⌘N/⌘R. They are intentionally NOT
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

/// One combined notice for apps that do not expose a manageable Core Audio
/// stream (see `AudioApp.hasNoAudioCapability`), replacing the same explanatory
/// paragraph repeated verbatim on every such row. Neutral in tone: these apps
/// are working as expected (menu-bar utilities, CLI tools), not broken, so this
/// isn't styled as an error/warning.
private struct UnroutableAppsBanner: View {
  let apps: [AudioApp]
  let onExcludeAll: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 10)

      Button(apps.count == 1 ? "Exclude" : "Exclude All", action: onExcludeAll)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    .padding(10)
    .wavesCard()
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    apps.count == 1
      ? "\(apps[0].displayName) has no manageable audio stream"
      : "\(apps.count) apps have no manageable audio stream"
  }

  private var detail: String {
    if apps.count == 1 {
      return "Waves cannot create a managed route for it. Exclude it to stop this notice."
    }
    let names = apps.map(\.displayName).joined(separator: ", ")
    return "Waves cannot create managed routes for: \(names). Exclude them to stop this notice."
  }
}

private struct ProfileHeaderView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  let profile: Profile
  let visibleCount: Int
  // True when a search is active. Search spans all visible apps regardless of
  // scope, so "N of M running" would count cross-scope matches against this
  // profile's membership; use a neutral "result(s)" noun instead (matching
  // OutputSummaryView).
  let isSearching: Bool
  let onEdit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: profile.carriesLevels ? "slider.horizontal.below.square.filled.and.square" : "square.grid.2x2")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(theme.accent)
        .frame(width: 30, height: 30)
        .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 1) {
        Text(profile.name)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      // The title wins truncation before the trailing buttons compress.
      .layoutPriority(1)

      Spacer(minLength: 12)

      if profile.carriesLevels {
        Button {
          store.applyProfile(profile)
        } label: {
          Label("Apply Levels", systemImage: "checkmark.circle")
        }
        .wavesGlassProminentButton()
        .controlSize(.small)
        .help("Set every app in this profile to its saved volume, mute, and boost.")
      }

      Button {
        onEdit()
      } label: {
        Label("Edit", systemImage: "slider.horizontal.3")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(theme.subtleFill)
    .overlay(Divider(), alignment: .bottom)
  }

  private var subtitle: String {
    if isSearching {
      return "\(visibleCount) \(visibleCount == 1 ? "result" : "results")"
    }
    let running = "\(visibleCount) of \(profile.entries.count) running"
    return profile.carriesLevels ? "\(running) · carries saved levels" : "\(running) · group"
  }
}

private struct OutputSummaryView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.wavesTheme) private var theme
  let scope: MixerScope
  let visibleCount: Int
  // True when a search is active. Search spans all visible apps regardless of
  // scope, so the count is labeled with a neutral "result(s)" noun instead of
  // the scope noun, which would otherwise contradict the rows actually shown.
  let isSearching: Bool

  private var countDetail: String {
    if isSearching {
      let noun = visibleCount == 1 ? "result" : "results"
      return "\(visibleCount) \(noun)"
    }
    if case .source(let filter) = scope {
      return filter.detail(count: visibleCount)
    }
    return "\(visibleCount) apps"
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "hifispeaker.2.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .background(.tertiary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 1) {
        Text(store.currentDeviceName)
          .font(.headline.weight(.semibold))
          .lineLimit(1)

        HStack(spacing: 8) {
          Text(countDetail)
            .foregroundStyle(.secondary)

          if let liveSummary {
            Label(liveSummary, systemImage: "waveform")
              // Drop to primary text under Increase Contrast so the cyan never
              // fails contrast on the .bar header.
              .foregroundStyle(contrast == .increased ? Color.primary : theme.accent)
              // The accent "playing" signal survives truncation over the static count.
              .layoutPriority(1)
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
    .background(theme.subtleFill)
    .overlay(Divider(), alignment: .bottom)
  }

  private var liveSummary: String? {
    // "…playing" is a present-tense claim, so use the real signal (no linger) —
    // it disappears the moment audio stops, matching the fading ribbon, rather
    // than naming a silent app for the linger window.
    let live = store.actuallyLiveApps
    let names = live.prefix(3).map(\.displayName)
    guard !names.isEmpty else { return nil }

    let joined = names.joined(separator: ", ")
    let overflow = live.count - names.count
    return overflow > 0 ? "\(joined) +\(overflow) playing" : "\(joined) playing"
  }
}

private struct RouteHealthBadge: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    // Healthy: a quiet status chip. Degraded: a button that runs recovery right
    // from where the problem is reported, instead of dead-ending in a tooltip and
    // hiding the remedy behind an obscure toolbar glyph.
    if isHealthy {
      badge
        .help(Text("Routing status: \(title)"))
        .accessibilityLabel(Text("Routing status: \(title)"))
    } else {
      Button {
        store.recoverRoutes()
      } label: {
        badge
      }
      .buttonStyle(.plain)
      .disabled(store.isRecovering)
      .help(Text("\(title). Click to recover managed routes."))
      .accessibilityLabel(Text("Routing status: \(title)"))
      .accessibilityHint("Reattaches active per-app audio routes.")
    }
  }

  private var badge: some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
  }

  private var isHealthy: Bool { store.session.backendStatus.isRouteRecoveryHealthy }

  private var title: String {
    if isHealthy { return "Ready" }
    if store.session.backendStatus.lastError != nil { return "Needs attention" }
    return "Limited"
  }

  private var systemImage: String {
    if isHealthy { return "checkmark.circle.fill" }
    if store.session.backendStatus.lastError != nil { return "exclamationmark.triangle.fill" }
    return "exclamationmark.circle"
  }

  private var color: Color {
    if isHealthy { return WavesDesign.success }
    if store.session.backendStatus.lastError != nil { return WavesDesign.error }
    return .secondary
  }
}

private struct DiagnosticsPanel: View {
  @Environment(AppStore.self) private var store
  @State private var expanded = false

  // Caps how tall the expanded checklist can grow. Without this, expanding
  // the DisclosureGroup in a long checklist (several failing checks, each
  // with a two-line description) could ask this VStack's List sibling above
  // it to shrink toward zero/negative height in the same animated layout
  // pass — a List (NSTableView-backed) squeezed that hard during a SwiftUI
  // animation reliably blanks the entire window content, sidebar included,
  // not just this panel (reproduced: clicking the disclosure with several
  // checks present collapses the whole NavigationSplitView to nothing, with
  // no crash/exception logged — a pure AppKit/SwiftUI layout corruption, not
  // a Swift-level bug). Scrolling past this cap instead of growing forever
  // keeps the panel's worst-case height bounded and predictable, mirroring
  // the same height-capped-scroller pattern already used for the menu bar's
  // app sections (MenuBarMixerView.sectionsScroller).
  private static let maxExpandedHeight: CGFloat = 220

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      if let diagnostics = store.diagnostics {
        ScrollView {
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
                  Image(systemName: check.status.symbolName)
                    .font(.caption)
                    .foregroundStyle(check.status.color)
                    .accessibilityHidden(true)
                  Text(check.title)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.status.statusWord): \(check.title)")

                Text(check.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.leading, 15)
              }
            }
          }
          .padding(.top, 10)
        }
        .frame(maxHeight: Self.maxExpandedHeight)
      } else {
        Text("Diagnostics not available yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 10)
      }
    } label: {
      HStack(spacing: 8) {
        Text("Diagnostics")
          .font(.callout.weight(.semibold))
        // A collapsed panel gives no reason to open it; surface a colored count
        // when a check needs attention so a problem is discoverable at a glance.
        if let attention = attentionSummary {
          Text(attention.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(attention.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(attention.color.opacity(0.14), in: Capsule())
            .accessibilityLabel(attention.accessibility)
        }
      }
    }
  }

  /// A "N issues" pill for the collapsed label when any check failed or warned.
  private var attentionSummary: (text: String, color: Color, accessibility: String)? {
    guard let checks = store.diagnostics?.checks else { return nil }
    let failed = checks.filter { $0.status == .failed }.count
    let warnings = checks.filter { $0.status == .warning }.count
    let total = failed + warnings
    guard total > 0 else { return nil }
    let noun = total == 1 ? "issue" : "issues"
    let color: Color = failed > 0 ? WavesDesign.error : WavesDesign.warning
    return ("\(total) \(noun)", color, "\(total) diagnostics \(noun)")
  }
}
