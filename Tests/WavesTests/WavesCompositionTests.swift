import Foundation
import Testing

@testable import Waves

@Test func previewFixtureAppsDecodeIntoAManagedControlSnapshot() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("WavesCompositionTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let fixtureURL = directory.appendingPathComponent("preview-apps.json")
  try Data(
    """
    [
      {
        "id": "com.spotify.client",
        "bundleID": "com.spotify.client",
        "name": "Spotify",
        "running": true,
        "live": true,
        "managed": true,
        "volume": 0.8,
        "muted": false
      },
      {
        "id": "com.tinyspeck.slackmacgap",
        "bundleID": "com.tinyspeck.slackmacgap",
        "name": "Slack",
        "running": false,
        "live": false,
        "managed": false,
        "volume": 0.5,
        "muted": true
      }
    ]
    """.utf8
  ).write(to: fixtureURL)

  let snapshot = try #require(
    WavesComposition.previewSnapshot(
      environment: [
        "CFFIXED_USER_HOME": directory.path,
        "WAVES_PREVIEW_APPS_PATH": fixtureURL.path,
      ]
    )
  )

  #expect(snapshot.apps.map(\.logicalID) == ["com.spotify.client", "com.tinyspeck.slackmacgap"])
  #expect(snapshot.apps[0].routingState == .managed)
  #expect(snapshot.apps[0].compatibility == .supported)
  #expect(snapshot.apps[1].routingState == .monitorOnly)
  #expect(snapshot.apps[1].compatibility == .unsupported)
  #expect(snapshot.backendStatus.hasRequiredPermissions)

  #expect(
    WavesComposition.previewSnapshot(
      environment: ["WAVES_PREVIEW_APPS_PATH": fixtureURL.path]
    ) == nil,
    "the packaged fixture must never target durable user state"
  )
}
