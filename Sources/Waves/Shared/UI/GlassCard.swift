import SwiftUI

struct GlassCard<Content: View>: View {
  let content: Content
  var compact = false

  init(compact: Bool = false, @ViewBuilder content: () -> Content) {
    self.compact = compact
    self.content = content()
  }

  var body: some View {
    content
      .padding(compact ? 14 : 20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        .regularMaterial,
        in: RoundedRectangle(
          cornerRadius: compact
            ? WavesDesign.compactCardCornerRadius : WavesDesign.cardCornerRadius,
          style: .continuous
        )
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: compact
            ? WavesDesign.compactCardCornerRadius : WavesDesign.cardCornerRadius,
          style: .continuous
        )
        .strokeBorder(WavesDesign.stroke)
      }
      .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
  }
}
