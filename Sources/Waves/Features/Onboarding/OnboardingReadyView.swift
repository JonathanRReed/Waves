import SwiftUI

struct OnboardingReadyView: View {
  @Environment(\.wavesTheme) private var theme

  let warnings: [RequiredReadinessIssue]
  let isCompleting: Bool
  let completionError: String?
  let onStartMixing: () -> Void
  let onTakeTour: () -> Void
  let onRepair: (GuidedSetupRepairAction) -> Void

  init(
    warnings: [RequiredReadinessIssue] = [],
    isCompleting: Bool,
    completionError: String?,
    onStartMixing: @escaping () -> Void,
    onTakeTour: @escaping () -> Void,
    onRepair: @escaping (GuidedSetupRepairAction) -> Void = { _ in }
  ) {
    self.warnings = warnings
    self.isCompleting = isCompleting
    self.completionError = completionError
    self.onStartMixing = onStartMixing
    self.onTakeTour = onTakeTour
    self.onRepair = onRepair
  }

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
        Text(readyDetail)
          .font(.title3)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 520)
          .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(warnings) { warning in
        warningSurface(warning)
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

  private var readyDetail: String {
    warnings.isEmpty
      ? "Audio Capture, your output, and the managed-audio service are ready for the real mixer."
      : "Core mixing is ready. You can start now or repair managed routes first."
  }

  private func warningSurface(_ warning: RequiredReadinessIssue) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "info.circle.fill")
        .font(.title3)
        .foregroundStyle(theme.accent)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(warning.title)
          .font(.headline)
        Text(warning.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if let action = warning.repairAction {
        Button("Recover Routes") {
          onRepair(action)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isCompleting)
      }
    }
    .padding(14)
    .frame(maxWidth: 560)
    .wavesCard(cornerRadius: 14)
    .accessibilityElement(children: .contain)
  }
}
