import SwiftUI
import WavesAudioCore

enum MenuBarRowAccessibility {
  static func moreActionsLabel(for app: AudioApp) -> String {
    MixerRowAccessibility.moreActionsLabel(for: app)
  }

  static func volumeValue(for app: AudioApp) -> String {
    "\(Int((app.desiredVolume * 100).rounded()))%"
  }
}

struct MenuBarAppRow: View {
  @Environment(AppStore.self) private var store
  @Environment(\.wavesTheme) private var theme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let app: AudioApp
  @State private var animateMuteChange = false

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 7) {
        AppIconView(app: app)
          .frame(width: 20, height: 20)

        Text(app.displayName)
          .font(.caption.weight(.medium))
          .lineLimit(1)
          .layoutPriority(1)

        RoutingStateDot(app: app)

        // Boost and EQ are only reachable through More here, so say when they
        // are on, in the main window's colors.
        if app.volumeBoost > 1 {
          Text("\(Int(app.volumeBoost))x")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(theme.accent)
            .fixedSize()
            .help("Boost is \(Int(app.volumeBoost))x")
            .accessibilityLabel("Boost \(Int(app.volumeBoost))x")
        }

        if equalizerIsEnabled {
          Image(systemName: "slider.horizontal.3")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.accent)
            .help("Equalizer is on")
            .accessibilityLabel("Equalizer on")
        }

        AdaptiveGainTag(appID: app.logicalID, appName: app.displayName)

        Spacer(minLength: 4)

        Text(MenuBarRowAccessibility.volumeValue(for: app))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 34, alignment: .trailing)
          .contentTransition(.numericText())
          .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: app.desiredVolume
          )
          .accessibilityHidden(true)

        muteButton

        Menu {
          MixerRowContextMenuItems(app: app, opensMainWindow: true)
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .wavesHoverHighlight()
        .accessibilityLabel(MenuBarRowAccessibility.moreActionsLabel(for: app))
        .help(MixerRowAccessibility.moreActionsHelp)
      }

      TaperedVolumeSlider(app: app, semantics: volumeSemantics)
        .padding(.leading, 28)
    }
    .overlay(alignment: .bottomLeading) {
      if showsLevelMeter {
        RowLevelMeterHost(appID: app.logicalID)
      }
    }
    .contextMenu {
      MixerRowContextMenuItems(app: app, opensMainWindow: true)
    }
    .accessibilityActions {
      ForEach(accessibilityActions) { action in
        Button(action.name) { action.perform() }
      }
    }
  }

  private var muteButton: some View {
    Button {
      store.setMuted(!app.isMuted, for: app)
      if !reduceMotion { animateMuteChange.toggle() }
    } label: {
      Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        .contentTransition(
          reduceMotion ? .identity : .symbolEffect(.replace.downUp)
        )
        .symbolEffect(.bounce, value: animateMuteChange)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.wavesIcon)
    .help(muteSemantics.help)
    .accessibilityLabel(muteSemantics.label)
    .accessibilityValue(muteSemantics.value ?? "")
    .accessibilityHint(muteSemantics.hint)
    .accessibilitySortPriority(muteSemantics.sortPriority)
    .sensoryFeedback(.selection, trigger: app.isMuted)
    .disabled(!muteSemantics.isEnabled)
  }

  private var volumeSemantics: MixerControlAccessibilitySemantics {
    accessibilitySemantics(for: .volume)
  }

  private var muteSemantics: MixerControlAccessibilitySemantics {
    accessibilitySemantics(for: .mute)
  }

  private var accessibilityActions: [MixerRowAccessibilityAction] {
    MixerRowAccessibility.actions(
      app: app,
      isExcluded: false,
      onPin: { store.togglePinned(app) },
      onExclusionChange: { store.setExcluded($0, for: app) }
    )
  }

  private func accessibilitySemantics(
    for control: MixerRowAccessibilityControl
  ) -> MixerControlAccessibilitySemantics {
    MixerRowAccessibility.semantics(
      for: control,
      app: app,
      isExcluded: false,
      isRecovering: store.isRecovering,
      equalizerIsEnabled: equalizerIsEnabled
    )
  }

  private var equalizerIsEnabled: Bool { store.equalizerSettings(for: app).isEnabled }

  private var showsLevelMeter: Bool {
    !app.isMuted && (app.routingState == .managed || app.routingState == .live)
  }
}
