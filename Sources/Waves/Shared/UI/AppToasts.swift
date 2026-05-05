import SwiftUI

struct AppToastStack: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    VStack(spacing: 10) {
      ForEach(store.toasts) { toast in
        AppToastBanner(toast: toast)
      }
    }
    .padding(.horizontal, 14)
    .frame(maxWidth: 420, alignment: .top)
    .animation(.spring(response: 0.24, dampingFraction: 0.9), value: store.toasts)
  }
}

private struct AppToastBanner: View {
  @Environment(AppStore.self) private var store
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
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Material.thick,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(iconColor.opacity(0.4), lineWidth: 1)
    )
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(iconColor)
        .frame(width: 4)
        .frame(maxHeight: .infinity)
    }
    .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    .contentShape(Rectangle())
    .transition(.asymmetric(
      insertion: .move(edge: .top).combined(with: .opacity),
      removal: .opacity
    ))
    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: toast.id)
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
      .green
    case .warning:
      .orange
    case .error:
      .red
    case .info:
      WavesDesign.accent
    }
  }
}
