import Darwin
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

@Test func appRuntimeDiscoveryRejectsAnAdHocChildIdentifierWithoutAuthenticatedMembership() {
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

  #expect(AppRuntimeDiscovery.processFamily(for: target, in: [target, helper]).map(\.pid) == [42])
}

@Test func appRuntimeDiscoveryKeepsAnExactAdHocNestedHelperIdentity() {
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
    bundleID: "com.example.player",
    localizedName: "Player Helper",
    bundlePath: "/Applications/Player.app/Contents/Helpers/Player Helper.app",
    activationPolicy: .accessory,
    isActive: false,
    iconTIFFData: nil,
    runtimeIdentity: testRuntimeIdentity(
      pid: 84,
      outerBundlePath: "/Applications/Player.app",
      signingIdentifier: "com.example.player"
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

@Test func runtimeSigningIdentityBindsStableEvidenceBackToTheDynamicCodeInOrder() throws {
  let identity = testRuntimeIdentity(
    pid: 42,
    outerBundlePath: "/Applications/Player.app",
    signingIdentifier: "com.example.player",
    teamIdentifier: "TEAM123"
  ).signingIdentity
  let fixture = RuntimeSigningOperationsFixture(
    snapshots: [
      .init(identity: identity, designatedRequirement: "requirement-a"),
      .init(identity: identity, designatedRequirement: "requirement-a"),
    ],
    validityResults: [true, true]
  )

  let captured = RuntimeProcessIdentity.validatedSigningIdentity(pid: 42, operations: fixture)

  #expect(captured == identity)
  #expect(
    fixture.events == [
      "copy-dynamic:42",
      "check:nil",
      "snapshot",
      "check:requirement-a",
      "snapshot",
    ])
}

@Test func runtimeSigningIdentityRejectsAFinalDynamicRequirementFailure() {
  let identity = testRuntimeIdentity(
    pid: 42,
    outerBundlePath: "/Applications/Player.app",
    signingIdentifier: "com.example.player",
    teamIdentifier: "TEAM123"
  ).signingIdentity
  let fixture = RuntimeSigningOperationsFixture(
    snapshots: [
      .init(identity: identity, designatedRequirement: "requirement-a"),
      .init(identity: identity, designatedRequirement: "requirement-a"),
    ],
    validityResults: [true, false]
  )

  #expect(RuntimeProcessIdentity.validatedSigningIdentity(pid: 42, operations: fixture) == nil)
  #expect(
    fixture.events == [
      "copy-dynamic:42",
      "check:nil",
      "snapshot",
      "check:requirement-a",
    ])
}

@Test func runtimeSigningIdentityRejectsSamePathEvidenceSubstitution() {
  let original = testRuntimeIdentity(
    pid: 42,
    outerBundlePath: "/Applications/Player.app",
    signingIdentifier: "com.example.player",
    teamIdentifier: "TEAM123"
  ).signingIdentity
  let replacement = AppCodeSigningIdentity(
    identifier: "com.example.replacement",
    teamIdentifier: "OTHERTEAM",
    designatedRequirement: "identifier \"com.example.replacement\"",
    codeDirectoryHash: Data([9, 9, 9])
  )
  let fixture = RuntimeSigningOperationsFixture(
    snapshots: [
      .init(identity: original, designatedRequirement: "requirement-a"),
      .init(identity: replacement, designatedRequirement: "requirement-b"),
    ],
    validityResults: [true, true]
  )

  #expect(RuntimeProcessIdentity.validatedSigningIdentity(pid: 42, operations: fixture) == nil)
  #expect(fixture.events.suffix(2) == ["check:requirement-a", "snapshot"])
}

@Test func securityFrameworkBindsRealAdHocNestedHelperFixtures() throws {
  let fixture = try RuntimeSigningProcessFixture()
  defer { fixture.dispose() }

  let targetProcess = try fixture.launch(fixture.targetExecutable)
  let exactHelperProcess = try fixture.launch(fixture.exactHelperExecutable)
  let childIdentifierProcess = try fixture.launch(fixture.childIdentifierExecutable)
  let target = try #require(waitForRuntimeIdentity(pid: targetProcess.processIdentifier))
  let exactHelper = try #require(
    waitForRuntimeIdentity(pid: exactHelperProcess.processIdentifier)
  )
  let childIdentifier = try #require(
    waitForRuntimeIdentity(pid: childIdentifierProcess.processIdentifier)
  )

  #expect(target.signingIdentity.teamIdentifier == nil)
  #expect(exactHelper.signingIdentity == target.signingIdentity)
  #expect(
    AppDiscoveryPolicy.runtimeFamilyMatches(
      target: target,
      candidate: exactHelper
    ))
  #expect(
    !AppDiscoveryPolicy.runtimeFamilyMatches(
      target: target,
      candidate: childIdentifier
    ))
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

