import SwiftUI

struct SetupStepRow: View {
  let title: String
  let isComplete: Bool
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(isComplete ? .green : WavesDesign.warning)
        .font(.title3)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
