import Foundation
import Testing

@testable import Waves

@Test func appRuntimeDiscoveryProcessesCapturedValuesWithoutAppKit() {
  let capture = AppRuntimeDiscovery.Capture(
    applications: [
      .init(
        pid: 42,
        bundleID: "com.example.player",
        localizedName: "Player",
        bundlePath: "/Applications/Player.app",
        activationPolicy: .regular,
        isActive: true,
        iconTIFFData: Data([1])
      )
    ]
  )

  let apps = AppRuntimeDiscovery.discoverRunningApps(
    from: capture,
    currentBundleID: "com.example.waves",
    audiblePIDs: [42],
    audibleParentBundlePaths: []
  )

  #expect(apps.map(\.logicalID) == ["com.example.player"])
  #expect(apps.first?.iconTIFFData == Data([1]))
}
