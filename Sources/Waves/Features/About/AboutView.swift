import SwiftUI

/// The About window: identity, version, and the update check in the first
/// place a Mac user looks for it. Fixed-size, like every native About panel.
struct AboutView: View {
  @Environment(UpdaterService.self) private var updaterService
  @Environment(\.wavesTheme) private var theme

  var body: some View {
    VStack(spacing: 14) {
      WavesMark(size: 72)

      VStack(spacing: 3) {
        Text("Waves")
          .font(.title.weight(.semibold))
        Text("Per-app audio mixer for macOS")
          .font(.callout)
          .foregroundStyle(.secondary)
        Text("Version \(AppVersion.display)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .padding(.top, 2)
      }

      Button("Check for Updates…") {
        updaterService.checkForUpdates()
      }
      .disabled(!updaterService.canCheckForUpdates)
      .wavesGlassProminentButton()

      HStack(spacing: 14) {
        Link("Website", destination: URL(string: "https://waves.jonathanrreed.com")!)
        Link("Source", destination: URL(string: "https://github.com/JonathanRReed/Waves")!)
        Link(
          "Privacy",
          destination: URL(string: "https://waves.jonathanrreed.com/privacy/")!)
      }
      .font(.callout)

      Text("MIT licensed. Audio is processed on this Mac and never leaves it.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 36)
    .padding(.vertical, 28)
    .frame(width: 320)
    .background(WavesBackground())
  }
}
