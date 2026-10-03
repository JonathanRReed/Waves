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

  @Test func appIconCacheReturnsTheDecodedObjectWhenSourceBytesMatch() throws {
    AppIconCache.resetForTesting()
    let firstApp = AudioApp(
      id: "runtime.icon.hit",
      displayName: "Icon Hit",
      iconTIFFData: iconTIFFData(width: 4, height: 4),
      category: .media
    )
    let first = try #require(AppIconCache.icon(for: firstApp))

    let hit = try #require(AppIconCache.icon(for: firstApp))

    #expect(first === hit)
  }

  @Test func appIconCacheDecodesReplacementBytesForTheSameLogicalID() throws {
    AppIconCache.resetForTesting()
    let original = AudioApp(
      id: "com.example.player",
      displayName: "Player",
      iconTIFFData: iconTIFFData(width: 4, height: 4),
      category: .media
    )
    let originalImage = try #require(AppIconCache.icon(for: original))
    let replacement = AudioApp(
      id: original.id,
      displayName: original.displayName,
      iconTIFFData: iconTIFFData(width: 7, height: 5),
      category: .media
    )

    let replacementImage = try #require(AppIconCache.icon(for: replacement))

    #expect(replacementImage !== originalImage)
    #expect(replacementImage.representations.first?.pixelsWide == 7)
    #expect(replacementImage.representations.first?.pixelsHigh == 5)
  }

  @Test func appIconCacheStorageEnforcesExactCountCostAndRecency() {
    let first = NSImage(size: NSSize(width: 1, height: 1))
    let second = NSImage(size: NSSize(width: 1, height: 1))
    let third = NSImage(size: NSSize(width: 1, height: 1))
    let fourth = NSImage(size: NSSize(width: 1, height: 1))

    let countBoundStorage = AppIconCache.Storage<String>(
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

    let costBoundStorage = AppIconCache.Storage<String>(
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

  @Test func boundedCacheRetainsDepartedIconsForOtherStoresToReuse() throws {
    AppIconCache.resetForTesting()
    let retained = iconApp(id: "runtime.retained", category: .media)
    let departed = iconApp(id: "runtime.departed", category: .media)
    _ = try #require(AppIconCache.icon(for: retained))
    _ = try #require(AppIconCache.icon(for: departed))

    #expect(AppIconCache.contains(runtimeID: retained.id))
    #expect(AppIconCache.contains(runtimeID: departed.id))
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

    #expect(AppIconCache.contains(runtimeID: visible.id))
    #expect(AppIconCache.contains(runtimeID: filteredSystemApp.id))
  }

  @Test func appStorePresentationFilteringDoesNotAffectTheSharedIconCache() async throws {
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
    #expect(AppIconCache.contains(runtimeID: filteredSystemApp.id))
  }

  @Test func oneAppStoreDepartureDoesNotEvictAnotherStoresSameAppIcon() async throws {
    let firstStore = await makeControlStoreFixture()
    let secondStore = await makeControlStoreFixture()
    let identity = iconRuntimeIdentity(pid: 42, startTimeSeconds: 100)
    let firstApp = iconApp(
      id: "com.example.shared",
      category: .media,
      runtimeIdentity: identity
    )
    let secondApp = firstApp
    firstStore.session.apps = [firstApp]
    secondStore.session.apps = [secondApp]
    AppIconCache.resetForTesting()
    let firstImage = try #require(AppIconCache.icon(for: firstApp))

    firstStore.session.apps = []
    let secondImage = try #require(AppIconCache.icon(for: secondApp))

    #expect(firstImage === secondImage)
    #expect(AppIconCache.contains(runtimeID: secondApp.id))
  }

  @Test func sameLogicalIDDifferentBytesKeepIndependentDecodedImages() throws {
    AppIconCache.resetForTesting()
    let identity = iconRuntimeIdentity(pid: 42, startTimeSeconds: 100)
    let firstApp = iconApp(
      id: "com.example.shared",
      category: .media,
      runtimeIdentity: identity,
      iconData: iconTIFFData(width: 4, height: 4)
    )
    let secondApp = iconApp(
      id: firstApp.id,
      category: .media,
      runtimeIdentity: identity,
      iconData: iconTIFFData(width: 7, height: 5)
    )

    let firstImage = try #require(AppIconCache.icon(for: firstApp))
    let secondImage = try #require(AppIconCache.icon(for: secondApp))
    let firstImageAgain = try #require(AppIconCache.icon(for: firstApp))

    #expect(firstImage !== secondImage)
    #expect(firstImageAgain === firstImage)
  }

  @Test func appStoreInvalidatesOnlyTheIconWhoseRuntimeLifetimeChanged() async throws {
    let store = await makeControlStoreFixture()
    let oldIdentity = iconRuntimeIdentity(pid: 42, startTimeSeconds: 100)
    let newIdentity = iconRuntimeIdentity(pid: 42, startTimeSeconds: 200)
    let unchangedIdentity = iconRuntimeIdentity(pid: 84, startTimeSeconds: 100)
    let original = iconApp(
      id: "com.example.player",
      category: .media,
      runtimeIdentity: oldIdentity
    )
    let unrelated = iconApp(
      id: "com.example.chat",
      category: .communication,
      runtimeIdentity: unchangedIdentity
    )
    store.session.apps = [original, unrelated]
    AppIconCache.resetForTesting()
    let originalImage = try #require(AppIconCache.icon(for: original))
    let unrelatedImage = try #require(AppIconCache.icon(for: unrelated))

    let replacement = iconApp(
      id: original.id,
      category: original.category,
      runtimeIdentity: newIdentity
    )
    store.session.apps = [replacement, unrelated]
    let replacementImage = try #require(AppIconCache.icon(for: replacement))
    let unrelatedImageAgain = try #require(AppIconCache.icon(for: unrelated))

    #expect(replacementImage !== originalImage)
    #expect(unrelatedImageAgain === unrelatedImage)
    #expect(AppIconCache.contains(runtimeID: unrelated.id))
  }
}

@MainActor
private func iconApp(
  id: String,
  category: AppCategory,
  runtimeIdentity: AppRuntimeIdentity? = nil,
  iconData: Data? = nil
) -> AudioApp {
  AudioApp(
    id: id,
    displayName: id,
    iconTIFFData: iconData ?? iconTIFFData(width: 4, height: 4),
    category: category,
    runtimeIdentity: runtimeIdentity
  )
}

private func iconRuntimeIdentity(pid: Int32, startTimeSeconds: UInt64) -> AppRuntimeIdentity {
  AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(
      pid: pid,
      startTimeSeconds: startTimeSeconds,
      startTimeMicroseconds: 0
    ),
    executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
    outerBundlePath: "/Applications/Fixture.app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.fixture",
      teamIdentifier: "TEAM123",
      designatedRequirement: "identifier \"com.example.fixture\"",
      codeDirectoryHash: Data([1, 2, 3])
    )
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
