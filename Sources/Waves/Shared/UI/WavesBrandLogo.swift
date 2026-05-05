import AppKit
import SwiftUI

enum WavesBrandAssets {
  private static let queue = DispatchQueue(label: "com.waves.brandassets", qos: .userInitiated)

  static let logoImage: NSImage? = queue.sync {
    let candidateBundles = [Bundle.main, Bundle.module]
    for bundle in candidateBundles {
      if let pngURL = bundle.url(forResource: "waves-logo", withExtension: "png"),
         let pngImage = NSImage(contentsOf: pngURL)
      {
        return pngImage
      }

      if let svgURL = bundle.url(forResource: "waves-logo", withExtension: "svg"),
         let svgImage = NSImage(contentsOf: svgURL)
      {
        return svgImage
      }
    }

    return nil
  }
}

struct WavesBrandLogo: View {
  let size: CGFloat

  init(size: CGFloat = 20) {
    self.size = size
  }

  var body: some View {
    ZStack {
      if let logo = WavesBrandAssets.logoImage {
        Image(nsImage: logo)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "waveform")
          .resizable()
          .scaledToFit()
          .padding(size * 0.16)
          .foregroundStyle(WavesDesign.accent)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
  }
}
