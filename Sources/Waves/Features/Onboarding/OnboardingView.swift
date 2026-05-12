import SwiftUI

struct OnboardingView: View {
  @Environment(AppStore.self) private var store
  @State private var selectedStep = 0

  private let steps: [(title: String, detail: String, action: String)] = [
    (
      "Confirm managed audio support",
      "Waves uses local Core Audio process taps on macOS 14.2 or newer. Audio stays on this Mac and is only replayed to your selected output device.",
      "Refresh Status"
    ),
    (
      "Validate output device visibility",
      "Waves needs to see your audio output devices to create managed routes. Ensure your speakers or headphones are connected and recognized by macOS.",
      "Refresh Devices"
    ),
    (
      "Exercise route recovery",
      "Route recovery ensures that when you switch audio devices (e.g., from speakers to headphones), Waves automatically re-establishes managed routes without requiring an app restart.",
      "Test Recovery"
    ),
    (
      "Enable keyboard shortcut permission",
      "Optional: grant Accessibility if you want global shortcuts and app-control helpers. Per-app volume routing can work without this permission.",
      "Open System Settings"
    )
  ]

  var completionProgress: Double {
    let completedSteps = [
      store.onboarding.audioComponentInstalled,
      store.onboarding.outputDeviceVisible,
      store.onboarding.routeHealthReady
    ].filter { $0 }.count
    return Double(completedSteps) / 3
  }

  var isFullyComplete: Bool {
    store.onboarding.audioComponentInstalled &&
    store.onboarding.outputDeviceVisible &&
    store.onboarding.routeHealthReady
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Welcome to Waves")
          .font(.largeTitle.weight(.semibold))

        Text(isFullyComplete
          ? "You're all set! Waves is ready to manage your per-app audio."
          : "Let's get Waves set up to manage your per-app audio. Follow the steps below.")
          .foregroundStyle(.secondary)
      }

      ProgressView(value: completionProgress)
        .tint(isFullyComplete ? .green : WavesDesign.accent)

      VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          EnhancedSetupStepRow(
            title: step.title,
            detail: step.detail,
            isComplete: isStepComplete(at: index),
            action: step.action,
            canPerformAction: canPerformAction(for: index)
          ) {
            handleAction(for: index)
          }
        }
      }

      if isFullyComplete {
        VStack(alignment: .leading, spacing: 12) {
          Text("Ready to use")
            .font(.headline)
            .foregroundStyle(.green)

          Text("You can now:")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("Adjust individual app volumes from the menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("Pin your favorite apps for quick access")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("Save and load volume presets")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
              Text("Use keyboard shortcuts (⌘R to refresh)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(16)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      }

      Spacer()

      HStack(spacing: 12) {
        Button("Refresh Status") {
          store.refresh()
          store.refreshDiagnostics()
        }
        .buttonStyle(.borderedProminent)

        if !store.onboarding.launchAtLoginEnabled {
          Button("Enable Launch at Login") {
            store.launchAtLoginEnabled = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(28)
  }

  private func isStepComplete(at index: Int) -> Bool {
    switch index {
    case 0: return store.onboarding.audioComponentInstalled
    case 1: return store.onboarding.outputDeviceVisible
    case 2: return store.onboarding.routeHealthReady
    case 3: return store.onboarding.accessibilityPermissionGranted
    default: return false
    }
  }

  private func canPerformAction(for index: Int) -> Bool {
    switch index {
    case 0: return !store.onboarding.audioComponentInstalled
    case 1: return !store.onboarding.outputDeviceVisible
    case 2: return store.onboarding.outputDeviceVisible && !store.onboarding.routeHealthReady
    case 3: return !store.onboarding.accessibilityPermissionGranted
    default: return false
    }
  }

  private func handleAction(for index: Int) {
    switch index {
    case 0:
      store.refresh()
    case 1:
      store.refresh()
    case 2:
      store.recoverRoutes()
    case 3:
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
      }
    default:
      break
    }
  }
}

private struct EnhancedSetupStepRow: View {
  let title: String
  let detail: String
  let isComplete: Bool
  let action: String
  let canPerformAction: Bool
  let onAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isComplete ? "checkmark.circle.fill" : canPerformAction ? "exclamationmark.triangle.fill" : "circle")
          .foregroundStyle(isComplete ? .green : canPerformAction ? WavesDesign.warning : .secondary)
          .font(.title3)

        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()

        if canPerformAction {
          Button(action) {
            onAction()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isComplete ? Color.green.opacity(0.3) : canPerformAction ? WavesDesign.warning.opacity(0.3) : Color.secondary.opacity(0.2))
    )
  }
}
