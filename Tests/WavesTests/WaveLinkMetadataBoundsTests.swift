import Darwin
import Foundation
import Testing

@testable import Waves

@Test func waveLinkPublishedMetadataSkipsOversizedHintsWithoutLosingFallback() throws {
  try withWaveLinkMetadataFiles { home, urls in
    let oversized = try JSONSerialization.data(withJSONObject: ["port": 1234, "padding": String(repeating: "x", count: 65_536)])
    try oversized.write(to: urls[0])
    try Data(#"{"port":1884}"#.utf8).write(to: urls[1])
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [1884])
    #expect(WaveLinkEndpointDiscovery.parsePort(fromWSInfo: oversized) == nil)
  }
}

@Test func waveLinkPublishedMetadataDoesNotFollowALeafSymlink() throws {
  try withWaveLinkMetadataFiles { home, urls in
    let target = home.appendingPathComponent("target.json")
    let contents = Data(#"{"port":1234}"#.utf8)
    try contents.write(to: target)
    try FileManager.default.createSymbolicLink(at: urls[0], withDestinationURL: target)
    try Data(#"{"port":1884}"#.utf8).write(to: urls[1])
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [1884])
    #expect(try Data(contentsOf: target) == contents)
  }
}

@Test func waveLinkPublishedMetadataAcceptsTheExactByteLimitWithoutChangingPermissions() throws {
  try withWaveLinkMetadataFiles { home, urls in
    let prefix = "{\"port\":1234,\"padding\":\""
    let suffix = "\"}"
    let contents = Data((prefix + String(repeating: "x", count: 65_536 - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    #expect(contents.count == 65_536)
    try contents.write(to: urls[0])
    let before = try FileManager.default.attributesOfItem(atPath: urls[0].path)[.posixPermissions] as? NSNumber
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [1234])
    let after = try FileManager.default.attributesOfItem(atPath: urls[0].path)[.posixPermissions] as? NSNumber
    #expect(before == after)
  }
}

@Test func waveLinkPublishedMetadataSkipsAFIFOWithoutOpeningIt() throws {
  try withWaveLinkMetadataFiles { home, urls in
    #expect(mkfifo(urls[0].path, 0o600) == 0)
    try Data(#"{"port":1884}"#.utf8).write(to: urls[1])
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [1884])
  }
}

@Test func waveLinkPublishedMetadataKeepsBoundsThroughADirectoryAlias() throws {
  try withWaveLinkMetadataFiles { home, urls in
    let originalDirectory = urls[0].deletingLastPathComponent()
    let actualDirectory = home.appendingPathComponent("actual-hints")
    try FileManager.default.moveItem(at: originalDirectory, to: actualDirectory)
    try FileManager.default.createSymbolicLink(at: originalDirectory, withDestinationURL: actualDirectory)
    let actualFile = actualDirectory.appendingPathComponent("ws-info.json")
    try Data(#"{"port":1234}"#.utf8).write(to: actualFile)
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home) == [1234])

    let oversized = try JSONSerialization.data(withJSONObject: ["port": 1234, "padding": String(repeating: "x", count: 65_536)])
    try oversized.write(to: actualFile)
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home).isEmpty)
    try FileManager.default.removeItem(at: actualFile)
    #expect(mkfifo(actualFile.path, 0o600) == 0)
    #expect(WaveLinkEndpointDiscovery.publishedPorts(homeDirectory: home).isEmpty)
  }
}

private func withWaveLinkMetadataFiles(_ body: (URL, [URL]) throws -> Void) throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("waves-ws-bounds-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: home) }
  let urls = WaveLinkEndpointDiscovery.wsInfoCandidateURLs(homeDirectory: home)
  for url in urls {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  try body(home, urls)
}
