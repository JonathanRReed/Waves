import Foundation

struct InstallLocationFacts: Equatable, Sendable {
  let canonicalBundleURL: URL
  let canonicalVolumeURL: URL
  let volumeIsReadOnly: Bool
}

struct InstallLocationAdvisor: Sendable {
  typealias ReadFacts = @Sendable (URL) throws -> InstallLocationFacts

  private let readFacts: ReadFacts

  init(readFacts: @escaping ReadFacts = Self.readLiveFacts) {
    self.readFacts = readFacts
  }

  func classify(bundleURL: URL) throws -> InstallLocationClassification {
    let facts = try readFacts(bundleURL)
    return Self.classify(
      bundleURL: facts.canonicalBundleURL,
      volumeURL: facts.canonicalVolumeURL,
      volumeIsReadOnly: facts.volumeIsReadOnly
    )
  }

  static func classify(
    bundleURL: URL,
    volumeURL: URL,
    volumeIsReadOnly: Bool
  ) -> InstallLocationClassification {
    let canonicalBundleURL = canonical(bundleURL)
    let canonicalVolumeURL = canonical(volumeURL)
    let bundlePath = canonicalBundleURL.path
    let volumePath = canonicalVolumeURL.path

    if bundlePath.hasPrefix("/Applications/") {
      return .applications
    }
    if volumeIsReadOnly, volumePath.hasPrefix("/Volumes/") {
      return .mountedDiskImage
    }
    if volumeIsReadOnly {
      return .readOnlyExternal
    }
    return .ordinaryWritable
  }

  private static func readLiveFacts(_ bundleURL: URL) throws -> InstallLocationFacts {
    let canonicalBundleURL = canonical(bundleURL)
    let values = try canonicalBundleURL.resourceValues(
      forKeys: [.volumeURLKey, .volumeIsReadOnlyKey]
    )
    let canonicalVolumeURL = canonical(values.volume ?? URL(fileURLWithPath: "/"))
    return InstallLocationFacts(
      canonicalBundleURL: canonicalBundleURL,
      canonicalVolumeURL: canonicalVolumeURL,
      volumeIsReadOnly: values.volumeIsReadOnly ?? false
    )
  }

  private static func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}
