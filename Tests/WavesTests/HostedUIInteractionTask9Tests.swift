import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
import WavesAudioCore

@testable import Waves

@Suite(.serialized)
struct HostedUIInteractionTask9Tests {
  @MainActor
  @Test func hostedMixerTourEscapeEndsImmediately() throws {
    var endReason: GuidedMixerTourEndReason?
    let surface = try Task9HostedSurface(
      rootView: MixerTourOverlay(
        moment: .setLevel,
        appName: "Keyboard Player",
        isTargetAvailable: true,
        onBack: {},
        onNext: {},
        onOpenSettings: {},
        onEnd: { endReason = $0 }
      )
      .frame(width: 640, height: 600)
    )
    defer { surface.close() }

    #expect(surface.performCancelAction())
    #expect(endReason == .button)
  }

  @MainActor
  @Test func hostedMixerKeysExerciseMuteEqualizerOutputAndGlobalRecovery() async throws {
    let announcements = Task9AnnouncementRecorder()
    let managed = task9InteractionApp()
    let fixture = try await makeTask9InteractionFixture(
      app: managed,
      announcementPoster: AccessibilityAnnouncementPoster { announcement in
        announcements.record(announcement)
      }
    )
    defer { fixture.cleanup() }

    let managedSurface = try Task9HostedSurface(
      rootView: Text("Mixer keyboard target")
        .focusable()
        .modifier(
          MixerKeyboardCommandsModifier(
            selectedAppID: .constant(managed.id),
            apps: [managed]
          )
        )
        .environment(fixture.store)
        .frame(width: 500, height: 180)
    )
    defer { managedSurface.close() }

    try managedSurface.focusKeyboardTarget()
    managedSurface.sendKey("m", keyCode: UInt16(kVK_ANSI_M))
    await fixture.store.drainAppIntentTransactions()
    #expect(fixture.store.session.apps.first?.isMuted == true)

    managedSurface.sendKey("e", keyCode: UInt16(kVK_ANSI_E))
    #expect(fixture.store.equalizerFocusRequest?.appID == managed.logicalID)

    managedSurface.sendKey("o", keyCode: UInt16(kVK_ANSI_O))
    await fixture.store.drainAppIntentTransactions()
    #expect(fixture.store.session.apps.first?.targetDeviceUID == fixture.device.id)

    let exhausted = task9InteractionApp(
      state: .error,
      context: .geometryRecoveryExhausted
    )
    let recoveryAnnouncements = Task9AnnouncementRecorder()
    let recoveryFixture = try await makeTask9InteractionFixture(
      app: exhausted,
      announcementPoster: AccessibilityAnnouncementPoster { announcement in
        recoveryAnnouncements.record(announcement)
      }
    )
    defer { recoveryFixture.cleanup() }
    let recoverySurface = try Task9HostedSurface(
      rootView: Text("Recovery keyboard target")
        .focusable()
        .modifier(
          MixerKeyboardCommandsModifier(
            selectedAppID: .constant(exhausted.id),
            apps: [exhausted]
          )
        )
        .environment(recoveryFixture.store)
        .frame(width: 500, height: 180)
    )
    defer { recoverySurface.close() }

    try recoverySurface.focusKeyboardTarget()
    recoverySurface.sendKey("r", keyCode: UInt16(kVK_ANSI_R))
    while recoveryFixture.store.isRecovering { await Task.yield() }
    #expect(recoveryAnnouncements.recordedValues.contains { $0.contains("Routes recovered") })
  }

  @MainActor
  @Test func hostedSettingsSidebarArrowKeyChangesTheVisiblePaneSelection() async throws {
    let fixture = try await makeTask9InteractionFixture(
      app: task9InteractionApp(),
      announcementPoster: .live
    )
    defer { fixture.cleanup() }
    let workspace = SettingsWorkspace(selection: .general)
    let surface = try Task9HostedSurface(
      rootView: SettingsView(workspace: workspace)
        .environment(fixture.store)
        .environment(UpdaterService())
        .frame(width: 840, height: 680)
    )
    defer { surface.close() }
    let generalPane = try surface.renderedData()

    try surface.focusKeyboardTarget()
    surface.sendKey(
      String(UnicodeScalar(NSDownArrowFunctionKey)!),
      keyCode: UInt16(kVK_DownArrow)
    )
    #expect(workspace.selection == .mixer)
    #expect(try surface.renderedData() != generalPane)
  }

