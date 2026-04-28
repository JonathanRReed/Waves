import AppKit
import SwiftUI
import WavesAudioCore

struct MixerRowView: View {
  @Environment(AppStore.self) private var store
  let app: AudioApp

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        AppIconView(app: app)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(app.displayName)
              .font(.body.weight(.medium))
              .lineLimit(1)

            if app.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            set: { store.setDesiredVolume(Float($0), for: app) }
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

        Text("\(Int(app.desiredVolume * 100))%")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 44, alignment: .trailing)

        Button {
          store.setMuted(!app.isMuted, for: app)
        } label: {
          Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.borderless)
        .help(muteHelp)
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
          set: { store.setDesiredVolume(Float($0), for: app) }
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

      Button {
        store.setMuted(!app.isMuted, for: app)
      } label: {
        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
      }
      .buttonStyle(.borderless)
      .help(muteHelp)
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
