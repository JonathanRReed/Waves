import SwiftUI

struct WhatsNewCard: View {
  @Environment(\.wavesTheme) private var theme

  let onTakeTour: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        WavesMark(size: 38, live: true)
        VStack(alignment: .leading, spacing: 3) {
          Text("What’s New in Waves")
            .font(.title3.weight(.semibold))
          Text("Profiles that bring back your whole mix, and sound that behaves.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button {
          onDismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss What’s New")
      }

      VStack(alignment: .leading, spacing: 8) {
        whatsNewLine("Save Current Mix, with EQ and outputs in profiles", symbol: "square.stack.3d.up.fill")
        whatsNewLine("Call muting that can follow the microphone", symbol: "phone.fill")
        whatsNewLine("Sliders that follow loudness, and click-free changes", symbol: "speaker.wave.2.fill")
        whatsNewLine("Shortcuts recipes and a bundled command-line tool", symbol: "keyboard")
      }

      HStack {
        Button("Not Now", action: onDismiss)
          .buttonStyle(.bordered)
        Spacer()
        Button("Take the 60-Second Tour", action: onTakeTour)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(18)
    .frame(width: 390)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(theme.accent.opacity(0.22))
    }
    .shadow(color: .black.opacity(0.15), radius: 22, y: 9)
  }

  private func whatsNewLine(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .font(.callout)
      .symbolRenderingMode(.hierarchical)
  }
}
