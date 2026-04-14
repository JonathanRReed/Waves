import Testing

@testable import WavesAudioCore

@Test func supportMatrixCoverageSummaryCountsSupportedApps() {
  let matrix = SupportMatrix(
    entries: [
      SupportMatrixEntry(
        appID: "safari",
        displayName: "Safari",
        category: .browser,
        state: .supported
      ),
      SupportMatrixEntry(
        appID: "zoom",
        displayName: "Zoom",
        category: .conferencing,
        state: .supported
      ),
      SupportMatrixEntry(
        appID: "discord",
        displayName: "Discord",
        category: .communication,
        state: .validating
      ),
    ]
  )

  #expect(matrix.coverageSummary == "2/3 validated")
}

@Test func presetDefaultsContainDailyUseProfiles() {
  let presets = Preset.defaults

  #expect(presets.count >= 2)
  #expect(presets.contains(where: { $0.name == "Focus" }))
  #expect(presets.contains(where: { $0.name == "Meeting" }))
}

@Test func previewSnapshotIncludesCurrentDeviceAndApps() {
  let snapshot = AudioSessionSnapshot.preview

  #expect(snapshot.currentDevice?.name == "MacBook Pro Speakers")
  #expect(snapshot.apps.count == 4)
  #expect(snapshot.apps.contains(where: { $0.routingState == .managed }))
}
