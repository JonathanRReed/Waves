import AppKit
import SwiftUI
import WavesAudioCore

struct MixerRowView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let app: AudioApp
  @State private var animateMuteChange = false

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 10) {
        AppIconView(app: app)

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(app.displayName)
              .font(.callout.weight(.medium))
              .lineLimit(1)

            if app.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pinned")
            }
          }

          HStack(spacing: 6) {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)

            RoutingStateIndicator(state: app.routingState)
          }
        }
        .frame(minWidth: 150, idealWidth: 240, maxWidth: .infinity, alignment: .leading)

        Spacer(minLength: 10)

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
        .tint(WavesDesign.accent)
        .frame(minWidth: 150, idealWidth: 210, maxWidth: 250)
        .help(sliderHelp)
        .accessibilityLabel("Volume for \(app.displayName)")
        .accessibilityValue("\(Int(app.desiredVolume * 100))%")
        .accessibilityHint("Adjusts the per-app volume target.")
        .accessibilityAdjustableAction { direction in
          adjustVolume(direction)
        }

        Text("\(Int(app.desiredVolume * 100))%")
          .font(.caption.monospacedDigit().weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 40, alignment: .trailing)
          .contentTransition(.numericText())
          .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: app.desiredVolume)
          .accessibilityHidden(true)

        BoostMenu(app: app, compact: false)

        Button {
          store.setMuted(!app.isMuted, for: app)
          if !reduceMotion { animateMuteChange.toggle() }
        } label: {
          Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .symbolEffect(.bounce, value: animateMuteChange)
        }
        .buttonStyle(.borderless)
        .help(muteHelp)
        .accessibilityLabel(app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
        .sensoryFeedback(.selection, trigger: app.isMuted)
      }

      if app.routingState == .error, let notes = app.notes {
        Text(notes)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 40)
      }
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
    .contextMenu {
      Button(app.isPinned ? "Unpin" : "Pin") {
        store.togglePinned(app)
      }
    }
    .accessibilityAction(named: app.isPinned ? "Unpin" : "Pin") {
      store.togglePinned(app)
    }
  }

  private var subtitle: String {
    var parts: [String] = []

    if app.routingState == .live {
      parts.append("Playing audio")
    } else if app.routingState == .managed && !app.isMuted && max(app.peakLevel, app.rmsLevel) > 0.001 {
      parts.append("Playing audio")
    } else if app.isActive {
      parts.append("Frontmost app")
    }

    if app.category != .unknown, app.category != .system {
      parts.append(app.category.displayName)
    } else if parts.isEmpty {
      parts.append("Running app")
    }

    return parts.joined(separator: ", ")
  }

  private var canControlAudio: Bool {
    app.routingState == .managed
  }

  private var sliderHelp: Text {
    canControlAudio
      ? Text("Adjust \(app.displayName) volume")
      : Text("Adjust to enroll \(app.displayName) in managed routing.")
  }

  private var muteHelp: Text {
    canControlAudio
      ? Text(app.isMuted ? "Unmute" : "Mute")
      : Text("Mute to enroll \(app.displayName) in managed routing.")
  }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
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

private struct MixerRowHelpers {
  static func canControlAudio(_ app: AudioApp) -> Bool {
    app.routingState == .managed
  }

  static func sliderHelp(for app: AudioApp) -> Text {
    canControlAudio(app)
      ? Text("Adjust \(app.displayName) volume")
      : Text("Adjust to enroll \(app.displayName) in managed routing.")
  }

  static func muteHelp(for app: AudioApp) -> Text {
    canControlAudio(app)
      ? Text(app.isMuted ? "Unmute" : "Mute")
      : Text("Mute to enroll \(app.displayName) in managed routing.")
  }
}

