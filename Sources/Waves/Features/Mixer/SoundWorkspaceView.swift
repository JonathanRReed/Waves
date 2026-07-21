import SwiftUI
import WavesAudioCore

/// Which stream the Sound workspace's equalizer card is editing: the shared
/// managed-audio EQ, or one app's own EQ. One card, one set of controls —
/// replacing the old split between this workspace and a per-app side panel,
/// which presented two disconnected EQs and clipped over the app list when
/// the window was small.
private enum EqualizerScope: Hashable {
  case managedAudio
  case app(String)
}

struct SoundWorkspaceView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @State private var pendingStrategy: AdaptiveStrategy?
  @State private var eqScope: EqualizerScope = .managedAudio

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header

        equalizerSection
        adaptiveMixSection
        appPoliciesSection
      }
      .frame(maxWidth: 920, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.vertical, 22)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(WavesBackground())
    .onAppear { consumeEqualizerFocusRequestIfAny() }
    .onChange(of: store.equalizerFocusToken) { _, _ in
      consumeEqualizerFocusRequestIfAny()
    }
    .onChange(of: store.visibleApps.map(\.logicalID)) { _, _ in
      // The selected app can quit; fall back to the shared EQ instead of
      // stranding the card on a stream that no longer exists.
      if case .app(let id) = eqScope, resolvedApp(for: id) == nil {
        eqScope = .managedAudio
      }
    }
    .confirmationDialog(
      "Apply \(pendingStrategy?.displayName ?? "this strategy")?",
      isPresented: Binding(
        get: { pendingStrategy != nil },
        set: { if !$0 { pendingStrategy = nil } }
      ),
      titleVisibility: .visible,
      presenting: pendingStrategy
    ) { strategy in
      Button("Apply \(strategy.displayName)") {
        store.applyAdaptiveStrategy(strategy)
        pendingStrategy = nil
      }
      Button("Cancel", role: .cancel) { pendingStrategy = nil }
    } message: { strategy in
      Text(
        "This updates the content type and priority for the apps listed below. Volumes, routing, and equalizers stay as they are."
      )
    }
  }

  /// An EQ button anywhere in the app (mixer row, menu bar, context menu)
  /// lands here with the app preselected.
  private func consumeEqualizerFocusRequestIfAny() {
    guard let request = store.consumeEqualizerFocusRequest() else { return }
    eqScope = .app(request.appID)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "waveform.and.magnifyingglass")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(theme.accent)
        .frame(width: 42, height: 42)
        .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(alignment: .leading, spacing: 5) {
        Text("Sound")
          .font(.title2.weight(.semibold))
        Text("Shape how each app sounds, and decide which apps stay in front when several play at once.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Label("\(managedAppCount) managed", systemImage: "checkmark.seal.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(managedAppCount > 0 ? theme.success : Color.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.subtleFill, in: Capsule())
        .help("Apps whose audio currently runs through Waves.")
    }
  }

  // MARK: - Equalizer (one card for the shared EQ and every app's EQ)

  private var equalizerSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(
        "Equalizer",
        detail: equalizerScopeDetail
      ) {
        Toggle(
          "Equalizer",
          isOn: Binding(
            get: { scopeIsEnabled },
            set: { setScopeEnabled($0) }
          )
        )
        .labelsHidden()
        .disabled(scopeIsUnavailable)
      }

      scopePicker

      if let note = scopeNote {
        Label(note.text, systemImage: note.symbol)
          .font(.caption)
          .foregroundStyle(note.isWarning ? theme.warning : Color.secondary)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(theme.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }

      HStack(alignment: .firstTextBaseline, spacing: 14) {
        Picker(
          "Bands",
          selection: Binding(
            get: { scopeSettings.mode },
            set: { setScopeMode($0) }
          )
        ) {
          ForEach(EqualizerMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)

        Picker(
          "Preset",
          selection: Binding(
            get: { scopeSettings.selectedPreset },
            set: { preset in
              guard preset != .custom else { return }
              applyScopePreset(preset)
            }
          )
        ) {
          ForEach(EqualizerPreset.selectablePresets, id: \.self) { preset in
            Text(preset.displayName).tag(preset)
          }
          if scopeSettings.selectedPreset == .custom {
            Text(EqualizerPreset.custom.displayName).tag(EqualizerPreset.custom)
          }
        }
        .frame(maxWidth: 240)

        Spacer()

        Button("Reset to Flat") { resetScope() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(scopeSettings.selectedPreset == .flat)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 190), spacing: 16)],
        alignment: .leading,
        spacing: 14
      ) {
        ForEach(Array(scopeBands.enumerated()), id: \.element.id) { index, band in
          SoundEQBandControl(
            band: band,
            gainDB: scopeGain(at: index),
            accent: theme.accent,
            onChange: { setScopeGain($0, at: index) }
          )
        }
      }

      HStack(spacing: 8) {
        Image(systemName: combinedHeadroomDB < 0 ? "shield.lefthalf.filled" : "checkmark.shield")
          .foregroundStyle(theme.accent)
        Text(headroomDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
    .padding(18)
    .wavesCard()
    .disabled(!store.isAudioRunning || scopeIsUnavailable)
  }

  /// One chip per stream: the shared EQ first, then every app that can carry
  /// its own curve. A horizontal scroller (not a dropdown) so switching between
  /// streams while tuning is one click, and the active stream stays visible.
  private var scopePicker: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        EQScopeChip(
          title: "All Managed Audio",
          icon: "waveform",
          isSelected: eqScope == .managedAudio,
          isEnabled: store.preferences.managedAudioEqualizer.isEnabled
        ) {
          eqScope = .managedAudio
        }

        ForEach(equalizerApps) { app in
          EQScopeChip(
            title: app.displayName,
            iconApp: app,
            isSelected: eqScope == .app(app.logicalID),
            isEnabled: store.equalizerSettings(for: app).isEnabled
          ) {
            eqScope = .app(app.logicalID)
          }
        }
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: Scope plumbing

  private var scopeApp: AudioApp? {
    guard case .app(let id) = eqScope else { return nil }
    return resolvedApp(for: id)
  }

  private func resolvedApp(for id: String) -> AudioApp? {
    store.visibleApps.first { $0.logicalID == id }
  }

  /// Apps offered in the scope picker: everything the mixer shows.
  private var equalizerApps: [AudioApp] {
    store.visibleApps.filter { !store.isExcluded($0) }
  }

  private var scopeSettings: EqualizerSettings {
    if let app = scopeApp {
      return store.equalizerSettings(for: app)
    }
    return store.preferences.managedAudioEqualizer.equalizerSettings
  }

  private var scopeIsEnabled: Bool {
    if let app = scopeApp {
      return store.equalizerSettings(for: app).isEnabled
    }
    return store.preferences.managedAudioEqualizer.isEnabled
  }

  private var scopeIsUnavailable: Bool {
    if case .app(let id) = eqScope { return resolvedApp(for: id) == nil }
    return false
  }

  private var scopeBands: [EqualizerBandDefinition] {
    EqualizerBandCatalog.bands(for: scopeSettings.mode)
  }

  private func scopeGain(at index: Int) -> Float {
    let gains = scopeSettings.activeGainsDB
    return gains.indices.contains(index) ? gains[index] : 0
  }

  private func setScopeEnabled(_ enabled: Bool) {
    if let app = scopeApp {
      store.setEqualizerEnabled(enabled, for: app)
    } else {
      store.setManagedAudioEqualizerEnabled(enabled)
    }
  }

  private func setScopeMode(_ mode: EqualizerMode) {
    if let app = scopeApp {
      store.setEqualizerMode(mode, for: app)
    } else {
      store.setManagedAudioEqualizerMode(mode)
    }
  }

  private func applyScopePreset(_ preset: EqualizerPreset) {
    if let app = scopeApp {
      store.applyEqualizerPreset(preset, for: app)
    } else {
      store.applyManagedAudioEqualizerPreset(preset)
    }
  }

  private func setScopeGain(_ gainDB: Float, at index: Int) {
    if let app = scopeApp {
      store.setEqualizerGain(gainDB, at: index, for: app)
    } else {
      store.setManagedAudioEqualizerGain(gainDB, at: index)
    }
  }

  private func resetScope() {
    if let app = scopeApp {
      store.resetEqualizer(for: app)
    } else {
      store.resetManagedAudioEqualizer()
    }
  }

  private var equalizerScopeDetail: String {
    if let app = scopeApp {
      return "This curve shapes only \(app.displayName). The shared All Managed Audio curve is applied after it."
    }
    return "One shared curve for every app routed through Waves. Pick an app below to shape just that app."
  }

  /// Status note for the selected app's stream, mirroring what the old side
  /// panel explained: saved-but-waiting routes and muted streams.
  private var scopeNote: (text: String, symbol: String, isWarning: Bool)? {
    guard let app = scopeApp else { return nil }
    if scopeSettings.isEnabled && app.routingState != .managed {
      return (
        "Saved. Waves applies this curve as soon as \(app.displayName) has a managed audio route.",
        "clock.arrow.circlepath",
        false
      )
    }
    return nil
  }

  // MARK: - Adaptive Mix

  private var adaptiveMixSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(
        "Adaptive Mix",
        detail:
          "Turns apps down, never off, so the app you care about stays in front. Nothing is paused or muted."
      ) {
        Toggle(
          "Adaptive Mix",
          isOn: Binding(
            get: { store.preferences.adaptiveMixMode != .off },
            set: { store.setAdaptiveMixMode($0 ? .both : .off) }
          )
        )
        .labelsHidden()
      }

      Picker(
        "Strategy",
        selection: Binding(
          get: { store.preferences.adaptiveStrategy },
          set: { strategy in
            if strategy == .custom || store.preferences.adaptiveAppPolicies.isEmpty {
              store.applyAdaptiveStrategy(strategy)
            } else {
              pendingStrategy = strategy
            }
          }
        )
      ) {
        ForEach(AdaptiveStrategy.allCases, id: \.self) { strategy in
          Text(strategy.displayName).tag(strategy)
        }
      }
      .pickerStyle(.segmented)

      Text(strategyDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Divider()

      HStack(alignment: .firstTextBaseline, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Sidechain Focus")
            .font(.callout.weight(.semibold))
          Text("Decides which app counts as the foreground when several are audible.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 12)

        Picker(
          "Sidechain Focus",
          selection: Binding(
            get: { store.preferences.adaptiveFocusMode },
            set: { store.setAdaptiveFocusMode($0) }
          )
        ) {
          ForEach(AdaptiveFocusMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .labelsHidden()
        .frame(width: 190)
      }

      Text(focusModeDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(18)
    .wavesCard()
    .disabled(!store.isAudioRunning)
  }

  // MARK: - App priorities

  private var appPoliciesSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionHeader(
        "App Priorities",
        detail:
          "Tell Waves what each app plays and how important it is. Never Adjust means Adaptive Mix leaves that app alone."
      ) { EmptyView() }

      if policyApps.isEmpty {
        ContentUnavailableView(
          "No Audio Apps Yet",
          systemImage: "speaker.slash",
          description: Text("Play audio in an app and it appears here.")
        )
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            Text("App")
              .frame(maxWidth: .infinity, alignment: .leading)
            Text("Content")
              .frame(width: 170, alignment: .leading)
            Text("Priority")
              .frame(width: 150, alignment: .leading)
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.bottom, 8)

          ForEach(policyApps) { app in
            AppPolicyRow(app: app)
            if app.id != policyApps.last?.id { Divider() }
          }
        }
      }
    }
    .padding(18)
    .wavesCard()
  }

  private func sectionHeader<Accessory: View>(
    _ title: String,
    detail: String,
    @ViewBuilder accessory: () -> Accessory
  ) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      accessory()
    }
  }

  private var policyApps: [AudioApp] {
    store.visibleApps.filter { app in
      app.routingState == .managed || app.routingState == .live || app.isActive
    }
  }

  private var managedAppCount: Int {
    store.visibleApps.filter { $0.routingState == .managed }.count
  }

  private var combinedHeadroomDB: Float {
    let values = store.visibleApps.map { app in
      GlobalEqualizerSettings.combinedHeadroomCompensationDB(
        perApp: store.equalizerSettings(for: app),
        managedAudio: store.preferences.managedAudioEqualizer
      )
    }
    return values.min() ?? store.preferences.managedAudioEqualizer.headroomCompensationDB
  }

  private var headroomDescription: String {
    if combinedHeadroomDB < 0 {
      return
        "Waves reserves \(String(format: "%.1f", -combinedHeadroomDB)) dB so boosted EQ curves can't clip."
    }
    return "No headroom needed for the current curves."
  }

  private var strategyDescription: String {
    switch store.preferences.adaptiveStrategy {
    case .lectureFocus:
      "Speech stays in front. Music and video keep playing quietly behind it."
    case .mediaFirst:
      "Music and video stay in front. Meetings drop into the background."
    case .balanced:
      "Every app starts at Normal priority, close to its manual level."
    case .custom:
      "Waves follows the content type and priority set per app below."
    }
  }

  private var focusModeDescription: String {
    switch store.preferences.adaptiveFocusMode {
    case .assignedPriorities:
      "Only the priorities below matter. The app in front gets no special treatment."
    case .followFrontApp:
      "The app in front becomes the foreground while it's audible. Voice and meeting apps need actual speech first."
    case .smartHybrid:
      "The app in front moves up one priority tier while it's audible. Your assigned priorities still set the limits."
    }
  }
}

