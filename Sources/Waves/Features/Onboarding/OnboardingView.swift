import SwiftUI

struct OnboardingView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Welcome to Waves")
        .font(.largeTitle.weight(.semibold))

      Text("Use onboarding to verify the managed audio path before trusting release coverage.")
        .foregroundStyle(.secondary)

      SetupStepRow(
        title: "Install managed audio component",
        isComplete: store.onboarding.audioComponentInstalled,
        detail: "The installer package can add this later."
      )
      SetupStepRow(
        title: "Grant permissions",
        isComplete: store.onboarding.permissionsGranted,
        detail: "Permissions stay explicit and local."
      )
      SetupStepRow(
        title: "Validate output device visibility",
        isComplete: store.onboarding.outputDeviceVisible,
        detail: "Required for route recovery."
      )
      SetupStepRow(
        title: "Exercise route recovery",
        isComplete: store.onboarding.routeHealthReady,
        detail: "Device changes should recover without app restarts."
      )

      Spacer()
    }
    .padding(28)
  }
}
