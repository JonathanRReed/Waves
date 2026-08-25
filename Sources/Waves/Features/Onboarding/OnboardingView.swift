import SwiftUI

struct OnboardingView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.wavesTheme) private var theme

  @State private var coordinator: GuidedSetupCoordinator
  @State private var isCompleting = false
  @State private var completionError: String?

  private let onStartTour: () -> Void
  private let onCancel: (() -> Void)?

  init(
    initialPhase: GuidedSetupPhase = .welcome,
    onStartTour: @escaping () -> Void = {},
    onCancel: (() -> Void)? = nil
  ) {
    _coordinator = State(
      initialValue: GuidedSetupCoordinator(initialPhase: initialPhase)
    )
    self.onStartTour = onStartTour
    self.onCancel = onCancel
  }

  var body: some View {
    ZStack {
      WavesBackground()

      VStack(spacing: 0) {
        if coordinator.phase != .welcome {
          progressHeader
          Divider()
        }

        Group {
          switch coordinator.phase {
          case .welcome:
            OnboardingWelcomeView(onContinue: performPrimaryAction)
          case .permissionPreflight, .waitingForMacOS:
            OnboardingPermissionView(
              isWaiting: coordinator.phase == .waitingForMacOS,
              startupError: store.privacySetupError,
              onContinue: performPrimaryAction
            )
          case .readiness:
            OnboardingReadinessView(
              issues: coordinator.issues,
              isStabilizing: store.guidedSetupFacts.isReadyForCoreMixing,
              onRepair: performRepair
            )
          case .ready:
            OnboardingReadyView(
              isCompleting: isCompleting,
              completionError: completionError,
              onStartMixing: { complete(startTour: false) },
              onTakeTour: { complete(startTour: true) }
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: 760, maxHeight: 620)

      if let onCancel {
        Button("Close Guided Setup", action: onCancel)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
    }
    .onAppear {
      coordinator.update(facts: store.guidedSetupFacts)
    }
    .onChange(of: store.guidedSetupFacts) { _, facts in
      coordinator.update(facts: facts)
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      refreshLiveFacts()
    }
    .onDisappear {
      coordinator.cancel()
    }
  }

  private var progressHeader: some View {
    HStack(spacing: 14) {
      WavesMark(size: 38, live: coordinator.phase == .ready)

      VStack(alignment: .leading, spacing: 3) {
        Text(coordinator.phase.setupTitle)
          .font(.headline)
        Text(coordinator.phase.progressDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 20)

      ProgressView(value: coordinator.phase.progressValue, total: 3)
        .frame(width: 130)
        .accessibilityLabel(coordinator.phase.progressDescription)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .background(theme.subtleFill)
  }

  private func performPrimaryAction() {
    Task { @MainActor in
      await coordinator.performPrimaryAction(
        using: GuidedSetupActions(
          acceptPrivacyAndStart: {
            await store.acceptPrivacySetupAndStart()
          },
          currentFacts: {
            store.guidedSetupFacts
          },
          refreshDiagnostics: {
            if store.isAudioRunning { store.refreshDiagnostics() }
          }
        )
      )
    }
  }

  private func performRepair(_ action: GuidedSetupRepairAction) {
    if action == .recheck {
      Task { @MainActor in
        await coordinator.performRepair(
          action,
          using: GuidedSetupActions(
            acceptPrivacyAndStart: {
              await store.acceptPrivacySetupAndStart()
            },
            currentFacts: {
              store.guidedSetupFacts
            },
            refreshDiagnostics: {
              if store.isAudioRunning { store.refreshDiagnostics() }
            }
          )
        )
      }
      return
    }
    switch action {
    case .recheck:
      break
    case .openCaptureSettings:
      SystemSettingsService().open(.audioCapture)
    case .openSoundSettings:
      SystemSettingsService().open(.soundOutput)
    case .recoverRoutes:
      store.recoverRoutes()
    }
  }

  private func refreshLiveFacts() {
    if store.isAudioRunning {
      store.refreshDiagnostics()
    }
    coordinator.update(facts: store.guidedSetupFacts)
  }

  private func complete(startTour: Bool) {
    guard !isCompleting else { return }
    isCompleting = true
    completionError = nil
    Task { @MainActor in
      let completed = await store.completeRequiredSetup(
        version: OnboardingExperience.currentVersion
      )
      isCompleting = false
      guard completed else {
        completionError =
          "Waves is ready, but setup could not be saved. Check your user Library and try again."
        return
      }
      if startTour { onStartTour() }
      dismiss()
    }
  }
}

private extension GuidedSetupPhase {
  var setupTitle: String {
    switch self {
    case .welcome: "Welcome"
    case .permissionPreflight, .waitingForMacOS: "Audio Capture"
    case .readiness: "Ready your Mac"
    case .ready: "Ready"
    }
  }

  var progressDescription: String {
    switch self {
    case .welcome: "Welcome"
    case .permissionPreflight, .waitingForMacOS: "Step 1 of 3"
    case .readiness: "Step 2 of 3"
    case .ready: "Step 3 of 3"
    }
  }

  var progressValue: Double {
    switch self {
    case .welcome: 0
    case .permissionPreflight, .waitingForMacOS: 1
    case .readiness: 2
    case .ready: 3
    }
  }
}
