import SwiftUI
import WavesAudioCore

struct OnboardingView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.wavesTheme) private var theme
  @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
  @State private var stage: OnboardingStage = .welcome

  var body: some View {
    VStack(spacing: 0) {
      stageHeader
      Divider()

      ScrollView {
        stageContent
          .frame(maxWidth: 720, alignment: .leading)
          .padding(.horizontal, 32)
          .padding(.vertical, 28)
          .frame(maxWidth: .infinity, alignment: .top)
      }

      Divider()
      navigationBar
    }
    .background(WavesBackground())
    .onAppear {
      if store.preferences.hasCompletedPrivacySetup && !store.preferences.hasCompletedGuidedSetup {
        stage = .readiness
      }
      refreshLiveStatus()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { refreshLiveStatus() }
    }
    .onChange(of: store.preferences.hasCompletedPrivacySetup) { _, completed in
      if completed && stage == .welcome { stage = .readiness }
    }
  }

  private var stageHeader: some View {
    HStack(spacing: 14) {
      WavesMark(size: 44, live: stage == .ready)

      VStack(alignment: .leading, spacing: 3) {
        Text("Set Up Waves")
          .font(.title3.weight(.semibold))
        Text(stage.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 16)

      HStack(spacing: 8) {
        ForEach(OnboardingStage.allCases) { item in
          VStack(spacing: 4) {
            Circle()
              .fill(item.rawValue <= stage.rawValue ? theme.accent : theme.subtleFill)
              .frame(width: 9, height: 9)
              .overlay(Circle().strokeBorder(theme.stroke))
            Text(item.shortTitle)
              .font(.caption2)
              .foregroundStyle(item == stage ? Color.primary : Color.secondary)
          }
          .frame(minWidth: 54)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Setup step \(stage.rawValue + 1) of \(OnboardingStage.allCases.count), \(stage.shortTitle)"
      )
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(theme.subtleFill)
  }

  @ViewBuilder
  private var stageContent: some View {
    switch stage {
    case .welcome:
      welcomeStage
    case .readiness:
      readinessStage
    case .personalize:
      personalizeStage
    case .ready:
      readyStage
    }
  }

  private var welcomeStage: some View {
    VStack(alignment: .leading, spacing: 20) {
      stageTitle(
        "Private audio control, on this Mac",
        detail:
          "Waves processes selected app audio locally in real time. It does not record audio, transmit it, or add telemetry."
      )

      VStack(alignment: .leading, spacing: 14) {
        fact(
          "Local by design", detail: "Managed streams stay on this Mac.", symbol: "lock.shield.fill"
        )
        fact(
          "Permission stays explicit",
          detail: "Waves explains a macOS permission before opening its settings pane.",
          symbol: "hand.raised.fill")
        fact(
          "Your choices remain yours",
          detail: "Redoing setup never removes app levels, profiles, equalizers, or preferences.",
          symbol: "slider.horizontal.3")
      }
      .padding(18)
      .wavesCard()

      if !store.preferences.hasCompletedPrivacySetup {
        PrivacySetupSurface(style: .compact)
      } else {
        Label(
          "The local-processing choice is accepted and saved.", systemImage: "checkmark.circle.fill"
        )
        .foregroundStyle(theme.success)
      }
    }
  }

  private var readinessStage: some View {
    VStack(alignment: .leading, spacing: 20) {
      stageTitle(
        "Make sure managed audio is ready",
        detail:
          "These checks reflect the live backend. If macOS needs your help, Waves opens the exact place to fix it."
      )

      VStack(spacing: 12) {
        readinessRow(
          "Managed audio support",
          detail: audioSupportDetail,
          isReady: store.onboarding.audioComponentInstalled,
          actionTitle: store.onboarding.audioComponentInstalled ? nil : "Re-check",
          action: { store.refresh(announce: false) }
        )
        readinessRow(
          "Audio capture permission",
          detail: captureDetail,
          isReady: captureIsAuthorized,
          actionTitle: captureActionTitle,
          action: repairCapturePermission
        )
        readinessRow(
          "Output device",
          detail: outputDetail,
          isReady: store.onboarding.outputDeviceVisible,
          actionTitle: store.onboarding.outputDeviceVisible ? nil : "Open Sound Settings",
          action: { SystemSettingsService().open(.soundOutput) }
        )
        readinessRow(
          "Managed routes",
          detail: routeDetail,
          isReady: store.onboarding.routeHealthReady,
          actionTitle: store.onboarding.routeHealthReady ? nil : "Recover Routes",
          action: { store.recoverRoutes() }
        )
      }

      HStack(spacing: 10) {
        Button {
          refreshLiveStatus()
        } label: {
          Label("Refresh Checks", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(!store.isAudioRunning || store.isRefreshing)

        if !readinessIsComplete {
          Text("Complete the required checks to continue.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var personalizeStage: some View {
    VStack(alignment: .leading, spacing: 20) {
      stageTitle(
        "Make Waves fit your day",
        detail:
          "Choose the common settings people usually look for before they start mixing apps. You can change all of these later."
      )

      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Look & Feel") {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
              Text("Appearance")
              Picker("Appearance", selection: preferenceBinding(\.appearance)) {
                ForEach(WavesAppearance.allCases) { value in
                  Text(value.displayName).tag(value)
                }
              }
              .labelsHidden()
            }
            GridRow {
              Text("Palette")
              Picker("Palette", selection: preferenceBinding(\.palette)) {
                ForEach(WavesPalette.allCases) { value in
                  Text(value.displayName).tag(value)
                }
              }
              .labelsHidden()
            }
          }
          .padding(.top, 8)
        }

        GroupBox("Everyday Use") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle("Show Waves in the menu bar", isOn: $showMenuBarExtra)
            Toggle(
              "Launch at login",
              isOn: Binding(
                get: { store.launchAtLoginEnabled },
                set: { store.launchAtLoginEnabled = $0 }
              ))
            Toggle("Show recent apps", isOn: preferenceBinding(\.showRecentApps))
            Toggle(
              "Enable global keyboard shortcuts",
              isOn: Binding(
                get: { store.preferences.enableKeyboardShortcuts },
                set: { store.setKeyboardShortcutsEnabled($0) }
              ))
          }
          .padding(.top, 8)
        }

        GroupBox("Adaptive Mix") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(
              "Enable Adaptive Mix",
              isOn: Binding(
                get: { store.preferences.adaptiveMixMode != .off },
                set: { store.setAdaptiveMixMode($0 ? .both : .off) }
              )
            )
            .disabled(!store.isAudioRunning)

            Picker(
              "Starting strategy",
              selection: Binding(
                get: { store.preferences.adaptiveStrategy },
                set: { store.applyAdaptiveStrategy($0) }
              )
            ) {
              ForEach(AdaptiveStrategy.allCases, id: \.self) { strategy in
                Text(strategy.displayName).tag(strategy)
              }
            }
            .disabled(!store.isAudioRunning)

            Text(strategyDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Picker(
              "Sidechain behavior",
              selection: Binding(
                get: { store.preferences.adaptiveFocusMode },
                set: { store.setAdaptiveFocusMode($0) }
              )
            ) {
              ForEach(AdaptiveFocusMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            .disabled(!store.isAudioRunning)

            Text(focusModeDescription)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, 8)
        }
      }
    }
  }

  private var readyStage: some View {
    VStack(alignment: .leading, spacing: 22) {
      stageTitle(
        "Waves is ready",
        detail: "Your audio engine is healthy and your basic preferences are saved."
      )

      VStack(spacing: 0) {
        summaryRow("Output", value: store.currentDeviceName)
        Divider()
        summaryRow(
          "Theme",
          value:
            "\(store.preferences.palette.displayName), \(store.preferences.appearance.displayName)")
        Divider()
        summaryRow("Adaptive Mix", value: adaptiveSummary)
        Divider()
        summaryRow("Menu Bar", value: showMenuBarExtra ? "Shown" : "Hidden")
      }
      .wavesCard()

      VStack(alignment: .leading, spacing: 9) {
        Label(
          "Open Sound to tune Managed Audio EQ and app priorities.",
          systemImage: "waveform.and.magnifyingglass")
        Label(
          "Open a mixer row to adjust one app's volume, routing, and EQ.",
          systemImage: "slider.horizontal.3")
        Label(
          "Return to Setup & Repair if a macOS permission or route stops working.",
          systemImage: "wrench.and.screwdriver")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private var navigationBar: some View {
    HStack {
      if stage != .welcome {
        Button("Back") { moveBackward() }
          .buttonStyle(.bordered)
      }

      Spacer()

      if stage == .ready {
        Button("Start Using Waves") {
          store.completeGuidedSetup()
          dismiss()
        }
        .wavesGlassProminentButton()
        .keyboardShortcut(.defaultAction)
      } else if !(stage == .welcome && !store.preferences.hasCompletedPrivacySetup) {
        Button("Continue") { moveForward() }
          .wavesGlassProminentButton()
          .keyboardShortcut(.defaultAction)
          .disabled(stage == .readiness && !readinessIsComplete)
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .background(theme.subtleFill)
  }

  private func stageTitle(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.title2.weight(.semibold))
      Text(detail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func fact(_ title: String, detail: String, symbol: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .foregroundStyle(theme.accent)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func readinessRow(
    _ title: String,
    detail: String,
    isReady: Bool,
    actionTitle: String?,
    action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(isReady ? theme.success : theme.warning)
        .font(.title3)
        .frame(width: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if let actionTitle {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
    .padding(14)
    .wavesCard(cornerRadius: 12)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(isReady ? "Ready" : "Needs action"): \(title). \(detail)")
  }

  private func summaryRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).fontWeight(.medium)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var captureIsAuthorized: Bool {
    store.onboarding.captureAuthorization == .authorized
  }

  private var readinessIsComplete: Bool {
    store.onboarding.audioComponentInstalled
      && captureIsAuthorized
      && store.onboarding.outputDeviceVisible
      && store.onboarding.routeHealthReady
  }

  private var audioSupportDetail: String {
    if #unavailable(macOS 14.2) {
      return "Managed per-app audio requires macOS 14.2 or newer."
    }
    return store.onboarding.audioComponentInstalled
      ? "This Mac supports the Core Audio process-tap path used by Waves."
      : "Waves has not confirmed managed-audio support yet."
  }

  private var captureDetail: String {
    switch store.onboarding.captureAuthorization {
    case .authorized:
      "macOS allows Waves to process selected app audio locally."
    case .notGranted:
      "Enable Waves in Privacy & Security, then return here."
    case .undetermined, nil:
      "macOS has not returned a decisive authorization state yet."
    case .probeFailed(let status):
      "The authorization probe failed with status \(status). Re-check before changing settings."
    case .unsupported:
      "This macOS version does not provide the authorization path Waves requires."
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
      ? "Waves can see \(store.currentDeviceName)."
      : "Choose connected speakers or headphones in System Settings > Sound."
  }

  private var routeDetail: String {
    store.onboarding.routeHealthReady
      ? "Managed routes are healthy and follow the current output device."
      : "Recover routes to rebuild the process taps without changing your saved mix."
  }

  private var strategyDescription: String {
    switch store.preferences.adaptiveStrategy {
    case .lectureFocus:
      "Keeps lecture or voice apps forward while music remains audible in the background."
    case .mediaFirst:
      "Keeps music and video forward while meetings can stay in the background."
    case .balanced:
      "Treats active apps evenly until you assign priorities."
    case .custom:
      "Uses the content type and priority you set for each app."
    }
  }

  private var adaptiveSummary: String {
    guard store.preferences.adaptiveMixMode != .off else { return "Off" }
    return
      "\(store.preferences.adaptiveStrategy.displayName), \(store.preferences.adaptiveFocusMode.displayName)"
  }

  private var focusModeDescription: String {
    switch store.preferences.adaptiveFocusMode {
    case .assignedPriorities:
      "Only your assigned priorities control ducking."
    case .followFrontApp:
      "An audible frontmost app takes the foreground automatically."
    case .smartHybrid:
      "Recommended. The front app gets a gentle boost in priority without overriding your guardrails."
    }
  }

  private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<UserPreferences, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { store.preferences[keyPath: keyPath] },
      set: {
        store.preferences[keyPath: keyPath] = $0
        store.persistPreferences()
      }
    )
  }

  private func refreshLiveStatus() {
    guard store.preferences.hasCompletedPrivacySetup, store.isAudioRunning else { return }
    store.refresh(announce: false)
  }

  private func moveForward() {
    guard let next = OnboardingStage(rawValue: stage.rawValue + 1) else { return }
    stage = next
  }

  private func moveBackward() {
    guard let previous = OnboardingStage(rawValue: stage.rawValue - 1) else { return }
    stage = previous
  }
}

private enum OnboardingStage: Int, CaseIterable, Identifiable {
  case welcome
  case readiness
  case personalize
  case ready

  var id: Self { self }

  var shortTitle: String {
    switch self {
    case .welcome: "Welcome"
    case .readiness: "Audio"
    case .personalize: "Personalize"
    case .ready: "Ready"
    }
  }

  var subtitle: String {
    switch self {
    case .welcome: "Privacy and local processing"
    case .readiness: "Permissions, device, and routes"
    case .personalize: "Appearance and everyday settings"
    case .ready: "Review and start mixing"
    }
  }
}
