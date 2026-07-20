import SwiftUI
import WavesAudioCore

struct SoundWorkspaceView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @State private var pendingStrategy: AdaptiveStrategy?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header

        managedEqualizerSection
        adaptiveMixSection
        appPoliciesSection
      }
      .frame(maxWidth: 920, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.vertical, 22)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(WavesBackground())
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
        "This updates the content-aware priority for visible apps. Manual volume, routing, and equalizer settings stay unchanged."
      )
    }
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
        Text("Shape every stream managed by Waves, then decide which apps should stay in front.")
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
    }
  }

  private var managedEqualizerSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(
        "Managed Audio EQ",
        detail:
          "Applies after each app's own EQ to streams currently routed through Waves. Excluded and unsupported audio is not affected."
      ) {
        Toggle(
          "Managed Audio EQ",
          isOn: Binding(
            get: { equalizer.isEnabled },
            set: { store.setManagedAudioEqualizerEnabled($0) }
          )
        )
        .labelsHidden()
        .help("Enable or bypass the shared equalizer for managed audio.")
      }

      HStack(alignment: .firstTextBaseline, spacing: 14) {
        Picker(
          "Bands",
          selection: Binding(
            get: { equalizer.mode },
            set: { store.setManagedAudioEqualizerMode($0) }
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
            get: { equalizer.selectedPreset },
            set: { preset in
              guard preset != .custom else { return }
              store.applyManagedAudioEqualizerPreset(preset)
            }
          )
        ) {
          ForEach(EqualizerPreset.selectablePresets, id: \.self) { preset in
            Text(preset.displayName).tag(preset)
          }
          if equalizer.selectedPreset == .custom {
            Text(EqualizerPreset.custom.displayName).tag(EqualizerPreset.custom)
          }
        }
        .frame(maxWidth: 240)

        Spacer()

        Button("Reset to Flat") { store.resetManagedAudioEqualizer() }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(equalizer.selectedPreset == .flat)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 190), spacing: 16)],
        alignment: .leading,
        spacing: 14
      ) {
        ForEach(Array(activeBands.enumerated()), id: \.element.id) { index, band in
          SoundEQBandControl(
            band: band,
            gainDB: activeGain(at: index),
            accent: theme.accent,
            onChange: { store.setManagedAudioEqualizerGain($0, at: index) }
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
    .disabled(!store.isAudioRunning)
  }

  private var adaptiveMixSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(
        "Adaptive Mix",
        detail:
          "Uses activity, content type, and priority to create space. It only attenuates, it never pauses or mutes lower-priority apps."
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
          Text("Choose what becomes the foreground source when multiple apps are audible.")
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

  private var appPoliciesSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      sectionHeader(
        "App Priorities",
        detail:
          "Classify what each app carries, then choose where it belongs in the mix. Never Adjust disables adaptive gain only."
      ) { EmptyView() }

      if policyApps.isEmpty {
        ContentUnavailableView(
          "No Audio Apps Yet",
          systemImage: "speaker.slash",
          description: Text("Start playback in an app, then refresh Waves.")
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

  private var equalizer: GlobalEqualizerSettings {
    store.preferences.managedAudioEqualizer
  }

  private var activeBands: [EqualizerBandDefinition] {
    EqualizerBandCatalog.bands(for: equalizer.mode)
  }

  private func activeGain(at index: Int) -> Float {
    equalizer.activeGainsDB.indices.contains(index) ? equalizer.activeGainsDB[index] : 0
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
        managedAudio: equalizer
      )
    }
    return values.min() ?? equalizer.headroomCompensationDB
  }

  private var headroomDescription: String {
    if combinedHeadroomDB < 0 {
      return
        "Clipping protection reserves up to \(String(format: "%.1f", -combinedHeadroomDB)) dB for stacked app and managed EQ boosts."
    }
    return "No extra headroom is needed for the current EQ curves."
  }

  private var strategyDescription: String {
    switch store.preferences.adaptiveStrategy {
    case .lectureFocus:
      "Lecture and voice are foreground, while music remains audible in the background."
    case .mediaFirst:
      "Music and video stay foreground, while meetings move behind them."
    case .balanced:
      "Visible apps start at Normal priority and remain close to their manual levels."
    case .custom:
      "Waves uses the content type and priority shown below for each app."
    }
  }

  private var focusModeDescription: String {
    switch store.preferences.adaptiveFocusMode {
    case .assignedPriorities:
      "Uses only the priorities you assign. The frontmost app receives no automatic promotion."
    case .followFrontApp:
      "An audible frontmost app becomes Foreground. Voice and meeting apps must contain speech before they take focus."
    case .smartHybrid:
      "Promotes an audible frontmost app by one tier while keeping explicit priorities as guardrails."
    }
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
      .accessibilityLabel("Managed audio \(band.label) gain")
      .accessibilityValue(formattedGain)
    }
  }

  private var formattedGain: String {
    let prefix = gainDB > 0 ? "+" : ""
    return "\(prefix)\(String(format: "%.1f", gainDB)) dB"
  }
}
