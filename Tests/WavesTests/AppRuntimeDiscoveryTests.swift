import Foundation
import Testing
import WavesAudioCore

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

@Test func appRuntimeDiscoveryDoesNotTrustASpoofedBundleFamily() {
  let target = AppRuntimeDiscovery.CapturedApplication(
    pid: 42,
    bundleID: "com.example.player",
    localizedName: "Player",
    bundlePath: "/Applications/Player.app",
    activationPolicy: .regular,
    isActive: true,
    iconTIFFData: nil,
    runtimeIdentity: testRuntimeIdentity(
      pid: 42,
      outerBundlePath: "/Applications/Player.app",
      signingIdentifier: "com.example.player",
      teamIdentifier: "TEAM123"
    )
  )
  let spoof = AppRuntimeDiscovery.CapturedApplication(
    pid: 84,
    bundleID: "com.example.player.helper",
    localizedName: "Player Helper",
    bundlePath: "/Applications/Spoof.app",
    activationPolicy: .accessory,
    isActive: false,
    iconTIFFData: nil,
    runtimeIdentity: testRuntimeIdentity(
      pid: 84,
      outerBundlePath: "/Applications/Spoof.app",
      signingIdentifier: "com.example.player.helper",
      teamIdentifier: "TEAM123"
    )
  )

  #expect(AppRuntimeDiscovery.processFamily(for: target, in: [target, spoof]).map(\.pid) == [42])
}

@Test func appRuntimeDiscoveryKeepsALegitimateNestedHelperFamily() {
  let target = AppRuntimeDiscovery.CapturedApplication(
    pid: 42,
    bundleID: "com.example.player",
    localizedName: "Player",
    bundlePath: "/Applications/Player.app",
    activationPolicy: .regular,
    isActive: true,
    iconTIFFData: nil,
    runtimeIdentity: testRuntimeIdentity(
      pid: 42,
      outerBundlePath: "/Applications/Player.app",
      signingIdentifier: "com.example.player"
    )
  )
  let helper = AppRuntimeDiscovery.CapturedApplication(
    pid: 84,
    bundleID: "com.example.audio-service",
    localizedName: "Audio Service",
    bundlePath: "/Applications/Player.app/Contents/Helpers/Audio Service.app",
    activationPolicy: .accessory,
    isActive: false,
    iconTIFFData: nil,
    runtimeIdentity: testRuntimeIdentity(
      pid: 84,
      outerBundlePath: "/Applications/Player.app",
      signingIdentifier: "com.example.player.audio-service"
    )
  )

  #expect(AppRuntimeDiscovery.processFamily(for: target, in: [target, helper]).map(\.pid) == [42, 84])
}

@Test func appRuntimeDiscoveryDoesNotTreatAReusedPIDAsTheSameRunningProcess() {
  let previous = AudioApp(
    id: "runtime.player",
    logicalID: "com.example.player",
    pid: 42,
    bundleID: "com.example.player",
    displayName: "Player",
    category: .media,
    runtimeIdentity: testRuntimeIdentity(
      pid: 42,
      startTimeSeconds: 100,
      outerBundlePath: "/Applications/Player.app",
      signingIdentifier: "com.example.player",
      teamIdentifier: "TEAM123"
    )
  )
  let replacement = AppRuntimeDiscovery.CapturedApplication(
    pid: 42,
    bundleID: "com.example.player",
    localizedName: "Player",
    bundlePath: "/Applications/Player.app",
    activationPolicy: .regular,
    isActive: true,
    iconTIFFData: nil,
    runtimeIdentity: testRuntimeIdentity(
      pid: 42,
      startTimeSeconds: 200,
      outerBundlePath: "/Applications/Player.app",
      signingIdentifier: "com.example.player",
      teamIdentifier: "TEAM123"
    )
  )

  #expect(
    !AppRuntimeDiscovery.isStillRunning(
      previous,
      in: .init(applications: [replacement]),
      currentBundleID: "com.example.waves"
    ))
}

@Test func runtimeIdentityFamilyFailsClosedWhenSigningEvidenceIsIncomplete() {
  let target = testRuntimeIdentity(
    pid: 42,
    outerBundlePath: "/Applications/Player.app",
    signingIdentifier: "com.example.player",
    teamIdentifier: "TEAM123"
  )
  let ambiguousHelper = AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(
      pid: 84,
      startTimeSeconds: 100,
      startTimeMicroseconds: 0
    ),
    executablePath: "/Applications/Player.app/Contents/Helpers/Helper.app/Contents/MacOS/Helper",
    outerBundlePath: "/Applications/Player.app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.player.helper",
      teamIdentifier: "TEAM123",
      designatedRequirement: "",
      codeDirectoryHash: Data()
    )
  )

  #expect(!AppDiscoveryPolicy.runtimeFamilyMatches(target: target, candidate: ambiguousHelper))
}

