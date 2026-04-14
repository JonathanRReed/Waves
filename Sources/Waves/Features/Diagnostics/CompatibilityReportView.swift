import SwiftUI
import WavesAudioCore

struct CompatibilityReportView: View {
  let entries: [SupportMatrixEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Compatibility report")
        .font(.title3.weight(.semibold))

      ForEach(entries) { entry in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
            Text(entry.category.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text(entry.state.displayName)
            .font(.caption.weight(.semibold))
        }
      }
    }
  }
}
