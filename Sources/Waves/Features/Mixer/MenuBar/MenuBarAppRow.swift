import SwiftUI
import WavesAudioCore

enum MenuBarRowAccessibility {
  static func moreActionsLabel(for app: AudioApp) -> String {
    "More actions for \(app.displayName)"
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
        .accessibilityLabel(MenuBarRowAccessibility.moreActionsLabel(for: app))
        .help("More controls")
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
    .buttonStyle(.borderless)
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
      equalizerIsEnabled: store.equalizerSettings(for: app).isEnabled
    )
  }

  private var showsLevelMeter: Bool {
    !app.isMuted && (app.routingState == .managed || app.routingState == .live)
  }
}
