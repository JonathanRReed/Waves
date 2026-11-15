import AppKit
import Observation
import SwiftUI
import Testing
import WavesAudioCore

@testable import Waves

// MARK: - Volume taper wiring

@MainActor
@Test func taperedVolumeSliderPlacesTheThumbAtTheSquareRootOfTheStoredVolume() async throws {
  let app = polishApp(volume: 0.25)
  let fixture = try await makePolishFixture(apps: [app])
  defer { fixture.cleanup() }

  let thumb = TaperedVolumeSlider.thumbPosition(for: app, in: fixture.store)
  #expect(thumb.wrappedValue == 0.5)

  // Dragging the thumb to three quarters stores 0.5625, not 0.75.
  thumb.wrappedValue = 0.75
  #expect(fixture.store.session.apps.first?.desiredVolume == 0.5625)
  thumb.wrappedValue = 1
  #expect(fixture.store.session.apps.first?.desiredVolume == 1)
  thumb.wrappedValue = .nan
  #expect(fixture.store.session.apps.first?.desiredVolume == 1)
}

// MARK: - Adaptive Mix tag

@Test func adaptiveGainReadoutAppearsAtHalfADecibelAndRoundsToWholeDecibels() {
  #expect(AdaptiveGainReadout.displayedDecibels(gain: nil, previous: nil) == nil)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -0.49, previous: nil) == nil)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -0.5, previous: nil) == -1)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: 0.6, previous: nil) == 1)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -4.2, previous: nil) == -4)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -4.6, previous: nil) == -5)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: 3.4, previous: nil) == 3)
}

@Test func adaptiveGainReadoutHoldsAcrossTheThresholdAndRoundingBoundaries() {
  // Hovering just under the appear threshold keeps a tag that is already up.
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -0.4, previous: -1) == -1)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -0.34, previous: -1) == nil)

  // A gain wobbling around -4.5 dB does not flip between -4 and -5.
  var shown: Int? = nil
  var changes = 0
  for gain: Float in [-4.4, -4.6, -4.45, -4.55, -4.5, -4.62, -4.38, -4.7] {
    let next = AdaptiveGainReadout.displayedDecibels(gain: gain, previous: shown)
    if next != shown { changes += 1 }
    shown = next
  }
  #expect(changes == 1)
  #expect(shown == -4)

  // A real move still updates.
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -5.8, previous: -4) == -6)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: 2, previous: -1) == 2)
}

@Test func adaptiveGainReadoutRejectsNonFiniteGains() {
  #expect(AdaptiveGainReadout.displayedDecibels(gain: .nan, previous: -3) == nil)
  #expect(AdaptiveGainReadout.displayedDecibels(gain: -.infinity, previous: nil) == nil)
}

@Test func adaptiveGainReadoutWordsTheChange() {
  #expect(AdaptiveGainReadout.text(decibels: -4) == "\u{2212}4 dB")
  #expect(AdaptiveGainReadout.text(decibels: 3) == "+3 dB")
  #expect(
    AdaptiveGainReadout.accessibilityLabel(decibels: -4, appName: "Spotify")
      == "Adaptive Mix is turning Spotify down by 4 dB right now.")
  #expect(
    AdaptiveGainReadout.accessibilityLabel(decibels: 2, appName: "Zoom")
      == "Adaptive Mix is turning Zoom up by 2 dB right now.")
}

@MainActor
@Test func adaptiveGainTagShowsWhileTheEngineIsApplyingAGain() async throws {
  let app = polishApp()
  let fixture = try await makePolishFixture(apps: [app])
  defer { fixture.cleanup() }
  let surface = PolishHostedSurface(
    rootView: AdaptiveGainTag(appID: app.logicalID, appName: app.displayName)
      .environment(fixture.store)
  )
  defer { surface.close() }
  #expect(surface.hostingView.fittingSize.width == 0)

  fixture.store.adaptiveGainsDBByAppID[app.logicalID] = -4.2
  surface.pump()
  let shownWidth = surface.hostingView.fittingSize.width
  #expect(shownWidth > 20)

  // A different value keeps the same width, so nothing beside it moves.
  fixture.store.adaptiveGainsDBByAppID[app.logicalID] = -11.8
  surface.pump()
  #expect(surface.hostingView.fittingSize.width == shownWidth)

  // Another app's gain does not show on this row.
  fixture.store.adaptiveGainsDBByAppID = ["com.example.other": -6]
  surface.pump(0.3)
  #expect(surface.hostingView.fittingSize.width == 0)
}

