import SwiftUI

struct OnboardingView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorSchemeContrast) private var contrast

  private let steps: [(title: String, detail: String, action: String)] = [
    (
      "Confirm managed audio support",
      "Waves uses local Core Audio process taps on macOS 14.2 or newer. Audio stays on this Mac and is only replayed to your selected output device.",
      "Re-check support"
    ),
    (
      "Validate output device visibility",
      "Waves needs to see your audio output devices to create managed routes. Ensure your speakers or headphones are connected and recognized by macOS.",
      "Refresh Devices"
    ),
    (
      "Test device switching",
      "When you switch audio devices (for example, from speakers to headphones), Waves re-establishes managed routes automatically — no restart needed. Run a quick check here.",
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

  /// True when the running OS is older than the per-app routing requirement.
  /// On such systems `audioComponentInstalled` can never flip true, so step 0's
  /// Refresh action is futile and must be replaced with an explanation instead.
  private var isUnsupportedOS: Bool {
    if #available(macOS 14.2, *) {
      return false
    }
    return true
  }

  /// True when the decisive Core Audio capture (Microphone/TCC) permission is
  /// the specific blocker for route health: routing is supported and a device
  /// is visible, but capture has not been authorized. In this state route
  /// recovery cannot help — only granting Microphone permission can.
  private var captureDeniesRouteHealth: Bool {
    store.onboarding.audioComponentInstalled &&
    store.onboarding.outputDeviceVisible &&
    !store.onboarding.routeHealthReady &&
    !store.onboarding.permissionsGranted
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 14) {
        WavesMark(size: 48, live: isFullyComplete)

        VStack(alignment: .leading, spacing: 6) {
          Text("Welcome to Waves")
            .font(.title2.weight(.semibold))

          Text(isFullyComplete
            ? "You're all set! Waves is ready to manage your per-app audio."
            : "Let's get Waves set up to manage your per-app audio. Follow the steps below.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      ProgressView(value: completionProgress)
        .tint(isFullyComplete ? WavesDesign.success : WavesDesign.accent)
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(Int((completionProgress * 3).rounded())) of 3 steps complete")

      VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
          EnhancedSetupStepRow(
            title: step.title,
            detail: detail(for: index, fallback: step.detail),
            isComplete: isStepComplete(at: index),
            action: actionLabel(for: index, fallback: step.action),
            canPerformAction: canPerformAction(for: index),
            badge: badge(for: index),
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
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WavesDesign.success)
              Text("Adjust individual app volumes from the menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WavesDesign.success)
              Text("Pin your favorite apps for quick access")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WavesDesign.success)
              Text("Group apps into profiles, with optional saved levels")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WavesDesign.success)
              Text("Use keyboard shortcuts (⌘R to refresh)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(16)
        .background(WavesDesign.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          // A defined edge so the card reads under Increase Contrast (matching
          // wavesCard and the step rows).
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WavesDesign.success.opacity(contrast == .increased ? 0.6 : 0.3))
        )
      }

      Spacer()

      HStack(spacing: 12) {
        Button("Refresh Status") {
          store.refresh()
          store.refreshDiagnostics()
        }
        .wavesGlassProminentButton()

        if !store.onboarding.launchAtLoginEnabled {
          Button("Enable Launch at Login") {
            store.launchAtLoginEnabled = true
          }
          .buttonStyle(.bordered)
        }
      }
    }
    .padding(28)
    .onAppear {
      // Probe live route-health/diagnostics state when the flow is shown so the
      // route-health step reflects a fresh check rather than the last sync.
      // refresh(announce: false) already rebuilds the snapshot, re-runs
      // diagnosticsReport(), and re-syncs onboarding, so a separate
      // refreshDiagnostics() would only duplicate that work — and announce:false
      // keeps this automatic re-sync from emitting a "Library refreshed" toast.
      store.refresh(announce: false)
    }
    .onChange(of: scenePhase) { _, newPhase in
      // Re-evaluate permissions (e.g. AXIsProcessTrusted for Accessibility) when
      // the user returns to Waves after granting them in System Settings, so the
      // relevant step updates without requiring a manual Refresh. Silent so
      // returning focus to Waves doesn't spam a toast on every reactivation.
      if newPhase == .active {
        store.refresh(announce: false)
      }
    }
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
    case 0:
      // On an unsupported OS the flag can never flip, so a Refresh action is
      // futile; surface an informational message instead (see `detail`).
      return !store.onboarding.audioComponentInstalled && !isUnsupportedOS
    case 1: return !store.onboarding.outputDeviceVisible
    case 2: return store.onboarding.outputDeviceVisible && !store.onboarding.routeHealthReady
    case 3: return !store.onboarding.accessibilityPermissionGranted
    default: return false
    }
  }

  /// Per-step body copy, overridden when the live state warrants more specific
  /// guidance than the static default (unsupported OS, capture permission, or
  /// the keyboard-shortcuts dependency).
  private func detail(for index: Int, fallback: String) -> String {
    switch index {
    case 0 where isUnsupportedOS:
      return "Per-app audio routing requires macOS 14.2 or newer. Waves can't manage audio on this version of macOS — update macOS to continue."
    case 2 where captureDeniesRouteHealth:
      return "Waves needs permission to capture audio so it can route it to your selected device. Without it, per-app volume, mute, and boost silently do nothing. Allow audio recording for Waves in System Settings, then refresh."
    case 3:
      var copy = fallback
      if !store.preferences.enableKeyboardShortcuts {
        copy += " Global keyboard shortcuts are currently turned off in General settings — turn them on there for this grant to take effect."
      }
      return copy
    default:
      return fallback
    }
  }

  /// Per-step action-button label, overridden when the live state changes what
  /// the button should do.
  private func actionLabel(for index: Int, fallback: String) -> String {
    switch index {
    case 2 where captureDeniesRouteHealth:
      return "Open System Settings"
    default:
      return fallback
    }
  }

  /// A short, non-warning chip shown beside a step. Used to mark the
  /// Accessibility step as intentionally optional so granting (or skipping) it
  /// reads as expected rather than as a stuck requirement.
  private func badge(for index: Int) -> String? {
    index == 3 ? "Optional" : nil
  }

  /// A secondary affordance shown on an already-complete step. Currently used to
  /// let the user re-run the route-recovery check after it has passed, since the
  /// primary action vanishes once the step is complete.
  private func secondaryAction(for index: Int) -> String? {
    if index == 2, store.onboarding.routeHealthReady {
      return "Re-test"
    }
    return nil
  }

  private func handleSecondaryAction(for index: Int) {
    switch index {
    case 2:
      store.recoverRoutes()
    default:
      break
    }
  }

  private func handleAction(for index: Int) {
    switch index {
    case 0:
      store.refresh()
    case 1:
      store.refresh()
    case 2:
      // When capture permission is the blocker, route recovery cannot create a
      // TCC grant, so direct the user to the Microphone privacy pane instead.
      if captureDeniesRouteHealth {
        openSystemSettings(privacyPane: "Privacy_Microphone")
      } else {
        store.recoverRoutes()
      }
    case 3:
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
  /// Optional non-warning chip (e.g. "Optional") shown beside the title.
  var badge: String? = nil
  /// Optional secondary action label shown even when the step is complete
  /// (e.g. a "Re-test" control). Rendered only when non-nil.
  var secondaryAction: String? = nil
  var onSecondaryAction: () -> Void = {}
  let onAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isComplete ? "checkmark.circle.fill" : canPerformAction ? "exclamationmark.triangle.fill" : "circle")
          .foregroundStyle(isComplete ? .green : canPerformAction ? WavesDesign.warning : .secondary)
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
    // A tonal fill behind the status stroke so step rows match the app's other
    // content cards instead of reading as thin outlines on the backdrop.
    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(isComplete ? WavesDesign.success.opacity(0.3) : canPerformAction ? WavesDesign.warning.opacity(0.3) : Color.secondary.opacity(0.2))
    )
  }
}
