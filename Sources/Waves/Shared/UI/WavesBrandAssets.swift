import AppKit

/// Loads the bundled app-icon artwork used for the Dock / application icon. The
/// in-app brand mark is drawn in code by `WavesMark` (see DesignSystem.swift);
/// this asset is only the rasterized logo for `NSApp.applicationIconImage`.
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
