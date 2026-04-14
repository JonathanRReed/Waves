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
        }

        Spacer(minLength: 16)

        Slider(
          value: Binding(
            get: { Double(app.desiredVolume) },
            set: { store.setDesiredVolume(Float($0), for: app) }
          ),
          in: 0...1
        )
        .controlSize(.small)
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)

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
        .help(app.isMuted ? "Unmute" : "Mute")
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

      Spacer()

      Slider(
        value: Binding(
          get: { Double(app.desiredVolume) },
          set: { store.setDesiredVolume(Float($0), for: app) }
        ),
        in: 0...1
      )
      .controlSize(.small)
      .frame(width: 110)

      Button {
        store.setMuted(!app.isMuted, for: app)
      } label: {
        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
      }
      .buttonStyle(.borderless)
    }
  }
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
