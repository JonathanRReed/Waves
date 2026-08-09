import SwiftUI
import WavesAudioCore

struct SetupRepairView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header

        VStack(spacing: 12) {
          ReadinessChecklistRow(
            title: "Managed audio support",
            detail: audioSupportDetail,
            status: audioSupportState,
            actionTitle: audioSupportState == .ready ? "Re-check" : nil,
            action: { store.refresh(announce: false) }
          )
          ReadinessChecklistRow(
            title: "Audio capture permission",
            detail: captureDetail,
            status: captureState,
            actionTitle: captureActionTitle,
            action: repairCapturePermission
          )
          ReadinessChecklistRow(
            title: "Output device",
            detail: outputDetail,
            status: store.onboarding.outputDeviceVisible ? .ready : .attention,
            actionTitle: store.onboarding.outputDeviceVisible ? nil : "Open Sound Settings",
            action: { SystemSettingsService().open(.soundOutput) }
          )
          ReadinessChecklistRow(
            title: "Managed routes",
            detail: routeDetail,
            status: store.onboarding.routeHealthReady ? .ready : .attention,
            actionTitle: store.onboarding.routeHealthReady ? "Re-test" : "Recover Routes",
            action: { store.recoverRoutes() }
          )

          if store.onboarding.launchAtLoginRequiresApproval {
            ReadinessChecklistRow(
              title: "Launch at login",
              detail: "macOS is waiting for your approval in General > Login Items.",
              status: .attention,
              actionTitle: "Open Login Items",
              action: { store.openLoginItemsSettings() }
            )
          }
        }

        HStack(spacing: 10) {
          Button {
            store.refresh(announce: false)
          } label: {
            Label("Refresh All Checks", systemImage: "arrow.clockwise")
          }
          .wavesGlassProminentButton()
          .disabled(!store.isAudioRunning || store.isRefreshing)

          Button("Redo Guided Setup…") {
            store.runRequiredSetupReplay()
          }
          .buttonStyle(.bordered)

          Button("Take the Mixer Tour") {
            store.startGuidedMixerTour()
          }
          .buttonStyle(.bordered)
        }

        Text(
          "Redo Guided Setup keeps your privacy choice, app levels, profiles, equalizers, theme, and other preferences. Protected macOS permissions still require your confirmation in System Settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onAppear { refreshIfPossible() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { refreshIfPossible() }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      WavesMark(size: 48, live: store.onboarding.routeHealthReady)
      VStack(alignment: .leading, spacing: 5) {
        Text("Setup & Repair")
          .font(.title2.weight(.semibold))
        Text(
          "Waves checks the exact macOS service behind each feature and takes you to the matching fix."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  private var isUnsupportedOS: Bool {
    if #available(macOS 14.2, *) { return false }
    return true
  }

  private var audioSupportState: ReadinessStatus {
    if isUnsupportedOS { return .unavailable }
    return store.onboarding.audioComponentInstalled ? .ready : .attention
  }

  private var audioSupportDetail: String {
    if isUnsupportedOS {
      return "Waves managed audio requires macOS 14.2 or newer. Update macOS to continue."
    }
    return store.onboarding.audioComponentInstalled
      ? "This Mac supports the Core Audio process-tap path used by Waves."
      : "Managed audio support has not been confirmed. Refresh after Waves finishes starting."
  }

  private var captureState: ReadinessStatus {
    switch store.onboarding.captureAuthorization {
    case .authorized: .ready
    case .unsupported: .unavailable
    case .notGranted, .undetermined, .probeFailed, nil: .attention
    }
  }

  private var captureDetail: String {
    switch store.onboarding.captureAuthorization {
    case .authorized:
      "macOS allows Waves to process selected app audio locally."
    case .notGranted:
      "Enable Waves under Privacy & Security, then return here. Waves will re-check automatically."
    case .undetermined, nil:
      "macOS has not returned a decisive audio-capture status. Re-check the permission."
    case .probeFailed(let status):
      "The authorization probe failed with status \(status). Re-check before changing privacy settings."
    case .unsupported:
      "This macOS version does not expose the audio-capture authorization Waves requires."
    }
  }

  private var captureActionTitle: String? {
    switch store.onboarding.captureAuthorization {
    case .authorized, .unsupported:
      nil
    case .notGranted:
      "Open Privacy Settings"
    case .undetermined, .probeFailed, nil:
      "Re-check Permission"
    }
  }

  private func repairCapturePermission() {
    if store.onboarding.captureAuthorization == .notGranted {
      SystemSettingsService().open(.audioCapture)
    } else {
      store.refreshDiagnostics()
    }
  }

  private var outputDetail: String {
    store.onboarding.outputDeviceVisible
      ? "Current output: \(store.currentDeviceName)."
      : "Choose connected speakers or headphones under System Settings > Sound, then return to Waves."
  }

  private var routeDetail: String {
    store.onboarding.routeHealthReady
      ? "Managed routes are healthy and follow the current output device."
      : "Waves can rebuild the process taps and output routes without changing your saved mix."
  }

  private func refreshIfPossible() {
    guard store.preferences.hasCompletedPrivacySetup, store.isAudioRunning else { return }
    store.refresh(announce: false)
  }
}
