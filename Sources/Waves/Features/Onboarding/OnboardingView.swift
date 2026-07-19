import SwiftUI
import WavesAudioCore

struct OnboardingView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorSchemeContrast) private var contrast

  private let requiredStepCount = 5

  var completionProgress: Double {
    let completedSteps = [
      store.onboarding.hasCompletedPrivacySetup,
      store.onboarding.audioComponentInstalled,
      captureIsAuthorized,
      store.onboarding.outputDeviceVisible,
      store.onboarding.routeHealthReady,
    ].filter { $0 }.count
    return Double(completedSteps) / Double(requiredStepCount)
  }

  var isFullyComplete: Bool {
    store.onboarding.hasCompletedPrivacySetup
      && store.onboarding.audioComponentInstalled
      && captureIsAuthorized
      && store.onboarding.outputDeviceVisible
      && store.onboarding.routeHealthReady
  }

  private var captureIsAuthorized: Bool {
    store.onboarding.captureAuthorization == .authorized
  }

  private var isUnsupportedOS: Bool {
    if #available(macOS 14.2, *) {
      return false
    }
    return true
  }

  var body: some View {
    ScrollView {
      checklist
        .padding(20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      refreshLiveStatusIfAllowed()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        refreshLiveStatusIfAllowed()
      }
    }
  }

  private var checklist: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 14) {
        WavesMark(size: 48, live: isFullyComplete)

        VStack(alignment: .leading, spacing: 6) {
          Text("Welcome to Waves")
            .font(.title2.weight(.semibold))

          Text(isFullyComplete
            ? "You're all set! Waves is ready to manage your per-app audio."
            : "Start with the local-processing choice, then verify macOS audio authorization and route readiness.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      ProgressView(value: completionProgress)
        .tint(isFullyComplete ? WavesDesign.success : WavesDesign.accent)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int((completionProgress * Double(requiredStepCount)).rounded())) of \(requiredStepCount) required steps complete")

      VStack(alignment: .leading, spacing: 16) {
        ForEach(0..<6, id: \.self) { index in
          EnhancedSetupStepRow(
            title: title(for: index),
            detail: detail(for: index),
            isComplete: isStepComplete(at: index),
            action: actionLabel(for: index),
            canPerformAction: canPerformAction(for: index),
            badge: index == 5 ? "Optional" : nil,
            crossReference: crossReference(for: index),
            secondaryAction: secondaryAction(for: index),
            onSecondaryAction: { handleSecondaryAction(for: index) }
          ) {
            handleAction(for: index)
          }
        }
      }

      if isFullyComplete {
        VStack(alignment: .leading, spacing: 12) {
          Text("Ready to use")
            .font(.headline)
            .foregroundStyle(WavesDesign.success)

          Text("You can now:")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 8) {
            readyRow("Adjust individual app volumes from the menu bar")
            readyRow("Pin your favorite apps for quick access")
            readyRow("Group apps into profiles, with optional saved levels")
            readyRow("Enable optional global shortcuts separately")
          }
        }
        .padding(16)
        .background(WavesDesign.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WavesDesign.success.opacity(contrast == .increased ? 0.6 : 0.3))
        )
      }

      HStack(spacing: 12) {
        if store.isAudioRunning {
          Button("Refresh Status") {
            store.refresh()
          }
          .wavesGlassProminentButton()
        } else if store.preferences.hasCompletedPrivacySetup {
          Button("Retry Start Waves") {
            Task { await store.acceptPrivacySetupAndStart() }
          }
          .wavesGlassProminentButton()
          .disabled(isStartupProgressing)
        } else {
          Button("Continue and Start Waves") {
            Task { await store.acceptPrivacySetupAndStart() }
          }
          .wavesGlassProminentButton()
          .disabled(isStartupProgressing)
        }

        if store.onboarding.launchAtLoginRequiresApproval {
          VStack(alignment: .leading, spacing: 6) {
            Label("Launch at Login needs approval in System Settings > General > Login Items.", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(WavesDesign.warning)
            Button("Open Login Items") {
              store.openLoginItemsSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        } else if !store.onboarding.launchAtLoginEnabled {
          Button("Enable Launch at Login") {
            store.launchAtLoginEnabled = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private func readyRow(_ text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(WavesDesign.success)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var isStartupProgressing: Bool {
    switch store.startupState {
    case .savingPrivacyConsent, .startingAudio:
      return true
    case .idle, .awaitingPrivacy, .running, .failed, .shuttingDown:
      return false
    }
  }

  private func refreshLiveStatusIfAllowed() {
    guard store.preferences.hasCompletedPrivacySetup, store.isAudioRunning else { return }
    store.refresh(announce: false)
  }

  private func title(for index: Int) -> String {
    switch index {
    case 0: "Accept local processing"
    case 1: "Confirm managed audio support"
    case 2: "Check audio capture authorization"
    case 3: "Validate output device visibility"
    case 4: "Test route recovery"
    case 5: "Enable keyboard shortcut permission"
    default: "Setup"
    }
  }

  private func isStepComplete(at index: Int) -> Bool {
    switch index {
    case 0: store.onboarding.hasCompletedPrivacySetup
    case 1: store.onboarding.audioComponentInstalled
    case 2: captureIsAuthorized
    case 3: store.onboarding.outputDeviceVisible
    case 4: store.onboarding.routeHealthReady
    case 5: store.onboarding.accessibilityPermissionGranted
    default: false
    }
  }

  private func canPerformAction(for index: Int) -> Bool {
    switch index {
    case 0:
      return !store.onboarding.hasCompletedPrivacySetup && !isStartupProgressing
    case 1:
      return store.onboarding.hasCompletedPrivacySetup
        && store.isAudioRunning
        && !store.onboarding.audioComponentInstalled
        && !isUnsupportedOS
    case 2:
      guard store.onboarding.hasCompletedPrivacySetup, store.isAudioRunning else { return false }
      switch store.onboarding.captureAuthorization {
      case .authorized, .unsupported:
        return false
      case .notGranted, .undetermined, .probeFailed, nil:
        return true
      }
    case 3:
      return store.onboarding.hasCompletedPrivacySetup
        && store.isAudioRunning
        && !store.onboarding.outputDeviceVisible
    case 4:
      return store.onboarding.hasCompletedPrivacySetup
        && store.isAudioRunning
        && captureIsAuthorized
        && store.onboarding.outputDeviceVisible
        && !store.onboarding.routeHealthReady
    case 5:
      return store.onboarding.hasCompletedPrivacySetup
        && !store.onboarding.accessibilityPermissionGranted
    default:
      return false
    }
  }

  private func detail(for index: Int) -> String {
    switch index {
    case 0:
      if store.onboarding.hasCompletedPrivacySetup {
        return "The local-processing explanation is accepted and saved. Audio is processed on this Mac and is not recorded or transmitted."
      }
      return "Waves uses private Core Audio process taps. Selected app audio is processed locally in real time and is not recorded or transmitted. macOS may ask for audio-capture or Microphone permission after Continue; Accessibility is optional and separate."
    case 1:
      guard store.onboarding.hasCompletedPrivacySetup else {
        return "Finish the local-processing step before Waves checks managed audio support."
      }
      if isUnsupportedOS {
        return "Per-app audio routing requires macOS 14.2 or newer. Update macOS to continue."
      }
      if store.onboarding.audioComponentInstalled {
        return "This Mac supports the Core Audio process-tap path Waves uses for managed per-app routing."
      }
      if !store.isAudioRunning {
        return "Waves has not started the audio backend yet. Retry startup to check managed audio support."
      }
      return "Waves could not confirm managed process-tap support. Re-check after verifying your macOS version."
    case 2:
      return captureAuthorizationDetail
    case 3:
      guard store.onboarding.hasCompletedPrivacySetup else {
        return "Finish the local-processing step before Waves reads output-device state."
      }
      if store.onboarding.outputDeviceVisible {
        return "Waves can see the current macOS output device."
      }
      return store.isAudioRunning
        ? "No current output device is visible. Connect speakers or headphones, choose them in macOS Sound settings, then refresh."
        : "Waves has not started the audio backend, so output devices have not been checked."
    case 4:
      guard store.onboarding.hasCompletedPrivacySetup else {
        return "Finish the local-processing step before Waves tests managed routes."
      }
      guard captureIsAuthorized else {
        return "Complete the audio capture authorization step before testing managed route recovery."
      }
      guard store.onboarding.outputDeviceVisible else {
        return "Connect and select an output device before testing managed route recovery."
      }
      return store.onboarding.routeHealthReady
        ? "Managed routes are healthy and will be re-established when the output device changes."
        : "Run recovery to reattach managed Core Audio routes."
    case 5:
      var copy = "Optional: open Accessibility settings only if you want global shortcuts and app-control helpers. Waves never requests Accessibility automatically."
      if !store.preferences.enableKeyboardShortcuts {
        copy += " Global shortcuts are currently turned off in General settings."
      }
      return copy
    default:
      return ""
    }
  }

  private var captureAuthorizationDetail: String {
    guard store.onboarding.hasCompletedPrivacySetup else {
      return "Finish the local-processing step before Waves runs any capture-capable authorization probe."
    }
    guard store.isAudioRunning else {
      return "Waves has not started the audio backend, so macOS audio authorization has not been checked."
    }
    switch store.onboarding.captureAuthorization {
    case .authorized:
      return "Authorized. macOS allows Waves to process selected app audio locally."
    case .notGranted:
      return "Not granted. Allow audio recording for Waves in System Settings, then refresh status."
    case .undetermined:
      return "Undetermined. macOS has not returned a decisive authorization state yet; re-check permission."
    case let .probeFailed(nativeStatus):
      return "Probe failed with native status \(nativeStatus). This is not the same as a denial; re-check before changing privacy settings."
    case .unsupported:
      return "Unsupported. This macOS version does not provide the process-tap authorization path Waves requires."
    case nil:
      return "Authorization has not been checked yet. Re-check permission."
    }
  }

  private func actionLabel(for index: Int) -> String {
    switch index {
    case 0: return "Continue and Start Waves"
    case 1: return "Re-check Support"
    case 2:
      return store.onboarding.captureAuthorization == .notGranted
        ? "Open System Settings"
        : "Re-check Permission"
    case 3: return "Refresh Devices"
    case 4: return "Test Recovery"
    case 5: return "Open System Settings"
    default: return "Continue"
    }
  }

  private func crossReference(for index: Int) -> String? {
    switch index {
    case 1: "Audio component"
    case 2: "Audio capture permission"
    case 4: "Route recovery"
    case 5: "Accessibility permission"
    default: nil
    }
  }

  private func secondaryAction(for index: Int) -> String? {
    if index == 0,
       store.onboarding.hasCompletedPrivacySetup,
       case .failed = store.startupState {
      return "Retry Start Waves"
    }
    if index == 4, store.onboarding.routeHealthReady {
      return "Re-test"
    }
    return nil
  }

  private func handleSecondaryAction(for index: Int) {
    switch index {
    case 0:
      Task { await store.acceptPrivacySetupAndStart() }
    case 4:
      store.recoverRoutes()
    default:
      break
    }
  }

  private func handleAction(for index: Int) {
    switch index {
    case 0:
      Task { await store.acceptPrivacySetupAndStart() }
    case 1, 3:
      store.refresh()
    case 2:
      if store.onboarding.captureAuthorization == .notGranted {
        openSystemSettings(privacyPane: "Privacy_Microphone")
      } else {
        store.refreshDiagnostics()
      }
    case 4:
      store.recoverRoutes()
    case 5:
      openSystemSettings(privacyPane: "Privacy_Accessibility")
    default:
      break
    }
  }

  private func openSystemSettings(privacyPane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") {
      NSWorkspace.shared.open(url)
    }
  }
}

private struct EnhancedSetupStepRow: View {
  let title: String
  let detail: String
  let isComplete: Bool
  let action: String
  let canPerformAction: Bool
  var badge: String? = nil
  var crossReference: String? = nil
  var secondaryAction: String? = nil
  var onSecondaryAction: () -> Void = {}
  let onAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isComplete ? "checkmark.circle.fill" : canPerformAction ? "exclamationmark.triangle.fill" : "circle")
          .foregroundStyle(isComplete ? WavesDesign.success : canPerformAction ? WavesDesign.warning : Color.secondary)
          .font(.title3)
          .accessibilityLabel(isComplete ? "Completed" : canPerformAction ? "Needs action" : "Pending")

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(title)
              .font(.headline)
            if let badge {
              Text(badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .accessibilityLabel("Optional step")
            }
          }
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          if let crossReference {
            Text("Also shown as “\(crossReference)” in Settings → Advanced.")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }

        Spacer()

        if canPerformAction {
          Button(action) {
            onAction()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        } else if let secondaryAction {
          Button(secondaryAction) {
            onSecondaryAction()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .padding(12)
    .wavesCard(cornerRadius: 12)
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(isComplete ? WavesDesign.success.opacity(0.3) : canPerformAction ? WavesDesign.warning.opacity(0.3) : Color.secondary.opacity(0.2))
    )
  }
}