  @MainActor
  @Test(arguments: [false, true])
  func hostedFullAndCompactRecoveryButtonsInvokeTheGlobalAction(compact: Bool) async throws {
    let announcements = Task9AnnouncementRecorder()
    let exhausted = task9InteractionApp(
      id: compact ? "compact.recovery" : "full.recovery",
      state: .error,
      context: .geometryRecoveryExhausted
    )
    let fixture = try await makeTask9InteractionFixture(
      app: exhausted,
      announcementPoster: AccessibilityAnnouncementPoster { announcement in
        announcements.record(announcement)
      }
    )
    defer { fixture.cleanup() }
    let surface = try Task9HostedSurface(
      rootView: RouteRecoveryButton(app: exhausted, compact: compact)
        .environment(fixture.store)
        .frame(width: 320, height: 120)
    )
    defer { surface.close() }

    try surface.focusKeyboardTarget()
    surface.sendKey(" ", keyCode: UInt16(kVK_Space))
    while fixture.store.isRecovering { await Task.yield() }
    #expect(announcements.recordedValues.contains { $0.contains("Routes recovered") })
  }

  @MainActor
  @Test func recordingAnAppMuteShortcutKeepsItAndTheAppsOtherShortcuts() async throws {
    // Drives the handlers the Settings row itself uses. Recording once ran the
    // same callback as the row's remove button, which deleted the new binding
    // and the app's volume shortcuts with it.
    let fixture = try await makeTask9InteractionFixture(
      app: task9InteractionApp(),
      announcementPoster: AccessibilityAnnouncementPoster { _ in }
    )
    defer { fixture.cleanup() }
    let store = fixture.store
    let appID = fixture.app.logicalID
    let draft = ControlSettingsDraft()
    draft.addPendingApp(appID)
    let volumeUpChord = HotkeyChord(keyCode: UInt16(kVK_ANSI_U), carbonModifiers: UInt32(cmdKey | optionKey))
    guard case .success = store.assignHotkey(volumeUpChord, to: .volumeUpApp(appID)) else {
      Issue.record("expected the volume shortcut to be assigned")
      return
    }

    let muteRow = ControlSettingsView.shortcutRowHandlers(
      action: .muteApp(appID),
      binding: nil,
      clearRemovesAppGroup: appID,
      store: store,
      draft: draft
    )
    let muteChord = HotkeyChord(keyCode: UInt16(kVK_ANSI_M), carbonModifiers: UInt32(cmdKey | optionKey))
    #expect(muteRow.onRecord(muteChord) == nil)

    #expect(Set(store.preferences.hotkeys.bindings.map(\.action)) == [.muteApp(appID), .volumeUpApp(appID)])
    #expect(draft.pendingAppIDs.isEmpty)

    // The row's remove button still takes the whole group with it.
    let recorded = try #require(store.preferences.hotkeys.bindings.first { $0.action == .muteApp(appID) })
    ControlSettingsView.shortcutRowHandlers(
      action: .muteApp(appID),
      binding: recorded,
      clearRemovesAppGroup: appID,
      store: store,
      draft: draft
    ).onClear()
    #expect(store.preferences.hotkeys.bindings.isEmpty)
  }

