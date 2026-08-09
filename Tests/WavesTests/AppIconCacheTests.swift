import AppKit
import Testing
import WavesAudioCore

@testable import Waves

@Suite(.serialized)
@MainActor
struct AppIconCacheTests {
  @Test func appIconCacheHasExplicitCountAndDecodedCostLimits() throws {
    AppIconCache.resetForTesting()
    #expect(AppIconCache.appliedConfiguration.countLimit == 128)
    #expect(AppIconCache.appliedConfiguration.totalCostLimit == 64 * 1024 * 1024)

    let image = NSImage(size: NSSize(width: 8, height: 6))
    image.addRepresentation(bitmapRepresentation(width: 8, height: 6))
    image.addRepresentation(bitmapRepresentation(width: 4, height: 3))
    #expect(AppIconCache.decodedCost(for: image) == ((8 * 6) + (4 * 3)) * 4)
    #expect(
      AppIconCache.decodedCost(
        forPixelDimensions: [(width: Int.max, height: Int.max)]
      ) == AppIconCache.appliedConfiguration.totalCostLimit
    )
  }

  @Test func appIconCacheReturnsTheDecodedObjectOnAHit() throws {
    AppIconCache.resetForTesting()
    let firstApp = AudioApp(
      id: "runtime.icon.hit",
      displayName: "Icon Hit",
      iconTIFFData: iconTIFFData(width: 4, height: 4),
      category: .media
    )
    let first = try #require(AppIconCache.icon(for: firstApp))

    let sameRuntimeWithUndecodableReplacement = AudioApp(
      id: firstApp.id,
      displayName: firstApp.displayName,
      iconTIFFData: Data([0]),
      category: .media
    )
    let hit = try #require(AppIconCache.icon(for: sameRuntimeWithUndecodableReplacement))

    #expect(first === hit)
  }

  @Test func appIconCacheStorageEnforcesExactCountCostAndRecency() {
    let first = NSImage(size: NSSize(width: 1, height: 1))
    let second = NSImage(size: NSSize(width: 1, height: 1))
    let third = NSImage(size: NSSize(width: 1, height: 1))
    let fourth = NSImage(size: NSSize(width: 1, height: 1))

    let countBoundStorage = AppIconCache.Storage(
      configuration: AppIconCache.Configuration(countLimit: 2, totalCostLimit: 1_000)
    )
    countBoundStorage.setObject(first, forKey: "first", cost: 40)
    countBoundStorage.setObject(second, forKey: "second", cost: 40)
    _ = countBoundStorage.object(forKey: "first")
    countBoundStorage.setObject(third, forKey: "third", cost: 40)

    #expect(countBoundStorage.object(forKey: "first") === first)
    #expect(countBoundStorage.object(forKey: "second") == nil)
    #expect(countBoundStorage.object(forKey: "third") === third)
    #expect(countBoundStorage.count == 2)

    let costBoundStorage = AppIconCache.Storage(
      configuration: AppIconCache.Configuration(countLimit: 10, totalCostLimit: 100)
    )
    costBoundStorage.setObject(first, forKey: "first", cost: 40)
    costBoundStorage.setObject(second, forKey: "second", cost: 40)
    _ = costBoundStorage.object(forKey: "first")
    costBoundStorage.setObject(third, forKey: "third", cost: 40)

    #expect(costBoundStorage.object(forKey: "first") === first)
    #expect(costBoundStorage.object(forKey: "second") == nil)
    #expect(costBoundStorage.object(forKey: "third") === third)

    costBoundStorage.setObject(fourth, forKey: "fourth", cost: 70)

    #expect(costBoundStorage.object(forKey: "first") == nil)
    #expect(costBoundStorage.object(forKey: "third") == nil)
    #expect(costBoundStorage.object(forKey: "fourth") === fourth)
    #expect(costBoundStorage.count == 1)
    #expect(costBoundStorage.totalCost == 70)
  }

  @Test func appIconCachePrunesOnlyRuntimeIDsThatDepartedTheAuthoritativeRoster() throws {
    AppIconCache.resetForTesting()
    let retained = iconApp(id: "runtime.retained", category: .media)
    let departed = iconApp(id: "runtime.departed", category: .media)
    _ = try #require(AppIconCache.icon(for: retained))
    _ = try #require(AppIconCache.icon(for: departed))

    AppIconCache.prune(
      from: iconSession(apps: [retained, departed]),
      using: iconSession(apps: [retained])
    )

    #expect(AppIconCache.contains(runtimeID: retained.id))
    #expect(!AppIconCache.contains(runtimeID: departed.id))
  }

  @Test func filteredPresentationScopeNeverEvictsAnAuthoritativeSessionIcon() throws {
    AppIconCache.resetForTesting()
    let visible = iconApp(id: "runtime.visible", category: .media)
    let filteredSystemApp = iconApp(id: "runtime.filtered", category: .system)
    let sessionRoster = [visible, filteredSystemApp]
    let filteredPresentation = sessionRoster.filter { $0.category != .system }
    #expect(filteredPresentation.map(\.id) == [visible.id])
    _ = try #require(AppIconCache.icon(for: visible))
    _ = try #require(AppIconCache.icon(for: filteredSystemApp))

    AppIconCache.prune(
      from: iconSession(apps: sessionRoster),
      using: iconSession(apps: sessionRoster)
    )

    #expect(AppIconCache.contains(runtimeID: visible.id))
    #expect(AppIconCache.contains(runtimeID: filteredSystemApp.id))
  }

  @Test func appStorePrunesAgainstItsSessionRatherThanItsFilteredPresentation() async throws {
    let store = await makeControlStoreFixture()
    let visible = iconApp(id: "runtime.store.visible", category: .media)
    let filteredSystemApp = iconApp(id: "runtime.store.filtered", category: .system)
    store.session.apps = [visible, filteredSystemApp]
    store.preferences.showSystemProcesses = false
    AppIconCache.resetForTesting()
    _ = try #require(AppIconCache.icon(for: visible))
    _ = try #require(AppIconCache.icon(for: filteredSystemApp))

    #expect(store.visibleApps.map(\.id) == [visible.id])
    #expect(AppIconCache.contains(runtimeID: filteredSystemApp.id))

    store.session.apps = [visible]

    #expect(AppIconCache.contains(runtimeID: visible.id))
    #expect(!AppIconCache.contains(runtimeID: filteredSystemApp.id))
  }

  @Test func oneAppStoreCannotEvictAnotherStoresRuntimeIcon() async throws {
    let firstStore = await makeControlStoreFixture()
    let secondStore = await makeControlStoreFixture()
    let firstApp = iconApp(id: "runtime.store.first", category: .media)
    let secondApp = iconApp(id: "runtime.store.second", category: .media)
    firstStore.session.apps = [firstApp]
    secondStore.session.apps = [secondApp]
    AppIconCache.resetForTesting()
    _ = try #require(AppIconCache.icon(for: firstApp))
    _ = try #require(AppIconCache.icon(for: secondApp))

    firstStore.session.apps = []

    #expect(!AppIconCache.contains(runtimeID: firstApp.id))
    #expect(AppIconCache.contains(runtimeID: secondApp.id))
  }
}

@MainActor
private func iconApp(id: String, category: AppCategory) -> AudioApp {
  AudioApp(
    id: id,
    displayName: id,
    iconTIFFData: iconTIFFData(width: 4, height: 4),
    category: category
  )
}

private func iconSession(apps: [AudioApp]) -> AudioSessionSnapshot {
  AudioSessionSnapshot(
    apps: apps,
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: .unprobed
  )
}

@MainActor
private func iconTIFFData(width: Int, height: Int) -> Data {
  let image = NSImage(size: NSSize(width: width, height: height))
  image.addRepresentation(bitmapRepresentation(width: width, height: height))
  return image.tiffRepresentation!
}

@MainActor
private func bitmapRepresentation(width: Int, height: Int) -> NSBitmapImageRep {
  NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: width * 4,
    bitsPerPixel: 32
  )!
}
