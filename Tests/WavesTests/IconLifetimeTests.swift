import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Suite(.serialized)
@MainActor
struct IconLifetimeTests {
  @Test func stableRuntimeIdentityReusesCapturedIconBytes() async {
    let identity = runtimeIdentity(startTimeSeconds: 100)
    let known = AppRuntimeDiscovery.KnownIcon(data: Data([1]), runtimeIdentity: identity)
    let encoder = recordingEncoder(output: Data([2]))

    let result = await AppRuntimeDiscovery.resolveIconData(
      logicalID: "com.example.player",
      runtimeIdentity: identity,
      knownIcons: ["com.example.player": known],
      captureRaster: { fixtureRaster },
      iconEncoder: encoder.encoder
    )

    #expect(result == Data([1]))
    #expect(encoder.count.value == 0)
  }

  @Test func newProcessLifetimeEncodesAFreshIconForTheSameLogicalID() async {
    let oldIdentity = runtimeIdentity(startTimeSeconds: 100)
    let newIdentity = runtimeIdentity(startTimeSeconds: 200)
    let known = AppRuntimeDiscovery.KnownIcon(data: Data([1]), runtimeIdentity: oldIdentity)
    let encoder = recordingEncoder(output: Data([2]))

    let result = await AppRuntimeDiscovery.resolveIconData(
      logicalID: "com.example.player",
      runtimeIdentity: newIdentity,
      knownIcons: ["com.example.player": known],
      captureRaster: { fixtureRaster },
      iconEncoder: encoder.encoder
    )

    #expect(result == Data([2]))
    #expect(encoder.count.value == 1)
  }

  @Test func missingRuntimeIdentityDoesNotReuseCapturedIconBytes() async {
    let known = AppRuntimeDiscovery.KnownIcon(
      data: Data([1]),
      runtimeIdentity: runtimeIdentity(startTimeSeconds: 100)
    )
    let encoder = recordingEncoder(output: Data([2]))

    let result = await AppRuntimeDiscovery.resolveIconData(
      logicalID: "com.example.player",
      runtimeIdentity: nil,
      knownIcons: ["com.example.player": known],
      captureRaster: { fixtureRaster },
      iconEncoder: encoder.encoder
    )

    #expect(result == Data([2]))
    #expect(encoder.count.value == 1)
  }
}

private final class IconEncodeCount: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int { lock.withLock { storage } }

  func increment() {
    lock.withLock { storage += 1 }
  }
}

private func recordingEncoder(output: Data) -> (encoder: AppIconEncoder, count: IconEncodeCount) {
  let count = IconEncodeCount()
  let encoder = AppIconEncoder(
    operation: { _ in
      count.increment()
      return output
    },
    executor: AppIconEncodingExecutor { operation in operation() }
  )
  return (encoder, count)
}

private let fixtureRaster = AppIconRaster(
  width: 1,
  height: 1,
  bytesPerRow: 4,
  rgbaBytes: Data([0, 0, 0, 255])
)

private func runtimeIdentity(startTimeSeconds: UInt64) -> AppRuntimeIdentity {
  AppRuntimeIdentity(
    lifetime: AppProcessLifetimeIdentity(
      pid: 42,
      startTimeSeconds: startTimeSeconds,
      startTimeMicroseconds: 0
    ),
    executablePath: "/Applications/Player.app/Contents/MacOS/Player",
    outerBundlePath: "/Applications/Player.app",
    signingIdentity: AppCodeSigningIdentity(
      identifier: "com.example.player",
      teamIdentifier: "TEAM123",
      designatedRequirement: "identifier \"com.example.player\"",
      codeDirectoryHash: Data([1, 2, 3])
    )
  )
}