  @MainActor
  @Test func hostedProfileDefaultActionShowsAndAnnouncesInvalidSaveFeedback() async throws {
    let announcements = Task9AnnouncementRecorder()
    let fixture = try await makeTask9InteractionFixture(
      app: task9InteractionApp(),
      announcementPoster: AccessibilityAnnouncementPoster { announcement in
        announcements.record(announcement)
      }
    )
    defer { fixture.cleanup() }

    let surface = try Task9HostedSurface(
      rootView: ProfileEditorSheet(
        context: ProfileEditorContext(profile: nil, preselectedAppIDs: [fixture.app.logicalID])
      )
      .environment(fixture.store)
      .frame(width: 460, height: 560)
    )
    defer { surface.close() }
    let beforeSave = try surface.renderedData()

    #expect(surface.performDefaultAction())
    #expect(announcements.recordedValues == ["Enter a profile name."])
    #expect(
      ProfileValidationScope.name.accessibilityErrorLabel(for: .blankName)
        == "Profile name error: Enter a profile name."
    )
    #expect(try surface.renderedData() != beforeSave)
  }

  @MainActor
  @Test func hostedSaveCurrentMixDefaultActionAnnouncesAMissingName() async throws {
    let announcements = Task9AnnouncementRecorder()
    let fixture = try await makeTask9InteractionFixture(
      app: task9InteractionApp(),
      announcementPoster: AccessibilityAnnouncementPoster { announcement in
        announcements.record(announcement)
      }
    )
    defer { fixture.cleanup() }

    let surface = try Task9HostedSurface(
      rootView: SaveCurrentMixSheet()
        .environment(fixture.store)
        .frame(width: 420, height: 440)
    )
    defer { surface.close() }
    let profilesBefore = fixture.store.profiles

    #expect(surface.performDefaultAction())
    #expect(announcements.recordedValues == ["Enter a profile name."])
    #expect(fixture.store.profiles == profilesBefore)
    #expect(surface.performCancelAction())
  }

  @MainActor
  @Test func mainWindowOpensSaveCurrentMixWhenTheMenuBarAsks() async throws {
    let fixture = try await makeTask9InteractionFixture(
      app: task9InteractionApp(),
      announcementPoster: AccessibilityAnnouncementPoster { _ in }
    )
    defer { fixture.cleanup() }

    // The menu bar's "Save Current Mix…" raises this request, then opens the
    // main window.
    let requested = try Task9HostedSurface(
      rootView: MainWindowView()
        .environment(fixture.store)
        .frame(width: 1100, height: 700)
    )
    defer { requested.close() }
    #expect(!requested.hasAttachedSheet)
    fixture.store.requestSaveCurrentMix()
    requested.waitUntil { requested.hasAttachedSheet }
    #expect(requested.hasAttachedSheet)
    #expect(!fixture.store.saveCurrentMixRequested)
  }

  @MainActor
  @Test func productionAccessibilityBoundaryCoversSemanticsActionsFocusAndRotors() {
    let managed = task9InteractionApp()
    let yielded = task9InteractionApp(
      state: .monitorOnly,
      context: .verifiedRouterOwnership
    )
    let exhausted = task9InteractionApp(
      state: .error,
      context: .geometryRecoveryExhausted
    )

    let volume = MixerRowAccessibility.semantics(
      for: .volume,
      app: managed,
      isExcluded: false,
      isRecovering: false
    )
    #expect(volume.label == "Volume for Keyboard Player")
    #expect(volume.value == "62%")
    #expect(volume.isEnabled)
    #expect(!volume.help.isEmpty)

    let yieldedEqualizer = MixerRowAccessibility.semantics(
      for: .equalizer,
      app: yielded,
      isExcluded: false,
      isRecovering: false
    )
    #expect(yieldedEqualizer.isEnabled == false)
    #expect(yieldedEqualizer.help.contains("Wave Link"))

    let recovery = MixerRowAccessibility.semantics(
      for: .recovery,
      app: exhausted,
      isExcluded: false,
      isRecovering: false
    )
    #expect(recovery.label == "Recover all managed Waves routes")
    #expect(recovery.help == "Rebuild all managed Waves routes")
    #expect(recovery.isEnabled)

    var actionInvocations: [String] = []
    let actions = MixerRowAccessibility.actions(
      app: managed,
      isExcluded: false,
      onPin: { actionInvocations.append("pin") },
      onExclusionChange: { actionInvocations.append($0 ? "exclude" : "manage") }
    )
    #expect(actions.map(\.name) == ["Pin", "Exclude from Waves"])
    actions.forEach { $0.perform() }
    #expect(actionInvocations == ["pin", "exclude"])

    #expect(
      MixerRowAccessibility.focusOrder(compact: false, offersRecovery: true)
        == [.recovery, .volume, .boost, .equalizer, .mute]
    )
    #expect(
      MixerRowAccessibility.focusOrder(compact: true, offersRecovery: true)
        == [.recovery, .volume, .boost, .equalizer, .mute]
    )

    let playing = task9InteractionApp(id: "playing", name: "Playing", state: .live)
    let attention = task9InteractionApp(id: "attention", name: "Attention", state: .error)
    let catalog = MixerRotorCatalog(
      apps: [managed, playing, attention],
      liveAppIDs: [playing.logicalID]
    )
    #expect(catalog.playing.map(\.displayName) == ["Playing"])
    #expect(catalog.needsAttention.map(\.displayName) == ["Attention"])

  }
}