/// Rows and lists must not read the fast-changing store state themselves; only
/// the leaf views built for it may. A row that read `adaptiveGainsDBByAppID` or
/// `liveLevels` would re-render, and the list would re-diff, ten times a second.
@Test func onlyLeafViewsReadFastChangingStoreState() throws {
  let viewsRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Waves", isDirectory: true)
  let allowed: [String: Set<String>] = [
    "adaptiveGainsDBByAppID": ["AdaptiveGainTag.swift"],
    "liveLevels": ["RowLevelMeter.swift"],
  ]
  let viewDirectories = ["Features", "Shared/UI", "Settings", "App"]
  for directory in viewDirectories {
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: viewsRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil))
    for case let file as URL in enumerator where file.pathExtension == "swift" {
      let source = try String(contentsOf: file, encoding: .utf8)
      for (property, files) in allowed where source.contains(property) {
        // Comments may name the property; code may not.
        let codeLines = source.split(separator: "\n").filter {
          !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            && $0.contains(property)
        }
        #expect(
          codeLines.isEmpty || files.contains(file.lastPathComponent),
          "\(file.lastPathComponent) reads \(property)")
      }
    }
  }
}

// MARK: - Live state and list invalidation

private final class ObservationFlag: @unchecked Sendable {
  var fired = false
}

@MainActor
private func observeLiveLists(_ store: AppStore) -> ObservationFlag {
  let flag = ObservationFlag()
  withObservationTracking {
    _ = store.liveApps
    _ = store.recentApps
    _ = store.sourceCounts
    _ = store.menuBarStatus
    _ = store.hasLiveAudio
    _ = MenuBarLayout.makeAppList(
      visibleApps: store.visibleApps,
      isRecentlyLive: store.isRecentlyLive,
      isExcluded: store.isExcluded
    )
  } onChange: {
    flag.fired = true
  }
  return flag
}

/// The Live list, the sidebar counts, the menu-bar panel's list, and the
/// menu-bar icon all ask whether an app is playing. They must re-evaluate when
/// an app starts or stops playing, and not on every level tick while it plays.
@MainActor
@Test func liveListsIgnoreLevelTicksButFollowPlayingChanges() async throws {
  let app = polishApp()
  let fixture = try await makePolishFixture(apps: [app])
  defer { fixture.cleanup() }
  let store = fixture.store
  store.liveLevels = [app.logicalID: AudioLevels(peak: 0.3, rms: 0.2)]
  #expect(store.isLive(app))
  #expect(store.liveApps.map(\.logicalID) == [app.logicalID])

  let tick = observeLiveLists(store)
  store.liveLevels = [app.logicalID: AudioLevels(peak: 0.42, rms: 0.31)]
  #expect(tick.fired == false, "a level tick re-evaluated a list")

  let stop = observeLiveLists(store)
  store.liveLevels = [app.logicalID: AudioLevels(peak: 0, rms: 0)]
  #expect(stop.fired)
  #expect(store.isLive(app) == false)
}

