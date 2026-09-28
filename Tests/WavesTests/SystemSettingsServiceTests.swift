import Foundation
import Testing

@testable import Waves

@Test func systemSettingsDestinationsProduceExpectedDeepLinks() throws {
  #expect(SystemSettingsDestination.allCases == [.audioCapture, .soundOutput])

  let expectedQueries: [SystemSettingsDestination: String] = [
    .audioCapture: "Privacy_AudioCapture",
    .soundOutput: "com.apple.Sound-Settings.extension",
  ]

  for (destination, marker) in expectedQueries {
    let url = try #require(destination.url)
    #expect(url.scheme == "x-apple.systempreferences")
    #expect(url.absoluteString.contains(marker))
  }
}

@Test @MainActor func systemSettingsServiceValidatesURLSchemes() throws {
  let service = SystemSettingsService()
  for destination in SystemSettingsDestination.allCases {
    let url = try #require(destination.url)
    #expect(url.scheme?.lowercased() == "x-apple.systempreferences")
  }
}
