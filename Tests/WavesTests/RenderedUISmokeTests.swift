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
    let welcome = OnboardingView()
      .environment(fixture.store)
      .wavesTheme(palette: palette, appearance: appearance)
      .frame(width: 760, height: 700)
    let permission = ZStack {
      WavesBackground()
      OnboardingPermissionView(
        isWaiting: false,
        startupError: nil,
        onContinue: {}
      )
    }
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 760, height: 700)
    let readiness = ZStack {
      WavesBackground()
      OnboardingReadinessView(
        issues: [
          RequiredReadinessIssue(
            id: .audioCapture,
            title: "Audio Capture access needs attention",
            detail: "Enable Waves under Privacy & Security, then return here.",
            severity: .blocking,
            repairAction: .openCaptureSettings
          ),
          RequiredReadinessIssue(
            id: .managedRoutes,
            title: "Managed routes need repair",
            detail: "Waves can open the mixer now, or rebuild managed routes before you continue.",
            severity: .warning,
            repairAction: .recoverRoutes
          ),
        ],
        isStabilizing: false,
        onRepair: { _ in }
      )
    }
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 760, height: 700)
    let ready = ZStack {
      WavesBackground()
      OnboardingReadyView(
        isCompleting: false,
        completionError: nil,
        onStartMixing: {},
        onTakeTour: {}
      )
    }
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 760, height: 700)
    let install = InstallLocationAdvisoryView(
      classification: .mountedDiskImage,
      openInFinder: {},
      continueForNow: {}
    )
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 760, height: 700)
    let education = ZStack(alignment: .bottomTrailing) {
      WavesBackground()
      VStack(alignment: .trailing, spacing: 18) {
        WhatsNewCard(onTakeTour: {}, onDismiss: {})
        MixerTourOverlay(
          moment: .setLevel,
          appName: "Lecture Player",
          isTargetAvailable: true,
          onBack: {},
          onNext: {},
          onOpenSettings: {},
          onEnd: { _ in }
        )
      }
      .padding(28)
    }
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 900, height: 760)
    let setupRepair = ZStack {
      WavesBackground()
      SetupRepairView()
    }
    .environment(fixture.store)
    .wavesTheme(palette: palette, appearance: appearance)
    .frame(width: 760, height: 700)

    let setupRepairImage = try hostedImage(
      setupRepair,
      size: NSSize(width: 760, height: 700),
      scale: 2,
      appearance: appearance
    )
    #expect(setupRepairImage.size == NSSize(width: 760, height: 700))

    try renderEvidence(
      welcome,
      filename: "onboarding-welcome-\(palette.rawValue)-\(appearance.rawValue).png",
      size: NSSize(width: 760, height: 700),
      appearance: appearance
    )
    try renderEvidence(
      permission,
      filename: "onboarding-permission-\(palette.rawValue)-\(appearance.rawValue).png",
      size: NSSize(width: 760, height: 700),
      appearance: appearance
    )
    try renderEvidence(
      readiness,
      filename: "onboarding-readiness-\(palette.rawValue)-\(appearance.rawValue).png",
      size: NSSize(width: 760, height: 700),
      appearance: appearance
    )
    try renderEvidence(
      ready,
      filename: "onboarding-ready-\(palette.rawValue)-\(appearance.rawValue).png",
      size: NSSize(width: 760, height: 700),
      appearance: appearance
    )
    try renderEvidence(
      install,
      filename: "onboarding-install-\(palette.rawValue)-\(appearance.rawValue).png",
      size: NSSize(width: 760, height: 700),
      appearance: appearance
    )
    try renderEvidence(
      education,
      filename: "onboarding-education-\(palette.rawValue)-\(appearance.rawValue).png",
      size: NSSize(width: 900, height: 760),
      appearance: appearance
    )

    if let outputPath = ProcessInfo.processInfo.environment["WAVES_QA_OUTPUT"] {
      let output = URL(fileURLWithPath: outputPath, isDirectory: true)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try pngData(from: setupRepairImage).write(
        to: output.appendingPathComponent(
          "setup-repair-\(palette.rawValue)-\(appearance.rawValue).png"),
        options: .atomic
      )
    }
  }
}