private final class RuntimeSigningOperationsFixture: RuntimeSigningIdentityOperating {
  typealias DynamicCode = Int
  typealias DesignatedRequirement = String

  private var snapshots: [RuntimeSigningSnapshot<String>]
  private var validityResults: [Bool]
  private(set) var events: [String] = []

  init(
    snapshots: [RuntimeSigningSnapshot<String>],
    validityResults: [Bool]
  ) {
    self.snapshots = snapshots
    self.validityResults = validityResults
  }

  func copyDynamicCode(pid: pid_t) -> Int? {
    events.append("copy-dynamic:\(pid)")
    return 1
  }

  func checkValidity(_ code: Int, requirement: String?) -> Bool {
    events.append("check:\(requirement ?? "nil")")
    return validityResults.removeFirst()
  }

  func copySigningSnapshot(_ code: Int) -> RuntimeSigningSnapshot<String>? {
    events.append("snapshot")
    return snapshots.removeFirst()
  }
}

private final class RuntimeSigningProcessFixture {
  let targetExecutable: URL
  let exactHelperExecutable: URL
  let childIdentifierExecutable: URL

  private let rootURL: URL
  private var processes: [Process] = []

  init() throws {
    let fileManager = FileManager.default
    rootURL = fileManager.temporaryDirectory
      .appendingPathComponent("waves-runtime-signing-\(UUID().uuidString)", isDirectory: true)
    let outerBundle = rootURL.appendingPathComponent("Fixture.app", isDirectory: true)
    targetExecutable = outerBundle.appendingPathComponent("Contents/MacOS/Fixture")
    exactHelperExecutable = outerBundle.appendingPathComponent(
      "Contents/Helpers/Fixture Helper.app/Contents/MacOS/Fixture Helper"
    )
    childIdentifierExecutable = outerBundle.appendingPathComponent(
      "Contents/Helpers/Chosen Child.app/Contents/MacOS/Chosen Child"
    )

    try fileManager.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let exactSignedSource = rootURL.appendingPathComponent("exact-signed-source")
    try fileManager.copyItem(
      at: URL(fileURLWithPath: "/bin/sleep"),
      to: exactSignedSource
    )
    try Self.run(
      "/usr/bin/codesign",
      arguments: [
        "--force",
        "--sign",
        "-",
        "--identifier",
        "com.example.waves.runtime-fixture",
        exactSignedSource.path,
      ]
    )
    for executable in [targetExecutable, exactHelperExecutable] {
      try fileManager.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: exactSignedSource, to: executable)
    }

    let childSignedSource = rootURL.appendingPathComponent("child-signed-source")
    try fileManager.copyItem(
      at: URL(fileURLWithPath: "/bin/sleep"),
      to: childSignedSource
    )
    try Self.run(
      "/usr/bin/codesign",
      arguments: [
        "--force",
        "--sign",
        "-",
        "--identifier",
        "com.example.waves.runtime-fixture.child",
        childSignedSource.path,
      ]
    )
    try fileManager.createDirectory(
      at: childIdentifierExecutable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.copyItem(
      at: childSignedSource,
      to: childIdentifierExecutable
    )
  }

  func launch(_ executable: URL) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["30"]
    try process.run()
    processes.append(process)
    return process
  }

  func dispose() {
    for process in processes where process.isRunning {
      process.terminate()
    }
    for process in processes {
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: rootURL)
  }

  private static func run(_ executable: String, arguments: [String]) throws {
    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let detail = String(data: data, encoding: .utf8) ?? "Unknown fixture error"
      throw RuntimeSigningFixtureError.commandFailed(detail)
    }
  }
}

private enum RuntimeSigningFixtureError: Error {
  case commandFailed(String)
}

private func waitForRuntimeIdentity(pid: pid_t) -> AppRuntimeIdentity? {
  for _ in 0..<100 {
    if let identity = RuntimeProcessIdentity.captureLive(pid: pid) {
      return identity
    }
    usleep(10_000)
  }
  return nil
}
