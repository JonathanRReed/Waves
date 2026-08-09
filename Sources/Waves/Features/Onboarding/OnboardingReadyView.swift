import SwiftUI

struct OnboardingReadyView: View {
  @Environment(\.wavesTheme) private var theme

  let isCompleting: Bool
  let completionError: String?
  let onStartMixing: () -> Void
  let onTakeTour: () -> Void

  var body: some View {
    VStack(spacing: 26) {
      ZStack {
        Circle()
          .fill(theme.success.opacity(0.14))
          .frame(width: 92, height: 92)
        Image(systemName: "checkmark")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(theme.success)
      }
      .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Waves is ready")
          .font(.largeTitle.weight(.semibold))
        Text("Audio Capture, your output, and the managed-audio service are ready for the real mixer.")
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 520)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let completionError {
        Label(completionError, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(theme.warning)
          .frame(maxWidth: 520)
      }

      VStack(spacing: 10) {
        Button(action: onStartMixing) {
          HStack(spacing: 8) {
            if isCompleting {
              ProgressView()
                .controlSize(.small)
            }
            Text("Start Mixing")
          }
          .frame(minWidth: 190)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(isCompleting)

        Button("Take the 60-Second Tour", action: onTakeTour)
          .buttonStyle(.bordered)
          .disabled(isCompleting)
      }

      Text("The tour is optional. End Tour or press Escape at any time.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 48)
    .padding(.vertical, 38)
  }
}
