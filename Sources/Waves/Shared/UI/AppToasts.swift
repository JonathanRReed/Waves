import SwiftUI

struct AppToastStack: View {
  @Environment(AppStore.self) private var store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 10) {
      ForEach(store.toasts) { toast in
        AppToastBanner(toast: toast)
      }
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: 420, alignment: .top)
    .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.9), value: store.toasts)
  }
}

private struct AppToastBanner: View {
  @Environment(AppStore.self) private var store
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let toast: AppToast

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: iconName)
        .font(.body.weight(.semibold))
        .foregroundStyle(iconColor)
        .frame(width: 18, height: 18)
        .padding(6)
        .background(iconColor.opacity(0.16), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text(toast.title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        if let detail = toast.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            // Recover the full text when a long detail is clipped to two lines.
            .help(detail)
        }
      }

      Spacer(minLength: 0)

      Button {
        store.dismissToast(id: toast.id)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
          .padding(4)
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss notification")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Material.thick,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(WavesDesign.hairline(increasedContrast: contrast == .increased), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    .contentShape(Rectangle())
    // Pause the auto-dismiss while the pointer is over the banner so a 2s toast
    // isn't lost mid-read; re-arm with a short grace when the cursor leaves.
    .onHover { hovering in
      if hovering {
        store.pauseToastDismissal(id: toast.id)
      } else {
        store.resumeToastDismissal(id: toast.id)
      }
    }
    .transition(bannerTransition)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityMessage)
    // .combine absorbs the dismiss button, so expose dismissal as an action.
    .accessibilityAction(named: "Dismiss") {
      store.dismissToast(id: toast.id)
    }
    .onAppear {
      // VoiceOver does not announce transient banners on its own.
      // Give errors/warnings high priority so they are not interrupted by
      // lower-severity toasts that appear in the same burst.
      var message = AttributedString(accessibilityMessage)
      switch toast.kind {
      case .error, .warning:
        message.accessibilitySpeechAnnouncementPriority = .high
      case .success, .info:
        break
      }
      AccessibilityNotification.Announcement(message).post()
    }
  }

  private var bannerTransition: AnyTransition {
    .asymmetric(
      insertion: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity),
      removal: .opacity
    )
  }

  private var accessibilityMessage: String {
    let prefix: String
    switch toast.kind {
    case .error:
      prefix = "Error. "
    case .warning:
      prefix = "Warning. "
    case .success, .info:
      prefix = ""
    }
    if let detail = toast.detail, !detail.isEmpty {
      return "\(prefix)\(toast.title). \(detail)"
    }
    return "\(prefix)\(toast.title)"
  }

  private var iconName: String {
    switch toast.kind {
    case .success:
      "checkmark.circle.fill"
    case .warning:
      "exclamationmark.triangle.fill"
    case .error:
      "xmark.octagon.fill"
    case .info:
      "info.circle.fill"
    }
  }

  private var iconColor: Color {
    switch toast.kind {
    case .success:
      WavesDesign.success
    case .warning:
      WavesDesign.warning
    case .error:
      WavesDesign.error
    case .info:
      WavesDesign.accent
    }
  }
}
