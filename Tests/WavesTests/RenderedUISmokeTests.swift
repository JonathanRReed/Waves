import AppKit
import SwiftUI
import Testing
import WavesAudioCore

@testable import Waves

@Test @MainActor func soundWorkspaceRendersAcrossPalettesAndAppearances() async throws {
  let fixture = try await makeRenderedUIFixture()
  let variants: [(WavesPalette, WavesAppearance)] = [
    (.waves, .light),
    (.waves, .dark),
    (.graphite, .light),
    (.graphite, .dark),
  ]

  for (palette, appearance) in variants {
    let view = SoundWorkspaceView()
      .environment(fixture.store)
      .wavesTheme(palette: palette, appearance: appearance)
      .frame(width: 920, height: 760)

    let image = try hostedImage(
      view,
      size: NSSize(width: 920, height: 760),
      scale: 2,
      appearance: appearance
    )
    #expect(image.size.width == 920)
    #expect(image.size.height == 760)

    if let outputPath = ProcessInfo.processInfo.environment["WAVES_QA_OUTPUT"] {
      let output = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let file = output.appendingPathComponent(
        "sound-\(palette.rawValue)-\(appearance.rawValue).png")
      try pngData(from: image).write(to: file, options: .atomic)
    }
  }
}

@Test @MainActor func onboardingAndSetupRepairRenderInLightAndDarkAppearances() async throws {
  let fixture = try await makeRenderedUIFixture()
  let variants: [(WavesPalette, WavesAppearance)] = [
    (.waves, .dark),
    (.graphite, .light),
  ]

  for (palette, appearance) in variants {
    let onboarding = OnboardingView()
      .environment(fixture.store)
      .wavesTheme(palette: palette, appearance: appearance)
      .frame(width: 760, height: 700)
    let setupRepair = ZStack {
      WavesBackground()
      SetupRepairView()
    }
    .environment(fixture.store)
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 760, height: 700)

    let onboardingImage = try hostedImage(
      onboarding,
      size: NSSize(width: 760, height: 700),
      scale: 2,
      appearance: appearance
    )
    let setupRepairImage = try hostedImage(
      setupRepair,
      size: NSSize(width: 760, height: 700),
      scale: 2,
      appearance: appearance
    )
    #expect(onboardingImage.size == NSSize(width: 760, height: 700))
    #expect(setupRepairImage.size == NSSize(width: 760, height: 700))

    if let outputPath = ProcessInfo.processInfo.environment["WAVES_QA_OUTPUT"] {
      let output = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try pngData(from: onboardingImage).write(
        to: output.appendingPathComponent(
          "onboarding-\(palette.rawValue)-\(appearance.rawValue).png"),
        options: .atomic
      )
      try pngData(from: setupRepairImage).write(
        to: output.appendingPathComponent(
          "setup-repair-\(palette.rawValue)-\(appearance.rawValue).png"),
        options: .atomic
      )
    }
  }
}

@MainActor
private func hostedImage<Content: View>(
  _ content: Content,
  size: NSSize,
  scale: CGFloat,
  appearance: WavesAppearance
) throws -> NSImage {
  _ = NSApplication.shared
  let hostingView = NSHostingView(rootView: content)
  hostingView.frame = NSRect(origin: .zero, size: size)
  hostingView.appearance = NSAppearance(
    named: appearance == .dark ? .darkAqua : .aqua
  )
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
  )
  window.appearance = hostingView.appearance
  window.contentView = hostingView
  window.layoutIfNeeded()
  hostingView.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  hostingView.layoutSubtreeIfNeeded()

  let pixelWidth = Int(size.width * scale)
  let pixelHeight = Int(size.height * scale)
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth,
      pixelsHigh: pixelHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  )
  bitmap.size = size
  hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

  let image = NSImage(size: size)
  image.addRepresentation(bitmap)
  return image
}

private struct RenderedUIFixture {
  let store: AppStore
  let directory: URL
}

@MainActor
private func makeRenderedUIFixture() async throws -> RenderedUIFixture {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-rendered-ui-\(UUID().uuidString)", isDirectory: true)
  let preferencesStore = PreferencesStore(directory: directory)
  let profileStore = ProfileStore(directory: directory)
  let sessionStore = SessionStore(directory: directory)
  let devicePresetsStore = DeviceVolumePresetsStore(directory: directory)

  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.urlSchemeAutomationAcknowledged = true
  preferences.adaptiveMixMode = .both
  preferences.adaptiveStrategy = .lectureFocus
  preferences.managedAudioEqualizer = GlobalEqualizerSettings(isEnabled: true)
  preferences.managedAudioEqualizer.applyPreset(.voiceFocus)
  preferences.adaptiveAppPolicies = [
    "edu.lecture": AdaptiveAppPolicy(contentType: .lectureOrVoice, priority: .foreground),
    "music.background": AdaptiveAppPolicy(contentType: .music, priority: .background),
    "meeting.sample": AdaptiveAppPolicy(contentType: .meeting, priority: .normal),
  ]
  try await preferencesStore.save(preferences)
  try await preferencesStore.flush()

  let snapshot = renderedUISnapshot()
  try await sessionStore.save(snapshot)
  try await sessionStore.flush()

  let store = AppStore(
    backend: PreviewAudioControlBackend(snapshot: snapshot),
    preferencesStore: preferencesStore,
    profileStore: profileStore,
    sessionStore: sessionStore,
    loginItemService: LoginItemService(),
    deviceVolumePresetsStore: devicePresetsStore,
    initialStartupState: .running
  )
  return RenderedUIFixture(store: store, directory: directory)
}

private func renderedUISnapshot() -> AudioSessionSnapshot {
  let apps = [
    AudioApp(
      id: "edu.lecture.runtime",
      logicalID: "edu.lecture",
      bundleID: "edu.lecture",
      displayName: "Lecture Player",
      category: .media,
      isActive: true,
      peakLevel: 0.72,
      rmsLevel: 0.35,
      desiredVolume: 0.82,
      appliedVolume: 0.82,
      routingState: .managed,
      compatibility: .supported
    ),
    AudioApp(
      id: "music.background.runtime",
      logicalID: "music.background",
      bundleID: "com.spotify.client",
      displayName: "Background Music",
      category: .media,
      peakLevel: 0.42,
      rmsLevel: 0.18,
      desiredVolume: 0.35,
      appliedVolume: 0.35,
      routingState: .managed,
      compatibility: .supported
    ),
    AudioApp(
      id: "meeting.sample.runtime",
      logicalID: "meeting.sample",
      bundleID: "us.zoom.xos",
      displayName: "Meeting",
      category: .conferencing,
      desiredVolume: 0.65,
      appliedVolume: 0.65,
      routingState: .live,
      compatibility: .supported
    ),
  ]
  let device = AudioDevice(id: "qa.output", name: "Studio Display", kind: .display)
  return AudioSessionSnapshot(
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
}

private func pngData(from image: NSImage) throws -> Data {
  let tiff = try #require(image.tiffRepresentation)
  let bitmap = try #require(NSBitmapImageRep(data: tiff))
  return try #require(bitmap.representation(using: .png, properties: [:]))
}
