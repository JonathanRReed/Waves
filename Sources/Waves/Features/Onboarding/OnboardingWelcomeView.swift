import SwiftUI

struct OnboardingWelcomeView: View {
  @Environment(\.wavesTheme) private var theme

  let onContinue: () -> Void

  var body: some View {
    VStack(spacing: 26) {
      WavesMark(size: 82, live: false)

      VStack(spacing: 10) {
        Text("Your Mac, mixed around you")
          .font(.largeTitle.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(
          "Give every compatible app its own volume, mute, output, and sound controls. Waves keeps the work local to this Mac."
        )
        .font(.title3)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 540)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 22) {
        welcomeFact("Per-app control", symbol: "slider.horizontal.3")
        welcomeFact("Local processing", symbol: "lock.shield.fill")
        welcomeFact("About one minute", symbol: "clock.fill")
      }

      Button("Set Up Waves", action: onContinue)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint("Begins the required Audio Capture and readiness setup.")
    }
    .padding(.horizontal, 48)
    .padding(.vertical, 42)
  }

  private func welcomeFact(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .font(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .symbolRenderingMode(.hierarchical)
      .accessibilityElement(children: .combine)
  }
}
