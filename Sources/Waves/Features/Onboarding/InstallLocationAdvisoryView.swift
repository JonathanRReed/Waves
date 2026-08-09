import SwiftUI

struct InstallLocationAdvisoryView: View {
  @Environment(\.wavesTheme) private var theme

  let classification: InstallLocationClassification
  let openInFinder: () -> Void
  let continueForNow: () -> Void

  var body: some View {
    ZStack {
      WavesBackground()

      VStack(spacing: 24) {
        WavesMark(size: 68, live: false)

        VStack(spacing: 8) {
          Text("Install Waves for the best experience")
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
          Text(detail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(spacing: 10) {
          Button(classification.finderActionTitle, action: openInFinder)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          Button("Continue for Now", action: continueForNow)
            .buttonStyle(.bordered)
        }

        Text("Waves never moves or copies itself without your action.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: 480)
      .padding(40)
    }
    .accessibilityElement(children: .contain)
  }

  private var detail: String {
    switch classification {
    case .mountedDiskImage:
      "Waves is running from its disk image. Drag it to Applications so updates, login launch, and macOS permissions stay attached to one installed copy."
    case .readOnlyExternal:
      "Waves is running from a read-only location. Move it to Applications before completing setup so macOS can keep one stable app identity."
    case .applications, .ordinaryWritable:
      "Move Waves to Applications before completing setup so macOS can keep one stable app identity."
    }
  }
}