@MainActor
@Test func isLiveKeepsItsMeaningAcrossPollAndSnapshotStates() async throws {
  let managed = polishApp(id: "com.example.managed")
  let muted = polishApp(id: "com.example.muted", muted: true)
  let live = polishApp(id: "com.example.live", state: .live)
  var snapshotLevels = polishApp(id: "com.example.snapshot")
  snapshotLevels.peakLevel = 0.2
  let fixture = try await makePolishFixture(apps: [managed, muted, live, snapshotLevels])
  defer { fixture.cleanup() }
  let store = fixture.store

  // No poll yet: the snapshot's own levels decide for managed apps.
  #expect(store.isLive(managed) == false)
  #expect(store.isLive(snapshotLevels))
  #expect(store.isLive(live))
  #expect(store.isLive(muted) == false)

  // A poll entry is authoritative, quiet or loud, and the threshold is unchanged.
  store.liveLevels = [
    managed.logicalID: AudioLevels(peak: 0.0016, rms: 0),
    snapshotLevels.logicalID: AudioLevels(peak: 0.0015, rms: 0.001),
    muted.logicalID: AudioLevels(peak: 0.5, rms: 0.5),
  ]
  #expect(store.isLive(managed))
  #expect(store.isLive(snapshotLevels) == false)
  #expect(store.isLive(muted) == false)
  #expect(store.isLive(live))

  // Clearing the poll falls back to the snapshot again.
  store.liveLevels = [:]
  #expect(store.isLive(managed) == false)
  #expect(store.isLive(snapshotLevels))
}

// MARK: - Row and menu-bar polish

@MainActor
@Test func mainWindowRowHasAVisibleMoreMenuBesideBoost() async throws {
  let app = polishApp()
  let fixture = try await makePolishFixture(apps: [app])
  defer { fixture.cleanup() }
  let surface = PolishHostedSurface(
    rootView: MixerRowView(app: app).environment(fixture.store).frame(width: 760),
    size: NSSize(width: 760, height: 80)
  )
  defer { surface.close() }

  let menus = surface.views(of: NSPopUpButton.self)
  // Boost shows its value as a title; More is the icon-only one.
  #expect(menus.map(\.title).contains("1x"))
  #expect(menus.contains { $0.title.isEmpty })
  #expect(MixerRowAccessibility.moreActionsLabel(for: app) == "More actions for Polish Player")
  #expect(MenuBarRowAccessibility.moreActionsLabel(for: app) == MixerRowAccessibility.moreActionsLabel(for: app))
}

@MainActor
@Test func menuBarRowShowsBoostAndEqualizerWhenTheyAreOn() async throws {
  let plain = polishApp(id: "com.example.plain")
  let shaped = polishApp(id: "com.example.shaped", boost: 3)
  let fixture = try await makePolishFixture(apps: [plain, shaped]) { preferences in
    preferences.appEqualizerSettings[shaped.logicalID] = EqualizerSettings(isEnabled: true)
  }
  defer { fixture.cleanup() }
  #expect(fixture.store.equalizerSettings(for: shaped).isEnabled)

  func idealWidth(_ app: AudioApp) -> CGFloat {
    let surface = PolishHostedSurface(rootView: MenuBarAppRow(app: app).environment(fixture.store))
    defer { surface.close() }
    return surface.hostingView.fittingSize.width
  }
  // The same name length, so only the indicators can account for the difference.
  #expect(idealWidth(shaped) > idealWidth(plain) + 20)
}

@MainActor
@Test func menuBarStatusIconKeepsOneWidthInEveryState() {
  let statuses: [AppStore.MenuBarStatus] = [.setup, .playing, .muted, .idle]
  let sizes = statuses.map { MenuBarStatusIcon.image(for: $0).size }
  #expect(Set(sizes.map(\.width)).count == 1)
  #expect(Set(sizes.map(\.height)).count == 1)
  #expect(sizes.allSatisfy { $0 == MenuBarStatusIcon.canvasSize })
  #expect(statuses.allSatisfy { MenuBarStatusIcon.image(for: $0).isTemplate })
  // Wide enough for the widest glyph, so nothing is clipped.
  for status in statuses {
    let symbol = NSImage(
      systemSymbolName: MenuBarStatusIcon.symbolName(for: status), accessibilityDescription: nil)
    #expect((symbol?.size.width ?? .infinity) <= MenuBarStatusIcon.canvasSize.width)
  }
  #expect(MenuBarStatusLabel.accessibilityLabel(for: .playing) == "Waves, playing")
  #expect(MenuBarStatusLabel.accessibilityLabel(for: .setup) == "Waves, finish setup")
}

