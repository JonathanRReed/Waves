import SwiftUI

struct OnboardingView: View {
  @Environment(AppStore.self) private var store
  @State private var selectedStep = 0

  private let steps: [(title: String, detail: String, action: String)] = [
    (
      "Install managed audio component",
      "Waves requires a managed audio component to intercept and control per-app audio. This component runs locally and never sends audio data outside your Mac.",
      "Install Component"
    ),
    (
      "Grant permissions",
      "Waves needs accessibility and screen recording permissions to detect running apps and manage their audio streams. These permissions are required for macOS audio routing.",
      "Open System Settings"
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
    )
  ]

  var completionProgress: Double {
    let completedSteps = [
      store.onboarding.audioComponentInstalled,
      store.onboarding.permissionsGranted,
      store.onboarding.outputDeviceVisible,
      store.onboarding.routeHealthReady
    ].filter { $0 }.count
    return Double(completedSteps) / Double(steps.count)
  }

  var isFullyComplete: Bool {
    store.onboarding.audioComponentInstalled &&
    store.onboarding.permissionsGranted &&
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
    case 1: return store.onboarding.permissionsGranted
    case 2: return store.onboarding.outputDeviceVisible
    case 3: return store.onboarding.routeHealthReady
    default: return false
    }
  }

  private func canPerformAction(for index: Int) -> Bool {
    switch index {
    case 0: return !store.onboarding.audioComponentInstalled
    case 1: return !store.onboarding.permissionsGranted
    case 2: return !store.onboarding.outputDeviceVisible
    case 3: return store.onboarding.outputDeviceVisible && !store.onboarding.routeHealthReady
    default: return false
    }
  }

  private func handleAction(for index: Int) {
    switch index {
    case 0:
      store.refresh()
    case 1:
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    case 2:
      store.refresh()
    case 3:
      store.recoverRoutes()
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
