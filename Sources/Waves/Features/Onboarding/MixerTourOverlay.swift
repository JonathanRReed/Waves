import SwiftUI

enum GuidedTourOverlayPlacement: Equatable {
  case topTrailing
  case bottomTrailing

  static func resolve(
    targetFrame: CGRect?,
    containerHeight: CGFloat
  ) -> GuidedTourOverlayPlacement {
    guard let targetFrame else { return .bottomTrailing }
    return targetFrame.midY > containerHeight / 2 ? .topTrailing : .bottomTrailing
  }

  var alignment: Alignment {
    switch self {
    case .topTrailing: .topTrailing
    case .bottomTrailing: .bottomTrailing
    }
  }
}

struct GuidedTourTargetBoundsPreferenceKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(
    value: inout Anchor<CGRect>?,
    nextValue: () -> Anchor<CGRect>?
  ) {
    if let next = nextValue() { value = next }
  }
}

struct MixerTourOverlay: View {
  @Environment(\.wavesTheme) private var theme

  let moment: GuidedMixerTourMoment
  let appName: String
  let isTargetAvailable: Bool
  let onBack: () -> Void
  let onNext: () -> Void
  let onOpenSettings: () -> Void
  let onEnd: (GuidedMixerTourEndReason) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        tourProgress
        Spacer()
        Button("End Tour") { onEnd(.button) }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .keyboardShortcut(.cancelAction)
          .accessibilityHint("Ends the tour immediately. Escape does the same thing.")
      }

      VStack(alignment: .leading, spacing: 7) {
        Label(title, systemImage: symbol)
          .font(.title3.weight(.semibold))
          .foregroundStyle(theme.accent)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 10) {
        if moment != .chooseSound {
          Button("Back", action: onBack)
            .buttonStyle(.bordered)
        }
        Spacer()
        if moment == .goFurther {
          Button("Open Settings", action: onOpenSettings)
            .buttonStyle(.bordered)
        }
        if isTargetAvailable, moment.requiresAcceptedMixerIntent {
          Text("Use the highlighted row to continue")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        } else {
          Button(primaryActionTitle, action: onNext)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(width: 360)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(theme.accent.opacity(0.28))
    }
    .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    .accessibilityElement(children: .contain)
  }

  private var tourProgress: some View {
    HStack(spacing: 5) {
      ForEach(GuidedMixerTourMoment.allCases, id: \.self) { candidate in
        Capsule()
          .fill(candidate.rawValue <= moment.rawValue ? theme.accent : theme.subtleFill)
          .frame(width: candidate == moment ? 22 : 8, height: 6)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Tour step \(moment.rawValue + 1) of \(GuidedMixerTourMoment.allCases.count)")
  }

  private var title: String {
    return switch moment {
    case .chooseSound: "Start with one real app"
    case .setLevel: "Put it where it belongs"
    case .muteAndRestore: "Mute without hunting"
    case .goFurther: "Make the mix yours"
    }
  }

  private var detail: String {
    if !isTargetAvailable {
      return "\(appName) is no longer available in the mixer. Skip this step or end the tour now. Waves will not retry or change another app for you."
    }
    return switch moment {
    case .chooseSound:
      "\(appName) is playing now. Its row is the source of truth for volume, route health, output, and sound controls. The rest of the mixer stays usable during this tour."
    case .setLevel:
      "Move \(appName)’s volume slider to set the level you want. Waves starts managing a compatible app when you use an audio control, and the row tells you when another router owns it."
    case .muteAndRestore:
      "Use the speaker button to mute \(appName), then restore it from the same place. Waves never changes the original mute state just to demonstrate a tutorial."
    case .goFurther:
      "Profiles save a whole mix. Sound adds per-app output and EQ. Adaptive Mix can keep important audio clear, and every option remains available later in Settings and Help."
    }
  }

  private var primaryActionTitle: String {
    if !isTargetAvailable { return "Skip Step" }
    return moment == .goFurther ? "Finish" : "Next"
  }

  private var symbol: String {
    switch moment {
    case .chooseSound: "speaker.wave.2.fill"
    case .setLevel: "slider.horizontal.3"
    case .muteAndRestore: "speaker.slash.fill"
    case .goFurther: "dial.medium.fill"
    }
  }
}

struct DeferredTourTip: View {
  let onStart: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .font(.title3)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("See this mix in action")
          .font(.headline)
        Text("A playing app is ready for the optional 60-second tour.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Not Now", action: onDismiss)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      Button("Show Me How", action: onStart)
        .buttonStyle(.borderedProminent)
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .shadow(color: .black.opacity(0.14), radius: 16, y: 7)
  }
}
