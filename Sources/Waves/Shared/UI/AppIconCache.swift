import AppKit
import WavesAudioCore

/// Bounded cache for decoded runtime app icons. Keys are Core Audio runtime IDs,
/// so an app relaunch gets a fresh decoded image rather than inheriting one from
/// an exited process.
@MainActor
enum AppIconCache {
  struct Configuration: Equatable {
    let countLimit: Int
    let totalCostLimit: Int
  }

  static let configuration = Configuration(
    countLimit: 128,
    totalCostLimit: 64 * 1024 * 1024
  )

  private static let shared: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = configuration.countLimit
    cache.totalCostLimit = configuration.totalCostLimit
    return cache
  }()

  private static var trackedRuntimeIDs: Set<String> = []

  static var appliedConfiguration: Configuration {
    Configuration(
      countLimit: shared.countLimit,
      totalCostLimit: shared.totalCostLimit
    )
  }

  static func icon(for app: AudioApp) -> NSImage? {
    guard let data = app.iconTIFFData else { return nil }
    let key = app.id as NSString
    if let cached = shared.object(forKey: key) {
      return cached
    }
    guard let image = NSImage(data: data) else { return nil }
    shared.setObject(image, forKey: key, cost: decodedCost(for: image))
    trackedRuntimeIDs.insert(app.id)
    return image
  }

  static func prune(
    from previousSession: AudioSessionSnapshot,
    using currentSession: AudioSessionSnapshot
  ) {
    let previousRuntimeIDs = Set(previousSession.apps.map(\.id))
    let currentRuntimeIDs = Set(currentSession.apps.map(\.id))
    let departedRuntimeIDs = previousRuntimeIDs.subtracting(currentRuntimeIDs)
    for runtimeID in departedRuntimeIDs {
      shared.removeObject(forKey: runtimeID as NSString)
    }
    trackedRuntimeIDs.subtract(departedRuntimeIDs)
  }

  static func decodedCost(for image: NSImage) -> Int {
    decodedCost(
      forPixelDimensions: image.representations.map {
        (width: $0.pixelsWide, height: $0.pixelsHigh)
      }
    )
  }

  static func decodedCost(
    forPixelDimensions dimensions: [(width: Int, height: Int)]
  ) -> Int {
    let limit = configuration.totalCostLimit
    var total = 0
    for dimension in dimensions {
      let width = max(1, dimension.width)
      let height = max(1, dimension.height)
      let (pixels, pixelsOverflowed) = width.multipliedReportingOverflow(by: height)
      guard !pixelsOverflowed else { return limit }
      let (bytes, bytesOverflowed) = pixels.multipliedReportingOverflow(by: 4)
      guard !bytesOverflowed else { return limit }
      let (nextTotal, totalOverflowed) = total.addingReportingOverflow(bytes)
      guard !totalOverflowed, nextTotal < limit else { return limit }
      total = nextTotal
    }
    return max(4, total)
  }

  static func contains(runtimeID: String) -> Bool {
    shared.object(forKey: runtimeID as NSString) != nil
  }

  static func resetForTesting() {
    shared.removeAllObjects()
    trackedRuntimeIDs.removeAll()
  }
}
