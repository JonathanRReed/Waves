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

      Slider(
        value: Binding(
          get: { Double(app.desiredVolume) },
          set: { newValue in
            store.setDesiredVolume(Float(newValue), for: app)
          }
        ),
        in: 0...1,
        onEditingChanged: { isEditing in
          if !isEditing {
            store.commitDesiredVolume(for: app)
          }
        }
      )
      .controlSize(.small)
      .tint(theme.accent)
      .padding(.leading, 28)
      .help(volumeSemantics.help)
      .accessibilityLabel(volumeSemantics.label)
      .accessibilityValue(volumeSemantics.value ?? "")
      .accessibilityHint(volumeSemantics.hint)
      .accessibilitySortPriority(volumeSemantics.sortPriority)
      .accessibilityAdjustableAction { direction in
        adjustVolume(direction)
      }
      .disabled(!volumeSemantics.isEnabled)
    }
    .overlay(alignment: .bottomLeading) {
      if showsLevelMeter {
        RowLevelMeter(rms: meterRMS, peak: meterPeak)
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

  private var routePolicy: MixerRouteControlPolicy {
    MixerRouteControlPolicy(app: app)
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

  private var meterRMS: Float { store.liveLevels[app.logicalID]?.rms ?? 0 }
  private var meterPeak: Float { store.liveLevels[app.logicalID]?.peak ?? 0 }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
    guard routePolicy.allowsAudioControl else { return }
    let step: Float = 0.05
    let nextValue: Float

    switch direction {
    case .increment:
      nextValue = min(app.desiredVolume + step, 1)
    case .decrement:
      nextValue = max(app.desiredVolume - step, 0)
    @unknown default:
      return
    }

    store.setDesiredVolume(nextValue, for: app)
    store.commitDesiredVolume(for: app)
  }
}
