import SwiftUI

struct OnboardingReadinessView: View {
  let issues: [RequiredReadinessIssue]
  let isStabilizing: Bool
  let onRepair: (GuidedSetupRepairAction) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 8) {
          Text(heading)
            .font(.title2.weight(.semibold))
          Text(detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if issues.isEmpty {
          checkingSurface
        } else {
          VStack(spacing: 12) {
            ForEach(issues) { issue in
              ReadinessProblemRow(issue: issue) {
                if let action = issue.repairAction { onRepair(action) }
              }
            }
          }

          if isStabilizing {
            Label("Core mixing is ready. Finishing the live check.", systemImage: "checkmark.circle.fill")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: 640, alignment: .leading)
      .padding(.horizontal, 40)
      .padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  private var heading: String {
    issues.isEmpty ? "Checking your Mac" : "A few things need attention"
  }

  private var detail: String {
    issues.isEmpty
      ? "Waves is confirming Audio Capture, your current output, and managed-audio support."
      : "Waves only keeps actionable problems here. Completed checks stay out of the way."
  }

  private var checkingSurface: some View {
    HStack(spacing: 14) {
      ProgressView()
        .controlSize(.small)
      VStack(alignment: .leading, spacing: 3) {
        Text("Verifying live audio readiness")
          .font(.headline)
        Text("This should take only a moment.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(18)
    .wavesCard(cornerRadius: 14)
  }
}

private struct ReadinessProblemRow: View {
  @Environment(\.wavesTheme) private var theme

  let issue: RequiredReadinessIssue
  let repair: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: issue.severity == .blocking ? "exclamationmark.triangle.fill" : "info.circle.fill")
        .font(.title3)
        .foregroundStyle(issue.severity == .blocking ? theme.warning : theme.accent)
        .frame(width: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text(issue.title)
          .font(.headline)
        Text(issue.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let label = issue.continuationLabel {
          Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.accent)
        }
      }

      Spacer(minLength: 12)

      if issue.repairAction != nil {
        Button(actionTitle, action: repair)
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
    .padding(16)
    .wavesCard(cornerRadius: 14)
    .accessibilityElement(children: .contain)
  }

  private var actionTitle: String {
    switch issue.repairAction {
    case .recheck: "Check Again"
    case .openCaptureSettings: "Open System Settings"
    case .openSoundSettings: "Choose Output"
    case .recoverRoutes: "Recover Routes"
    case nil: ""
    }
  }
}
