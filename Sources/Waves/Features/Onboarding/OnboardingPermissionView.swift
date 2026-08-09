import SwiftUI

struct OnboardingPermissionView: View {
  @Environment(\.wavesTheme) private var theme

  let isWaiting: Bool
  let startupError: String?
  let onContinue: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text(isWaiting ? "Waiting for macOS" : "Let Waves hear the apps you choose")
            .font(.title2.weight(.semibold))
          Text(
            isWaiting
              ? "Finish the Audio Capture request in macOS. Waves will check the result when you return."
              : "Waves needs Audio Capture access to process selected app audio and apply your mix. It does not record or upload audio."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 16) {
          permissionFact(
            "Processed locally",
            detail: "Selected audio stays in memory on this Mac.",
            symbol: "lock.shield.fill"
          )
          permissionFact(
            "You stay in control",
            detail: "macOS presents the permission. Waves cannot grant it for you.",
            symbol: "hand.raised.fill"
          )
          permissionFact(
            "No Accessibility access",
            detail: "Waves uses system-registered shortcuts and never reads general keystrokes.",
            symbol: "accessibility"
          )
        }
        .padding(20)
        .wavesCard(cornerRadius: 14)

        if let startupError {
          Label(startupError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(theme.error)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
          Spacer()
          if isWaiting {
            ProgressView("Waiting for macOS")
              .controlSize(.small)
          } else {
            Button("Continue", action: onContinue)
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .keyboardShortcut(.defaultAction)
              .accessibilityHint("Asks macOS for Audio Capture access.")
          }
        }
      }
      .frame(maxWidth: 620, alignment: .leading)
      .padding(.horizontal, 40)
      .padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private func permissionFact(
    _ title: String,
    detail: String,
    symbol: String
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.body.weight(.semibold))
        .foregroundStyle(theme.accent)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
