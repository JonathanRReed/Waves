import Foundation
import Testing

@testable import Waves

@Test(arguments: [
  InstallLocationCase(
    bundle: "/Applications/Waves.app",
    volume: "/",
    readOnly: false,
    expected: .applications
  ),
  InstallLocationCase(
    bundle: "/Volumes/Waves/Waves.app",
    volume: "/Volumes/Waves",
    readOnly: true,
    expected: .mountedDiskImage
  ),
  InstallLocationCase(
    bundle: "/System/Volumes/ReadOnlyTools/Waves.app",
    volume: "/System/Volumes/ReadOnlyTools",
    readOnly: true,
    expected: .readOnlyExternal
  ),
  InstallLocationCase(
    bundle: "/Users/test/Downloads/Waves.app",
    volume: "/",
    readOnly: false,
    expected: .ordinaryWritable
  ),
])
func installLocationUsesCanonicalBundleAndVolumeFacts(testCase: InstallLocationCase) {
  #expect(
    InstallLocationAdvisor.classify(
      bundleURL: URL(fileURLWithPath: testCase.bundle),
      volumeURL: URL(fileURLWithPath: testCase.volume),
      volumeIsReadOnly: testCase.readOnly
    ) == testCase.expected
  )
}

@Test func applicationsClassificationRejectsLookalikePrefixes() {
  #expect(
    InstallLocationAdvisor.classify(
      bundleURL: URL(fileURLWithPath: "/Applications Backup/Waves.app"),
      volumeURL: URL(fileURLWithPath: "/"),
      volumeIsReadOnly: false
    ) == .ordinaryWritable
  )
}

@Test func installAdvisoryUsesATruthfulFinderActionForEveryLocation() {
  #expect(
    InstallLocationClassification.mountedDiskImage.finderActionTitle
      == "Open This Disk Image in Finder"
  )
  #expect(
    InstallLocationClassification.readOnlyExternal.finderActionTitle
      == "Show Waves in Finder"
  )
}

@Test func liveAdvisorReadsFactsOnceAndNeverMutatesTheBundle() throws {
  let bundle = URL(fileURLWithPath: "/Volumes/Waves/Waves.app")
  let probe = InstallLocationProbeRecorder(
    result: InstallLocationFacts(
      canonicalBundleURL: bundle,
      canonicalVolumeURL: URL(fileURLWithPath: "/Volumes/Waves"),
      volumeIsReadOnly: true
    )
  )
  let advisor = InstallLocationAdvisor(readFacts: probe.read)

  #expect(try advisor.classify(bundleURL: bundle) == .mountedDiskImage)
  #expect(probe.requestedURLs == [bundle])
}

struct InstallLocationCase: Sendable {
  let bundle: String
  let volume: String
  let readOnly: Bool
  let expected: InstallLocationClassification
}

private final class InstallLocationProbeRecorder: @unchecked Sendable {
  private let result: InstallLocationFacts
  private(set) var requestedURLs: [URL] = []

  init(result: InstallLocationFacts) {
    self.result = result
  }

  func read(_ url: URL) throws -> InstallLocationFacts {
    requestedURLs.append(url)
    return result
  }
}