@Test @MainActor func primarySurfacesSettingsAndAccessibilityVariantsRender() async throws {
  let fixture = try await makeRenderedUIFixture()
  let updater = UpdaterService()

  for appearance in [WavesAppearance.light, .dark] {
    let main = MainWindowView()
      .environment(fixture.store)
      .wavesTheme(palette: .waves, appearance: appearance)
      .frame(width: 1100, height: 760)
    let menu = MenuBarMixerView()
      .environment(fixture.store)
      .wavesTheme(palette: .waves, appearance: appearance)
      .frame(width: WavesDesign.menuBarPanelWidth, height: 720)

    try renderEvidence(
      main,
      filename: "main-\(appearance.rawValue).png",
      size: NSSize(width: 1100, height: 760),
      appearance: appearance
    )
    try renderEvidence(
      menu,
      filename: "menu-\(appearance.rawValue).png",
      size: NSSize(width: WavesDesign.menuBarPanelWidth, height: 720),
      appearance: appearance
    )
  }

  let originalSession = fixture.store.session
  fixture.store.startGuidedMixerTour()
  let activeTour = MainWindowView()
    .environment(fixture.store)
    .wavesTheme(palette: .waves, appearance: .dark)
    .frame(width: 1100, height: 760)
  try renderEvidence(
    activeTour,
    filename: "main-tour-active-dark.png",
    size: NSSize(width: 1100, height: 760),
    appearance: .dark
  )

  fixture.store.session.apps = []
  let unavailableTour = MainWindowView()
    .environment(fixture.store)
    .wavesTheme(palette: .waves, appearance: .dark)
    .frame(width: 1100, height: 760)
  try renderEvidence(
    unavailableTour,
    filename: "main-tour-target-unavailable-dark.png",
    size: NSSize(width: 1100, height: 760),
    appearance: .dark
  )
  fixture.store.session = originalSession
  fixture.store.endGuidedMixerTour(reason: .button)

  for pane in SettingsPane.allCases {
    let settings = SettingsView(initialPane: pane)
      .environment(fixture.store)
      .environment(updater)
      .wavesTheme(palette: .waves, appearance: .dark)
      .frame(width: 840, height: 680)
    try renderEvidence(
      settings,
      filename: "settings-\(pane.rawValue).png",
      size: NSSize(width: 840, height: 680),
      appearance: .dark
    )
  }

  let accessibilityVariant = VStack(alignment: .leading, spacing: 12) {
    ProfileValidationFeedback(scope: .name, result: .duplicateName("Focus"))
    ProfileValidationFeedback(scope: .selection, result: .noEligibleApps)
    ReadinessChecklistRow(
      title: "Audio capture permission",
      detail: "macOS has not returned a decisive authorization state yet.",
      status: .attention,
      actionTitle: "Re-check Permission",
      action: {}
    )
  }
  .padding(24)
  .environment(
    \.wavesAccessibilityOverrides,
    WavesAccessibilityOverrides(
      reduceMotion: true,
      reduceTransparency: true,
      increasedContrast: true
    )
  )
  .wavesTheme(palette: .graphite, appearance: .light)
  .frame(width: 620, height: 300)
  try renderEvidence(
    accessibilityVariant,
    filename: "accessibility-contrast-transparency-motion.png",
    size: NSSize(width: 620, height: 300),
    appearance: .light
  )

  let emptySnapshot = AudioSessionSnapshot(
    apps: [],
    currentDevice: renderedUISnapshot().currentDevice,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
  let emptyFixture = try await makeRenderedUIFixture(snapshot: emptySnapshot)
  let empty = SoundWorkspaceView()
    .environment(emptyFixture.store)
    .wavesTheme(palette: .waves, appearance: .dark)
    .frame(width: 920, height: 760)
  try renderEvidence(
    empty,
    filename: "sound-empty-dark.png",
    size: NSSize(width: 920, height: 760),
    appearance: .dark
  )

  let routeMatrix = ZStack {
    WavesBackground()
    HStack(alignment: .top, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Main mixer route states")
          .font(.headline)
        ForEach(fixture.store.session.apps) { app in
          MixerRowView(app: app)
        }
      }
      .frame(width: 760)

      VStack(alignment: .leading, spacing: 4) {
        Text("Menu mixer route states")
          .font(.headline)
        ForEach(fixture.store.session.apps) { app in
          CompactMixerRow(app: app)
        }
      }
      .frame(width: 380)
    }
    .padding(24)
  }
  .environment(fixture.store)
  .wavesTheme(palette: .waves, appearance: .dark)
  .frame(width: 1212, height: 860)
  try renderEvidence(
    routeMatrix,
    filename: "route-health-main-menu-dark.png",
    size: NSSize(width: 1212, height: 860),
    appearance: .dark
  )
}