@Test func hoverFillIsQuietAndStrongerUnderIncreaseContrast() {
  #expect(WavesHoverFill.opacity(isHovering: false, isPressed: false, increasedContrast: false) == 0)
  let hover = WavesHoverFill.opacity(isHovering: true, isPressed: false, increasedContrast: false)
  let pressed = WavesHoverFill.opacity(isHovering: true, isPressed: true, increasedContrast: false)
  #expect(hover > 0 && hover < pressed && pressed <= 0.2)
  #expect(WavesHoverFill.opacity(isHovering: true, isPressed: false, increasedContrast: true) > hover)
}

// MARK: - Fixtures

@MainActor
final class PolishHostedSurface<Content: View> {
  let window: NSWindow
  let hostingView: NSHostingView<Content>

  init(rootView: Content, size: NSSize = NSSize(width: 480, height: 200)) {
    _ = NSApplication.shared
    hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()
  }

  func views<View: NSView>(of type: View.Type) -> [View] {
    allViews(in: hostingView).compactMap { $0 as? View }
  }

  func close() {
    window.orderOut(nil)
  }

  func pump(_ interval: TimeInterval = 0.02) {
    RunLoop.main.run(until: Date().addingTimeInterval(interval))
    hostingView.layoutSubtreeIfNeeded()
  }

  private func allViews(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(allViews(in:))
  }
}

struct PolishFixture {
  let store: AppStore
  let directory: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
func makePolishFixture(
  apps: [AudioApp],
  configure: (inout UserPreferences) -> Void = { _ in }
) async throws -> PolishFixture {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-polish-\(UUID().uuidString)", isDirectory: true)
  let device = AudioDevice(
    id: "polish.output",
    name: "Polish Output",
    kind: .builtInOutput,
    isCurrent: true,
    isManagedRouteAvailable: true
  )
  let snapshot = AudioSessionSnapshot(
    apps: apps,
    currentDevice: device,
    recentDeviceIDs: [device.id],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.urlSchemeAutomationAcknowledged = true
  configure(&preferences)

  let preferencesStore = PreferencesStore(directory: directory)
  let sessionStore = SessionStore(directory: directory)
  try await preferencesStore.save(preferences)
  try await preferencesStore.flush()
  try await sessionStore.save(snapshot)
  try await sessionStore.flush()

  let store = AppStore(
    backend: PreviewAudioControlBackend(snapshot: snapshot),
    preferencesStore: preferencesStore,
    profileStore: ProfileStore(directory: directory),
    sessionStore: sessionStore,
    loginItemService: LoginItemService(),
    deviceVolumePresetsStore: DeviceVolumePresetsStore(directory: directory),
    initialStartupState: .running
  )
  await store.drainPersistenceTasks()
  return PolishFixture(store: store, directory: directory)
}

func polishApp(
  id: String = "com.example.polish",
  name: String = "Polish Player",
  state: RoutingState = .managed,
  volume: Float = 0.62,
  boost: Float = 1,
  muted: Bool = false,
  notes: String? = nil,
  noAudioCapability: Bool = false
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: id,
    displayName: name,
    category: .media,
    desiredVolume: volume,
    appliedVolume: state == .managed ? volume : nil,
    isMuted: muted,
    routingState: state,
    hasNoAudioCapability: noAudioCapability,
    compatibility: .supported,
    notes: notes,
    volumeBoost: boost
  )
}

// MARK: - Exclude All

@Test func excludingOneUnroutableAppIsImmediateButSeveralAsksFirst() {
  #expect(UnroutableAppsBanner.asksBeforeExcluding(count: 1) == false)
  #expect(UnroutableAppsBanner.asksBeforeExcluding(count: 2))
  #expect(UnroutableAppsBanner.asksBeforeExcluding(count: 12))
  #expect(UnroutableAppsBanner.confirmationTitle(count: 3) == "Exclude 3 apps from Waves?")
  #expect(UnroutableAppsBanner.confirmationButton(count: 3) == "Exclude 3 Apps")
}
