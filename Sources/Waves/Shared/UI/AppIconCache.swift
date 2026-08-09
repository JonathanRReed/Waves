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

  @MainActor
  final class Storage {
    private struct Entry {
      let image: NSImage
      let cost: Int
      var lastAccess: UInt64
    }

    let configuration: Configuration
    private var entries: [String: Entry] = [:]
    private var accessCounter: UInt64 = 0
    private(set) var totalCost = 0

    init(configuration: Configuration) {
      self.configuration = configuration
    }

    var count: Int { entries.count }

    func object(forKey key: String) -> NSImage? {
      guard var entry = entries[key] else { return nil }
      entry.lastAccess = nextAccess()
      entries[key] = entry
      return entry.image
    }

    func setObject(_ image: NSImage, forKey key: String, cost: Int) {
      if let existing = entries.removeValue(forKey: key) {
        totalCost -= existing.cost
      }

      let normalizedCost = min(
        max(0, cost),
        max(0, configuration.totalCostLimit)
      )
      entries[key] = Entry(
        image: image,
        cost: normalizedCost,
        lastAccess: nextAccess()
      )
      let (newTotal, overflowed) = totalCost.addingReportingOverflow(normalizedCost)
      totalCost = overflowed ? Int.max : newTotal
      trimToLimits()
    }

    func removeObject(forKey key: String) {
      guard let removed = entries.removeValue(forKey: key) else { return }
      totalCost -= removed.cost
    }

    func removeAllObjects() {
      entries.removeAll(keepingCapacity: true)
      totalCost = 0
      accessCounter = 0
    }

    func contains(_ key: String) -> Bool {
      entries[key] != nil
    }

    private func nextAccess() -> UInt64 {
      accessCounter &+= 1
      return accessCounter
    }

    private func trimToLimits() {
      while exceedsLimits, let leastRecentKey {
        removeObject(forKey: leastRecentKey)
      }
    }

    private var exceedsLimits: Bool {
      configuration.countLimit <= 0
        || configuration.totalCostLimit <= 0
        || entries.count > configuration.countLimit
        || totalCost > configuration.totalCostLimit
    }

    private var leastRecentKey: String? {
      entries.min { lhs, rhs in
        if lhs.value.lastAccess == rhs.value.lastAccess {
          return lhs.key < rhs.key
        }
        return lhs.value.lastAccess < rhs.value.lastAccess
      }?.key
    }
  }

  static let configuration = Configuration(
    countLimit: 128,
    totalCostLimit: 64 * 1024 * 1024
  )

  private static let shared = Storage(configuration: configuration)

  static var appliedConfiguration: Configuration {
    shared.configuration
  }

  static func icon(for app: AudioApp) -> NSImage? {
    guard let data = app.iconTIFFData else { return nil }
    let key = app.id
    if let cached = shared.object(forKey: key) {
      return cached
    }
    guard let image = NSImage(data: data) else { return nil }
    shared.setObject(image, forKey: key, cost: decodedCost(for: image))
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
      shared.removeObject(forKey: runtimeID)
    }
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
    shared.contains(runtimeID)
  }

  static func resetForTesting() {
    shared.removeAllObjects()
  }
}
