import AppKit
import SwiftUI
import WavesAudioCore

struct MixerRowView: View {
  @Environment(AppStore.self) private var store
  let app: AudioApp
  @State private var animateVolumeChange = false
  @State private var animateMuteChange = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        AppIconView(app: app)
          .scaleEffect(animateVolumeChange ? 1.1 : 1.0)
          .animation(.spring(response: 0.3, dampingFraction: 0.6), value: animateVolumeChange)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(app.displayName)
              .font(.body.weight(.medium))
              .lineLimit(1)

            if app.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .scaleEffect(animateMuteChange ? 1.2 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: animateMuteChange)
            }
          }

          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

          RoutingStateIndicator(state: app.routingState)
        }

        Spacer(minLength: 16)

        Slider(
          value: Binding(
            get: { Double(app.desiredVolume) },
            set: { newValue in
              store.setDesiredVolume(Float(newValue), for: app)
              withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                animateVolumeChange = true
              }
              Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                if !Task.isCancelled {
                  animateVolumeChange = false
                }
              }
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
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)
        .help(sliderHelp)
        .accessibilityLabel("Volume for \(app.displayName)")
        .accessibilityValue("\(Int(app.desiredVolume * 100))%")

        Text("\(Int(app.desiredVolume * 100))%")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)
          .contentTransition(.numericText())
          .animation(.spring(response: 0.2, dampingFraction: 0.7), value: app.desiredVolume)
          .accessibilityLabel("Volume percentage")

        BoostMenu(app: app, compact: false)

        Button {
          store.setMuted(!app.isMuted, for: app)
          withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            animateMuteChange = true
          }
          Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            if !Task.isCancelled {
              animateMuteChange = false
            }
          }
        } label: {
          Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .symbolEffect(.bounce, value: animateMuteChange)
        }
        .buttonStyle(.borderless)
        .help(muteHelp)
        .accessibilityLabel(app.isMuted ? "Unmute \(app.displayName)" : "Mute \(app.displayName)")
      }

      if app.routingState == .error, let notes = app.notes {
        Text(notes)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 40)
      }
    }
    .contextMenu {
      Button(app.isPinned ? "Unpin" : "Pin") {
        store.togglePinned(app)
      }
    }
  }

  private var subtitle: String {
    var parts: [String] = []

    if app.isActive {
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
  let app: AudioApp
  @State private var animateVolumeChange = false
  @State private var animateMuteChange = false

  var body: some View {
    HStack(spacing: 8) {
      AppIconView(app: app)
        .frame(width: 18, height: 18)
        .scaleEffect(animateVolumeChange ? 1.15 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: animateVolumeChange)

      Text(app.displayName)
        .lineLimit(1)

      RoutingStateDot(state: app.routingState)

      Spacer()

      Slider(
        value: Binding(
          get: { Double(app.desiredVolume) },
          set: { newValue in
            store.setDesiredVolume(Float(newValue), for: app)
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
              animateVolumeChange = true
            }
            Task {
              try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
              if !Task.isCancelled {
                animateVolumeChange = false
              }
            }
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
      .frame(width: 110)
      .padding(.trailing, 4)
      .help(sliderHelp)
      .accessibilityLabel("Volume for \(app.displayName)")
      .accessibilityValue("\(Int(app.desiredVolume * 100))%")
      .accessibilityHint("Adjusts the per-app volume target.")

      BoostMenu(app: app, compact: true)

      Button {
        store.setMuted(!app.isMuted, for: app)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
          animateMuteChange = true
        }
        Task {
          try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
          if !Task.isCancelled {
            animateMuteChange = false
          }
        }
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
        .font(compact ? .caption.monospacedDigit() : .callout.monospacedDigit())
        .frame(width: compact ? 34 : 42)
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
      .orange
    case .recent:
      .secondary
    case .error:
      .red
    }
  }
}

private struct RoutingStateIndicator: View {
  let state: RoutingState

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(state.displayName)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .help(Text(helpText))
    .accessibilityLabel(Text(helpText))
  }

  private var color: Color { state.indicatorColor }

  private var helpText: String {
    switch state {
    case .managed:
      "Managed route is active."
    case .live:
      "Live audio source detected."
    case .monitorOnly:
      "Waves can see this app, but control is not active yet."
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
    Circle()
      .fill(color)
      .frame(width: 7, height: 7)
      .help(Text(state.displayName))
      .accessibilityLabel(Text("Route state: \(state.displayName)"))
  }

  private var color: Color { state.indicatorColor }
}

struct AppIconView: View {
  let app: AudioApp

  var body: some View {
    if let iconTIFFData = app.iconTIFFData, let icon = NSImage(data: iconTIFFData) {
      Image(nsImage: icon)
        .resizable()
        .scaledToFit()
        .frame(width: 28, height: 28)
    } else {
      Image(systemName: app.iconName ?? "app")
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
  }
}
