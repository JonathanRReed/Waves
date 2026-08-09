import SwiftUI

enum ReadinessStatus: String, CaseIterable, Equatable, Sendable {
  case ready
  case attention
  case unavailable

  var symbolName: String {
    switch self {
    case .ready: "checkmark.circle.fill"
    case .attention: "exclamationmark.triangle.fill"
    case .unavailable: "xmark.octagon.fill"
    }
  }

  var statusWord: String {
    switch self {
    case .ready: "Ready"
    case .attention: "Needs attention"
    case .unavailable: "Unavailable"
    }
  }
}

struct ReadinessChecklistRow: View {
  @Environment(\.wavesTheme) private var theme

  let title: String
  let detail: String
  let status: ReadinessStatus
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: status.symbolName)
        .font(.title3)
        .foregroundStyle(statusColor)
        .frame(width: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityLabel("\(actionTitle), \(title)")
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .wavesCard(cornerRadius: 12)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(status.statusWord): \(title). \(detail)")
  }

  private var statusColor: Color {
    switch status {
    case .ready: theme.success
    case .attention: theme.warning
    case .unavailable: theme.error
    }
  }
}