/// One selectable stream in the equalizer card's scope row: the shared EQ or
/// a single app. A small dot marks streams whose EQ is currently on, so you
/// can see at a glance where shaping is active without visiting each one.
private struct EQScopeChip: View {
  @Environment(\.wavesTheme) private var theme
  let title: String
  var icon: String? = nil
  var iconApp: AudioApp? = nil
  let isSelected: Bool
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let iconApp {
          AppIconView(app: iconApp)
            .frame(width: 16, height: 16)
        } else if let icon {
          Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(isSelected ? theme.accent : Color.secondary)
        }
        Text(title)
          .font(.caption.weight(isSelected ? .semibold : .regular))
          .lineLimit(1)
        if isEnabled {
          Circle()
            .fill(theme.accent)
            .frame(width: 5, height: 5)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        isSelected ? theme.selectionFill : theme.subtleFill,
        in: Capsule()
      )
      .overlay(
        Capsule().strokeBorder(isSelected ? theme.accent.opacity(0.5) : Color.clear)
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title) equalizer")
    .accessibilityValue(isEnabled ? "On" : "Off")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

private struct AppPolicyRow: View {
  @Environment(AppStore.self) private var store
  let app: AudioApp

  var body: some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        AppIconView(app: app)
        VStack(alignment: .leading, spacing: 2) {
          Text(app.displayName)
            .lineLimit(1)
          Text(routeLabel)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Picker(
        "Content type for \(app.displayName)",
        selection: Binding(
          get: { policy.contentType },
          set: { store.setAdaptiveContentType($0, for: app) }
        )
      ) {
        ForEach(AdaptiveContentType.allCases, id: \.self) { type in
          Text(type.displayName).tag(type)
        }
      }
      .labelsHidden()
      .frame(width: 170)

      Picker(
        "Priority for \(app.displayName)",
        selection: Binding(
          get: { policy.priority },
          set: { store.setAdaptivePriority($0, for: app) }
        )
      ) {
        ForEach(AdaptivePriority.allCases, id: \.self) { priority in
          Text(priority.displayName).tag(priority)
        }
      }
      .labelsHidden()
      .frame(width: 150)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .disabled(store.isExcluded(app))
  }

  private var policy: AdaptiveAppPolicy {
    store.adaptivePolicy(for: app)
  }

  private var routeLabel: String {
    if store.isExcluded(app) { return "Excluded from Waves" }
    return switch app.routingState {
    case .managed: "Managed"
    case .live: "Playing, ready to manage"
    case .monitorOnly: "Monitoring only"
    case .recent: "Recently active"
    case .error: "Needs route attention"
    }
  }
}

private struct SoundEQBandControl: View {
  let band: EqualizerBandDefinition
  let gainDB: Float
  let accent: Color
  let onChange: (Float) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(band.label)
          .font(.caption.weight(.medium))
        Spacer()
        Text(formattedGain)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Slider(
        value: Binding(
          get: { Double(gainDB) },
          set: { onChange(Float($0)) }
        ),
        in: Double(EqualizerSettings.minimumGainDB)...Double(EqualizerSettings.maximumGainDB),
        step: 0.5
      )
      .tint(accent)
      .accessibilityLabel("\(band.label) gain")
      .accessibilityValue(formattedGain)
    }
  }

  private var formattedGain: String {
    let prefix = gainDB > 0 ? "+" : ""
    return "\(prefix)\(String(format: "%.1f", gainDB)) dB"
  }
}