@Test func runtimeIdentityCacheInvalidatesOnLifetimeAndPathChange() throws {
  let fixture = RuntimeIdentityCacheFixture()
  fixture.setProbe(pid: 42, startTimeSeconds: 100, outerBundlePath: "/Applications/Player.app")
  let cache = RuntimeProcessIdentityCache(
    maximumEntryCount: 4,
    probeProvider: fixture.probe,
    captureProvider: fixture.capture
  )

  let first = try #require(cache.identity(pid: 42))
  let repeated = try #require(cache.identity(pid: 42))
  #expect(first == repeated)
  #expect(fixture.captureCallCount == 1)

  fixture.setProbe(pid: 42, startTimeSeconds: 200, outerBundlePath: "/Applications/Player.app")
  let newLifetime = try #require(cache.identity(pid: 42))
  #expect(newLifetime.lifetime.startTimeSeconds == 200)
  #expect(fixture.captureCallCount == 2)

  fixture.setProbe(pid: 42, startTimeSeconds: 200, outerBundlePath: "/Applications/Player 2.app")
  let newPath = try #require(cache.identity(pid: 42))
  #expect(newPath.outerBundlePath == "/Applications/Player 2.app")
  #expect(fixture.captureCallCount == 3)
}

@Test func runtimeIdentityCacheEvictsLeastRecentEntriesAtItsBound() {
  let fixture = RuntimeIdentityCacheFixture()
  for pid: Int32 in 1...3 {
    fixture.setProbe(
      pid: pid,
      startTimeSeconds: UInt64(pid),
      outerBundlePath: "/Applications/Player\(pid).app"
    )
  }
  let cache = RuntimeProcessIdentityCache(
    maximumEntryCount: 2,
    probeProvider: fixture.probe,
    captureProvider: fixture.capture
  )

  #expect(cache.identity(pid: 1) != nil)
  #expect(cache.identity(pid: 2) != nil)
  #expect(cache.identity(pid: 3) != nil)
  #expect(cache.identity(pid: 1) != nil)
  #expect(fixture.captureCallCount == 4)
}

private func testRuntimeIdentity(
  pid: Int32,
  startTimeSeconds: UInt64 = 100,
  outerBundlePath: String,
  signingIdentifier: String,
  teamIdentifier: String? = nil
) -> AppRuntimeIdentity {
  AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(
      pid: pid,
      startTimeSeconds: startTimeSeconds,
      startTimeMicroseconds: 0
    ),
    executablePath: outerBundlePath + "/Contents/MacOS/Executable",
    outerBundlePath: outerBundlePath,
    signingIdentity: AppCodeSigningIdentity(
      identifier: signingIdentifier,
      teamIdentifier: teamIdentifier,
      designatedRequirement: "identifier \"\(signingIdentifier)\"",
      codeDirectoryHash: Data(signingIdentifier.utf8)
    )
  )
}

private final class RuntimeIdentityCacheFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var probes: [pid_t: RuntimeProcessProbe] = [:]
  private var captures = 0

  var captureCallCount: Int {
    lock.withLock { captures }
  }

  func setProbe(
    pid: pid_t,
    startTimeSeconds: UInt64,
    outerBundlePath: String
  ) {
    lock.withLock {
      probes[pid] = RuntimeProcessProbe(
        lifetime: AppProcessLifetimeIdentity(
          pid: pid,
          startTimeSeconds: startTimeSeconds,
          startTimeMicroseconds: 0
        ),
        executablePath: outerBundlePath + "/Contents/MacOS/Player",
        outerBundlePath: outerBundlePath
      )
    }
  }

  func probe(pid: pid_t) -> RuntimeProcessProbe? {
    lock.withLock { probes[pid] }
  }

  func capture(pid: pid_t, probe: RuntimeProcessProbe) -> AppRuntimeIdentity? {
    lock.withLock { captures += 1 }
    return AppRuntimeIdentity(
      lifetime: probe.lifetime,
      executablePath: probe.executablePath,
      outerBundlePath: probe.outerBundlePath,
      signingIdentity: AppCodeSigningIdentity(
        identifier: "com.example.player",
        teamIdentifier: "TEAM123",
        designatedRequirement: "identifier \"com.example.player\"",
        codeDirectoryHash: Data([1, 2, 3])
      )
    )
  }
}
