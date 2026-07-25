import Foundation
import Testing

@testable import Waves

@Test func brandAssetLocatorFindsLogoInsidePackagedAppResources() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-brand-assets-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let appURL = root.appendingPathComponent("Waves.app", isDirectory: true)
  let resourcesURL =
    appURL
    .appendingPathComponent("Contents", isDirectory: true)
    .appendingPathComponent("Resources", isDirectory: true)
  let logoURL =
    resourcesURL
    .appendingPathComponent(WavesBrandAssetLocator.resourceBundleName, isDirectory: true)
    .appendingPathComponent(WavesBrandAssetLocator.logoFilename, isDirectory: false)
  try FileManager.default.createDirectory(
    at: logoURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data([0x89, 0x50, 0x4E, 0x47]).write(to: logoURL)

  let locatedURL = WavesBrandAssetLocator.logoURL(
    bundleURL: appURL,
    resourceURL: resourcesURL,
    executableURL:
      appURL
      .appendingPathComponent("Contents/MacOS/Waves", isDirectory: false)
  )

  #expect(locatedURL == logoURL)
}

@Test func brandAssetLocatorReturnsNilInsteadOfTrappingWhenLogoIsMissing() {
  let missingRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-missing-brand-assets-\(UUID().uuidString)", isDirectory: true)

  let locatedURL = WavesBrandAssetLocator.logoURL(
    bundleURL: missingRoot.appendingPathComponent("Waves.app", isDirectory: true),
    resourceURL: nil,
    executableURL: nil
  )

  #expect(locatedURL == nil)
}

@Test func packagedBrandAssetLocatorDoesNotLoadAnAdjacentUnsignedLogo() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-adjacent-brand-assets-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let appURL = root.appendingPathComponent("Waves.app", isDirectory: true)
  let adjacentLogoURL =
    root
    .appendingPathComponent(WavesBrandAssetLocator.resourceBundleName, isDirectory: true)
    .appendingPathComponent(WavesBrandAssetLocator.logoFilename, isDirectory: false)
  try FileManager.default.createDirectory(
    at: adjacentLogoURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data([0x89, 0x50, 0x4E, 0x47]).write(to: adjacentLogoURL)

  let locatedURL = WavesBrandAssetLocator.logoURL(
    bundleURL: appURL,
    resourceURL: appURL.appendingPathComponent("Contents/Resources", isDirectory: true),
    executableURL: appURL.appendingPathComponent("Contents/MacOS/Waves", isDirectory: false)
  )

  #expect(locatedURL == nil)
}

@Test func brandAssetLocatorSupportsSwiftPMDevelopmentBundleLayout() throws {
  let buildRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-development-assets-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: buildRoot) }

  let testBundleURL = buildRoot.appendingPathComponent(
    "WavesPackageTests.xctest", isDirectory: true)
  let logoURL =
    buildRoot
    .appendingPathComponent(WavesBrandAssetLocator.resourceBundleName, isDirectory: true)
    .appendingPathComponent(WavesBrandAssetLocator.logoFilename, isDirectory: false)
  try FileManager.default.createDirectory(
    at: logoURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data([0x89, 0x50, 0x4E, 0x47]).write(to: logoURL)

  let locatedURL = WavesBrandAssetLocator.logoURL(
    bundleURL: testBundleURL,
    resourceURL: nil,
    executableURL: nil
  )

  #expect(locatedURL == logoURL)
}
