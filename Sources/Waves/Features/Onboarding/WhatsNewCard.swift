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
          Text("What’s New in Waves 1.5")
            .font(.title3.weight(.semibold))
          Text("A more capable mixer, with clearer route truth and faster recovery.")
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
        whatsNewLine("Per-app output and EQ", symbol: "dial.medium.fill")
        whatsNewLine("Truthful Wave Link ownership and recovery", symbol: "point.3.connected.trianglepath.dotted")
        whatsNewLine("Focused keyboard and automation controls", symbol: "keyboard")
        whatsNewLine("Labeled controls and reduced-motion support", symbol: "accessibility")
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