@Test func primarySurfaceAccessibilityAndKeyboardContractsMatchRenderedControls() {
  for pane in SettingsPane.allCases {
    #expect(pane.accessibilityLabel == "\(pane.title) settings, \(pane.subtitle)")
  }

  let app = renderedRouteApp(
    id: "keyboard.runtime",
    name: "Keyboard Player",
    state: .managed
  )
  #expect(MixerRowAccessibility.volumeLabel(for: app) == "Volume for Keyboard Player")
  #expect(MixerRowAccessibility.equalizerLabel(for: app) == "Open equalizer for Keyboard Player")
  #expect(MixerRowAccessibility.muteLabel(for: app) == "Mute Keyboard Player")
  #expect(MixerRowAccessibility.outputDeviceMenuLabel == "Output Device")

  #expect(MixerKeyboardCommand.toggleMute.updatedMute(for: app) == true)
  #expect(MixerKeyboardCommand.increaseVolume.updatedVolume(for: app) == 0.67)
  #expect(MixerKeyboardCommand.decreaseVolume.updatedVolume(for: app) == 0.57)
  #expect(MixerKeyboardCommand.cycleBoost.updatedBoost(for: app) == 2)
  #expect(MixerKeyboardCommand.togglePin.updatedPin(for: app) == true)

  #expect(SoundControlAccessibility.equalizerLabel(title: "All Managed Audio") == "All Managed Audio equalizer")
  #expect(SoundControlAccessibility.gainLabel(bandLabel: "Low") == "Low gain")

  let profileError = ProfileSaveResult.duplicateName("Focus")
  #expect(
    ProfileValidationScope.name.accessibilityErrorLabel(for: profileError)
      == "Profile name error: A profile named “Focus” already exists."
  )

  let exhausted = renderedRouteApp(
    id: "recovery.runtime",
    name: "Recovery",
    state: .error,
    context: .geometryRecoveryExhausted
  )
  let route = RouteHealthPresentation(app: exhausted)
  #expect(route.accessibilityLabel == "Route status: Recovery failed")
  #expect(route.accessibilityValue == "Geometry retry limit reached")
  #expect(route.help.contains("retry limit"))
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

@MainActor
private func renderEvidence<Content: View>(
  _ content: Content,
  filename: String,
  size: NSSize,
  appearance: WavesAppearance
) throws {
  let image = try hostedImage(content, size: size, scale: 2, appearance: appearance)
  #expect(image.size == size)
  guard let outputPath = ProcessInfo.processInfo.environment["WAVES_QA_OUTPUT"] else { return }
  let output = URL(fileURLWithPath: outputPath, isDirectory: true)
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  try pngData(from: image).write(
    to: output.appendingPathComponent(filename),
    options: .atomic
  )
}

private struct RenderedUIFixture {
  let store: AppStore
  let directory: URL
}

@MainActor
private func makeRenderedUIFixture(
  snapshot: AudioSessionSnapshot = renderedUISnapshot()
) async throws -> RenderedUIFixture {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-rendered-ui-\(UUID().uuidString)", isDirectory: true)
  let preferencesStore = PreferencesStore(directory: directory)
  let profileStore = ProfileStore(directory: directory)
  let sessionStore = SessionStore(directory: directory)
  let devicePresetsStore = DeviceVolumePresetsStore(directory: directory)

  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.requiredSetupVersion = OnboardingExperience.currentVersion
  preferences.whatsNewDismissedVersion = OnboardingExperience.currentVersion
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
    renderedRouteApp(
      id: "monitor.runtime",
      name: "Visible, not yet managed",
      state: .monitorOnly
    ),
    renderedRouteApp(
      id: "error.runtime",
      name: "Route setup error",
      state: .error,
      notes: "The route could not be attached."
    ),
    renderedRouteApp(
      id: "geometry.recovering.runtime",
      name: "Geometry recovery",
      state: .managed,
      context: .geometryRecoveryInProgress
    ),
    renderedRouteApp(
      id: "geometry.exhausted.runtime",
      name: "Geometry recovery exhausted",
      state: .error,
      context: .geometryRecoveryExhausted,
      notes: "Retry limit reached. Recover routes to try again."
    ),
    renderedRouteApp(
      id: "wave-link.claimed.runtime",
      name: "Claimed by Wave Link",
      state: .monitorOnly,
      context: .verifiedRouterOwnership
    ),
    renderedRouteApp(
      id: "wave-link.fallback.runtime",
      name: "Unreadable Wave Link tap",
      state: .monitorOnly,
      context: .unattributableRouterFallback
    ),
    renderedRouteApp(
      id: "wave-link.mix.runtime",
      name: "Wave Link mixed output",
      state: .monitorOnly,
      context: .routerMixedOutput
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

private func renderedRouteApp(
  id: String,
  name: String,
  state: RoutingState,
  context: RouteHealthContext? = nil,
  notes: String? = nil
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: id,
    displayName: name,
    category: .media,
    desiredVolume: 0.62,
    appliedVolume: 0.62,
    routingState: state,
    compatibility: .supported,
    notes: notes,
    routeHealthContext: context
  )
}

private func pngData(from image: NSImage) throws -> Data {
  let tiff = try #require(image.tiffRepresentation)
  let bitmap = try #require(NSBitmapImageRep(data: tiff))
  return try #require(bitmap.representation(using: .png, properties: [:]))
}