struct CompactMixerRow: View {
  @Environment(AppStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let app: AudioApp
  @State private var animateMuteChange = false

  var body: some View {
    HStack(spacing: 8) {
      AppIconView(app: app)
        .frame(width: 18, height: 18)

      Text(app.displayName)
        .lineLimit(1)

      RoutingStateDot(state: app.routingState)

      Spacer()

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
      .tint(WavesDesign.accent)
      .frame(width: 110)
      .padding(.trailing, 4)
      .help(sliderHelp)
      .accessibilityLabel("Volume for \(app.displayName)")
      .accessibilityValue("\(Int(app.desiredVolume * 100))%")
      .accessibilityHint("Adjusts the per-app volume target.")
      .accessibilityAdjustableAction { direction in
        adjustVolume(direction)
      }

      BoostMenu(app: app, compact: true)

      Button {
        store.setMuted(!app.isMuted, for: app)
        if !reduceMotion { animateMuteChange.toggle() }
      } label: {
        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .symbolEffect(.bounce, value: animateMuteChange)
      }
      .buttonStyle(.borderless)
      .help(muteHelp)
      .accessibilityLabel(app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
      .accessibilityHint(app.isMuted ? "Restores audio for this app." : "Silences this app.")
    }
  }

  private var canControlAudio: Bool {
    MixerRowHelpers.canControlAudio(app)
  }

  private var sliderHelp: Text {
    MixerRowHelpers.sliderHelp(for: app)
  }

  private var muteHelp: Text {
    MixerRowHelpers.muteHelp(for: app)
  }

  private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
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

private struct BoostMenu: View {
  @Environment(AppStore.self) private var store
  let app: AudioApp
  let compact: Bool

  private let boostOptions: [Float] = [1, 2, 3, 4]

  var body: some View {
    Menu {
      ForEach(boostOptions, id: \.self) { boost in
        Button("\(Int(boost))x") {
          store.setVolumeBoost(boost, for: app)
        }
      }
    } label: {
      Text("\(Int(app.volumeBoost))x")
        .font(compact ? .caption.monospacedDigit() : .caption.monospacedDigit().weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: compact ? 34 : 38)
    }
    .menuStyle(.borderlessButton)
    .help("Set boost for \(app.displayName)")
    .accessibilityLabel("Boost for \(app.displayName)")
    .accessibilityValue("\(Int(app.volumeBoost))x")
  }
}

private extension RoutingState {
  var indicatorColor: Color {
    switch self {
    case .managed:
      .green
    case .live:
      WavesDesign.accent
    case .monitorOnly:
      .secondary
    case .recent:
      .secondary
    case .error:
      .red
    }
  }
}

private struct RoutingStateIndicator: View {
  let state: RoutingState

  @ViewBuilder
  var body: some View {
    if state != .monitorOnly {
      HStack(spacing: 4) {
        Image(systemName: symbolName)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(color)
          .frame(width: 10)

        Text(state.displayName)
          .font(.caption2.weight(.medium))
          .foregroundStyle(color)
          .lineLimit(1)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(backgroundOpacity), in: Capsule())
      .help(Text(helpText))
      .accessibilityLabel(Text(helpText))
    }
  }

  private var color: Color { state.indicatorColor }

  private var backgroundOpacity: Double {
    switch state {
    case .monitorOnly, .recent:
      0.08
    default:
      0.12
    }
  }

  private var symbolName: String {
    switch state {
    case .managed:
      "checkmark.circle.fill"
    case .live:
      "waveform"
    case .monitorOnly:
      "checkmark.circle"
    case .recent:
      "clock.fill"
    case .error:
      "exclamationmark.triangle.fill"
    }
  }

  private var helpText: String {
    switch state {
    case .managed:
      "Managed route is active."
    case .live:
      "Live audio source detected."
    case .monitorOnly:
      "Ready to manage. Move the slider or mute the app to start per-app control."
    case .recent:
      "Recent audio source."
    case .error:
      "Route setup failed."
    }
  }
}

private struct RoutingStateDot: View {
  let state: RoutingState

  var body: some View {
    Image(systemName: symbolName)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .frame(width: 12, height: 12)
      .help(Text(state.displayName))
      .accessibilityLabel(Text("Route state: \(state.displayName)"))
  }

  private var color: Color { state.indicatorColor }

  private var symbolName: String {
    switch state {
    case .managed:
      "checkmark.circle.fill"
    case .live:
      "waveform"
    case .monitorOnly:
      "checkmark.circle"
    case .recent:
      "clock.fill"
    case .error:
      "exclamationmark.triangle.fill"
    }
  }
}

/// Caches decoded app icons so the icon PNG/TIFF is not re-decoded on every
/// SwiftUI body evaluation (which happens on every level/volume update).
@MainActor
private enum AppIconCache {
  static let shared = NSCache<NSString, NSImage>()

  static func icon(for app: AudioApp) -> NSImage? {
    guard let data = app.iconTIFFData else { return nil }
    let key = app.id as NSString
    if let cached = shared.object(forKey: key) {
      return cached
    }
    guard let image = NSImage(data: data) else { return nil }
    shared.setObject(image, forKey: key)
    return image
  }
}

struct AppIconView: View {
  let app: AudioApp

  var body: some View {
    Group {
      if let icon = AppIconCache.icon(for: app) {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
          .frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else {
        Image(systemName: app.iconName ?? "app")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(.tertiary.opacity(0.28), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    }
    // The app name is already shown as text beside the icon, so the icon is
    // decorative for VoiceOver.
    .accessibilityHidden(true)
  }
}