@MainActor
private final class Task9HostedSurface<Content: View> {
  private let window: NSWindow
  private let hostingView: NSHostingView<Content>

  init(rootView: Content) throws {
    _ = NSApplication.shared
    hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
    window = NSWindow(
      contentRect: hostingView.frame,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    Task9HostedSurfaceRegistry.retain(self)
  }

  func close() {
    window.orderOut(nil)
  }

  var hasAttachedSheet: Bool { window.attachedSheet != nil }

  func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else {
        Issue.record("Timed out waiting for the hosted window")
        return
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  func focusKeyboardTarget() throws {
    let target = try #require(
      allViews(in: hostingView).first { view in
        view.acceptsFirstResponder && String(describing: type(of: view)).contains("KeyViewProxy")
      }
    )
    #expect(window.makeFirstResponder(target))
  }

  func sendKey(_ characters: String, keyCode: UInt16) {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      )
    else { return }
    window.sendEvent(event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }

  func performDefaultAction() -> Bool {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: UInt16(kVK_Return)
      )
    else { return false }
    let handled = window.performKeyEquivalent(with: event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    return handled
  }

  func performCancelAction() -> Bool {
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: String(UnicodeScalar(0x1B)!),
        charactersIgnoringModifiers: String(UnicodeScalar(0x1B)!),
        isARepeat: false,
        keyCode: UInt16(kVK_Escape)
      )
    else { return false }
    let handled = window.performKeyEquivalent(with: event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    return handled
  }

  func renderedData() throws -> Data {
    hostingView.layoutSubtreeIfNeeded()
    let representation = try #require(
      hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
    )
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
    return try #require(representation.representation(using: .png, properties: [:]))
  }

  private func allViews(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(allViews(in:))
  }
}

@MainActor
private enum Task9HostedSurfaceRegistry {
  private static var retainedSurfaces: [AnyObject] = []

  static func retain(_ surface: AnyObject) {
    retainedSurfaces.append(surface)
  }
}

private final class Task9AnnouncementRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func record(_ announcement: AttributedString) {
    let value = String(announcement.characters)
    lock.withLock {
      values.append(value)
    }
  }

  var recordedValues: [String] {
    lock.withLock { values }
  }
}

private struct Task9InteractionFixture {
  let store: AppStore
  let app: AudioApp
  let device: AudioDevice
  let directory: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private func makeTask9InteractionFixture(
  app: AudioApp,
  announcementPoster: AccessibilityAnnouncementPoster
) async throws -> Task9InteractionFixture {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-task9-hosted-\(UUID().uuidString)", isDirectory: true)
  let device = AudioDevice(
    id: "task9.output",
    name: "Task 9 Output",
    kind: .builtInOutput,
    isCurrent: true,
    isManagedRouteAvailable: true
  )
  let snapshot = AudioSessionSnapshot(
    apps: [app],
    currentDevice: device,
    recentDeviceIDs: [device.id],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: app.routeHealthContext != .geometryRecoveryExhausted,
      lastError: app.routeHealthContext == .geometryRecoveryExhausted ? "Geometry retry limit reached" : nil
    )
  )
  var preferences = UserPreferences()
  preferences.hasCompletedPrivacySetup = true
  preferences.hasCompletedGuidedSetup = true
  preferences.urlSchemeAutomationAcknowledged = true

  let preferencesStore = PreferencesStore(directory: directory)
  let profileStore = ProfileStore(directory: directory)
  let sessionStore = SessionStore(directory: directory)
  let presetsStore = DeviceVolumePresetsStore(directory: directory)
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
    deviceVolumePresetsStore: presetsStore,
    initialStartupState: .running,
    accessibilityAnnouncementPoster: announcementPoster
  )
  await store.drainPersistenceTasks()
  return Task9InteractionFixture(store: store, app: app, device: device, directory: directory)
}

private func task9InteractionApp(
  id: String = "keyboard.runtime",
  name: String = "Keyboard Player",
  state: RoutingState = .managed,
  context: RouteHealthContext? = nil
) -> AudioApp {
  AudioApp(
    id: id,
    logicalID: "com.example.\(id)",
    displayName: name,
    category: .media,
    desiredVolume: 0.62,
    appliedVolume: state == .managed ? 0.62 : nil,
    routingState: state,
    compatibility: .supported,
    routeHealthContext: context
  )
}
