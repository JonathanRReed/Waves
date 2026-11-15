import AppKit
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
