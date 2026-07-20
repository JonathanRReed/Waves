import SwiftUI

enum PrivacySetupSurfaceStyle: Equatable {
  case full
  case compact
}

struct PrivacySetupSurface: View {
  @Environment(AppStore.self) private var store
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.wavesTheme) private var theme
  let style: PrivacySetupSurfaceStyle

  init(style: PrivacySetupSurfaceStyle = .full) {
    self.style = style
  }

  var body: some View {
    Group {
      if style == .full {
        fullSurface
      } else {
        compactSurface
      }
    }
  }

  private var fullSurface: some View {
    ZStack {
      WavesBackground()

      ScrollView {
        VStack(spacing: 26) {
          header(markSize: 68)

          if showsPrivacyExplanation {
            privacyExplanation
          } else {
            startupStatusCard
          }

          actionArea
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 48)
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .accessibilityElement(children: .contain)
  }

  private var compactSurface: some View {
    VStack(alignment: .leading, spacing: 16) {
      header(markSize: 42)

      if showsPrivacyExplanation {
        VStack(alignment: .leading, spacing: 9) {
          compactFact("Selected app audio is processed locally in real time.", systemImage: "waveform")
          compactFact("Audio is not recorded or transmitted.", systemImage: "externaldrive.badge.xmark")
          compactFact("macOS may ask for audio-capture/Microphone permission after Continue.", systemImage: "hand.raised.fill")
          compactFact("Accessibility is optional and separate.", systemImage: "accessibility")
        }
        .padding(12)
        .wavesCard(cornerRadius: 12)
      } else {
        startupStatusCard
      }

      actionArea
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  private func header(markSize: CGFloat) -> some View {
    HStack(alignment: .top, spacing: style == .full ? 18 : 12) {
      WavesMark(size: markSize, live: store.isAudioRunning)

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(style == .full ? .largeTitle.weight(.semibold) : .title3.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)

        Text(subtitle)
          .font(style == .full ? .body : .callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private var privacyExplanation: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Private, local audio processing")
        .font(.headline)

      Text("Waves uses private Core Audio process taps. Selected app audio is processed locally in real time so Waves can apply your volume, mute, routing, and equalizer choices.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 12) {
        privacyFact(
          "Nothing is recorded or transmitted",
          detail: "Waves does not save audio, send audio over a network, or add telemetry.",
          systemImage: "lock.shield.fill"
        )
        privacyFact(
          "macOS permission comes next",
          detail: "After Continue, macOS may ask for audio-capture or Microphone permission. That permission lets Waves process selected app audio locally.",
          systemImage: "hand.raised.fill"
        )
        privacyFact(
          "Accessibility stays optional",
          detail: "Accessibility is separate and is only useful for optional global shortcuts and app-control helpers. Waves will not request it automatically.",
          systemImage: "accessibility"
        )
      }
    }
    .padding(22)
    .wavesCard(cornerRadius: WavesDesign.cardCornerRadius)
  }

  private var startupStatusCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        if isProgressing {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        } else {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(WavesDesign.error)
            .accessibilityHidden(true)
        }

        Text(statusTitle)
          .font(.headline)
      }

      Text(statusDetail)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(style == .full ? 20 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .wavesCard(cornerRadius: style == .full ? WavesDesign.cardCornerRadius : 12)
    .overlay(
      RoundedRectangle(
        cornerRadius: style == .full ? WavesDesign.cardCornerRadius : 12,
        style: .continuous
      )
      .strokeBorder(
        isProgressing
          ? theme.accent.opacity(contrast == .increased ? 0.65 : 0.3)
          : WavesDesign.error.opacity(contrast == .increased ? 0.75 : 0.4)
      )
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(statusTitle). \(statusDetail)")
  }

  private var actionArea: some View {
    VStack(alignment: style == .full ? .center : .leading, spacing: 10) {
      if let error = visibleError {
        Label(error, systemImage: "exclamationmark.octagon.fill")
          .font(.callout)
          .foregroundStyle(WavesDesign.error)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("Setup error. \(error)")
      }

      Button {
        Task {
          await store.acceptPrivacySetupAndStart()
        }
      } label: {
        HStack(spacing: 8) {
          if isProgressing {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
          }
          Text(actionTitle)
          if !isProgressing {
            Image(systemName: "arrow.right")
              .accessibilityHidden(true)
          }
        }
        .frame(minWidth: style == .full ? 220 : nil)
      }
      .wavesGlassProminentButton()
      .controlSize(style == .full ? .large : .regular)
      .disabled(isProgressing)
      .accessibilityLabel(actionAccessibilityLabel)
      .accessibilityHint(actionAccessibilityHint)

      if showsPrivacyExplanation {
        Text("Continuing saves this choice before Waves starts any audio capture or permission probe.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(style == .full ? .center : .leading)
          .fixedSize(horizontal: false, vertical: true)
      } else if case .startupFailed = store.privacySetupPresentationState {
        Text("Your local-processing choice is already saved. Retrying does not ask you to accept it again.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: style == .full ? .center : .leading)
  }

  private func privacyFact(_ title: String, detail: String, systemImage: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(theme.accent)
        .frame(width: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func compactFact(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var title: String {
    switch store.privacySetupPresentationState {
    case .hidden:
      return "Waves is ready"
    case .awaitingPrivacy:
      return style == .full ? "Your audio stays on this Mac" : "Finish setting up Waves"
    case .savingConsent:
      return "Saving your choice"
    case .startingAudio:
      return "Starting Waves"
    case .startupFailed:
      return "Waves couldn't start"
    }
  }

  private var subtitle: String {
    switch store.privacySetupPresentationState {
    case .hidden:
      return "Per-app audio controls are available."
    case .awaitingPrivacy:
      return style == .full
        ? "Before Waves asks macOS for audio access, here is exactly how local processing works."
        : "Waves uses private Core Audio process taps to process selected app audio locally."
    case .savingConsent:
      return "Waves is making your local-processing choice durable before starting audio."
    case .startingAudio:
      return "Your choice is saved. Waves is now starting the local audio engine and checking macOS authorization."
    case .startupFailed:
      return "Your privacy choice is saved, but the audio engine needs another try."
    }
  }

  private var showsPrivacyExplanation: Bool {
    switch store.privacySetupPresentationState {
    case .awaitingPrivacy, .savingConsent:
      return true
    case .hidden, .startingAudio, .startupFailed:
      return false
    }
  }

  private var isProgressing: Bool {
    switch store.privacySetupPresentationState {
    case .savingConsent, .startingAudio:
      return true
    case .hidden, .awaitingPrivacy, .startupFailed:
      return false
    }
  }

  private var statusTitle: String {
    switch store.privacySetupPresentationState {
    case .savingConsent:
      return "Saving privacy setup"
    case .startingAudio:
      return "Starting the audio backend"
    case .startupFailed:
      return "Audio startup failed"
    case .hidden:
      return "Waves is running"
    case .awaitingPrivacy:
      return "Waiting for your choice"
    }
  }

  private var statusDetail: String {
    switch store.privacySetupPresentationState {
    case .savingConsent:
      return "No audio backend or capture-capable probe will start until this save succeeds."
    case .startingAudio:
      return "Waves is building the live app snapshot, restoring your saved audio choices, and preparing background maintenance."
    case let .startupFailed(detail):
      return detail
    case .hidden:
      return "The local audio engine is ready."
    case .awaitingPrivacy:
      return "Continue when you're ready."
    }
  }

  private var visibleError: String? {
    switch store.privacySetupPresentationState {
    case .awaitingPrivacy:
      return store.privacySetupError
    case let .startupFailed(detail):
      return detail
    case .hidden, .savingConsent, .startingAudio:
      return nil
    }
  }

  private var actionTitle: String {
    switch store.privacySetupPresentationState {
    case .startupFailed:
      return "Retry Start Waves"
    case .savingConsent:
      return "Saving Setup…"
    case .startingAudio:
      return "Starting Waves…"
    case .hidden:
      return "Waves is Ready"
    case .awaitingPrivacy:
      return "Continue and Start Waves"
    }
  }

  private var actionAccessibilityLabel: String {
    switch store.privacySetupPresentationState {
    case .startupFailed:
      return "Retry starting Waves"
    case .savingConsent:
      return "Saving privacy setup, in progress"
    case .startingAudio:
      return "Starting Waves, in progress"
    case .hidden:
      return "Waves is ready"
    case .awaitingPrivacy:
      return "Continue and start Waves"
    }
  }

  private var actionAccessibilityHint: String {
    switch store.privacySetupPresentationState {
    case .startupFailed:
      return "Retries the local audio backend without asking you to accept the privacy explanation again."
    case .awaitingPrivacy:
      return "Saves your local-processing choice before starting the audio backend. macOS may then ask for audio-capture or Microphone permission."
    case .hidden, .savingConsent, .startingAudio:
      return ""
    }
  }
}
