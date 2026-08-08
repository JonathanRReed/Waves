import AppKit
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func controlCommandHandlerCoversEveryCommand() async throws {
  let store = await makeHandlerStore()
  let handler = ControlCommandHandler(store: store)
  let appID = try #require(store.controlApps().first?.id)

  var session = ControlCommandHandler.Session()

  let hello = await handler.handle(ControlRequest(id: 1, cmd: .hello), session: session)
  #expect(hello.response.ok)
  #expect(hello.response.protocolVersion == ControlProtocol.version)
  #expect(hello.session.didHandshake)
  session = hello.session

  let listApps = await handler.handle(ControlRequest(id: 2, cmd: .listApps), session: session)
  #expect(listApps.response.ok)
  #expect(listApps.response.apps?.contains(where: { $0.id == appID }) == true)

  let icon = await handler.handle(ControlRequest(id: 3, cmd: .getIcon, app: appID), session: session)
  #expect(icon.response.ok)
  #expect(icon.response.app == appID)

  let setVolume = await handler.handle(
    ControlRequest(id: 4, cmd: .setVolume, app: appID, volume: 0.25),
    session: session
  )
  #expect(setVolume.response.ok)
  #expect(setVolume.response.volume == 0.25)

  let adjustVolume = await handler.handle(
    ControlRequest(id: 5, cmd: .adjustVolume, app: appID, delta: -0.05),
    session: session
  )
  #expect(adjustVolume.response.ok)
  #expect(adjustVolume.response.volume == 0.2)

  let setMute = await handler.handle(
    ControlRequest(id: 6, cmd: .setMute, app: appID, muted: true),
    session: session
  )
  #expect(setMute.response.ok)
  #expect(setMute.response.muted == true)

  let toggleMute = await handler.handle(
    ControlRequest(id: 7, cmd: .toggleMute, app: appID),
    session: session
  )
  #expect(toggleMute.response.ok)
  #expect(toggleMute.response.muted == false)

  let subscribe = await handler.handle(ControlRequest(id: 8, cmd: .subscribe), session: session)
  #expect(subscribe.response.ok)
  #expect(subscribe.session.isSubscribed)

  let unsubscribe = await handler.handle(ControlRequest(id: 9, cmd: .unsubscribe), session: subscribe.session)
  #expect(unsubscribe.response.ok)
  #expect(!unsubscribe.session.isSubscribed)
}

@MainActor
@Test func controlCommandHandlerCoversEveryErrorPath() async throws {
  let runningStore = await makeHandlerStore()
  let runningHandler = ControlCommandHandler(store: runningStore)
  let appID = try #require(runningStore.controlApps().first?.id)

  let unsupported = await runningHandler.handle(
    ControlRequest(id: 1, cmd: .hello, protocolVersion: 2),
    session: .init()
  )
  #expect(unsupported.response.error == .unsupportedProtocol)

  let malformed = await runningHandler.handle(
    ControlRequest(id: 2, cmd: .listApps),
    session: .init()
  )
  #expect(malformed.response.error == .malformedRequest)

  let missingParameter = await runningHandler.handle(
    ControlRequest(id: 3, cmd: .setVolume),
    session: .init(didHandshake: true)
  )
  #expect(missingParameter.response.error == .missingParameter)

  let unknownApp = await runningHandler.handle(
    ControlRequest(id: 4, cmd: .setMute, app: "missing.app", muted: true),
    session: .init(didHandshake: true)
  )
  #expect(unknownApp.response.error == .unknownApp)

  runningStore.setExcluded(true, for: runningStore.session.apps[0])
  let appExcluded = await runningHandler.handle(
    ControlRequest(id: 5, cmd: .toggleMute, app: appID),
    session: .init(didHandshake: true)
  )
  #expect(appExcluded.response.error == .appExcluded)

  let notPermittedStore = await makeHandlerStore(enableExternalControl: false)
  let notPermitted = await ControlCommandHandler(store: notPermittedStore).handle(
    ControlRequest(id: 6, cmd: .toggleMute, app: appID),
    session: .init(didHandshake: true)
  )
  #expect(notPermitted.response.error == .notPermitted)

  let idleStore = await makeHandlerStore(initialStartupState: .idle)
  let audioNotRunning = await ControlCommandHandler(store: idleStore).handle(
    ControlRequest(id: 7, cmd: .setMute, app: appID, muted: true),
    session: .init(didHandshake: true)
  )
  #expect(audioNotRunning.response.error == .audioNotRunning)
}

@MainActor
@Test func controlCommandHandlerPreservesIDsAndCoversRateLimitIconAndMissingFields() async throws {
  let image = try #require(NSImage(systemSymbolName: "waveform", accessibilityDescription: nil))
  let iconData = try #require(image.tiffRepresentation)
  let store = await makeControlStoreFixture(iconTIFFData: iconData)
  store.preferences.enableExternalControl = true
  let session = ControlCommandHandler.Session(didHandshake: true)
  let handler = ControlCommandHandler(store: store)

  let icon = await handler.handle(
    ControlRequest(id: 40, cmd: .getIcon, app: "com.example.render"), session: session)
  #expect(icon.response.id == 40)
  #expect(icon.response.icon?.isEmpty == false)

  let absentStore = await makeControlStoreFixture()
  absentStore.preferences.enableExternalControl = true
  let absent = await ControlCommandHandler(store: absentStore).handle(
    ControlRequest(id: 41, cmd: .getIcon, app: "com.example.render"), session: session)
  #expect(absent.response.id == 41)
  #expect(absent.response.ok)
  #expect(absent.response.icon == nil)

  let missingDelta = await handler.handle(
    ControlRequest(id: 42, cmd: .adjustVolume, app: "com.example.render"), session: session)
  #expect(missingDelta.response == .failure(id: 42, .missingParameter))
  let missingMute = await handler.handle(
    ControlRequest(id: 43, cmd: .setMute, app: "com.example.render"), session: session)
  #expect(missingMute.response == .failure(id: 43, .missingParameter))

  let throttled = await ControlCommandHandler(
    store: store,
    testingPreflightFailure: { _ in .rateLimited }
  ).handle(ControlRequest(id: 44, cmd: .listApps), session: session)
  #expect(throttled.response == .failure(id: 44, .rateLimited))
  #expect(throttled.session.didHandshake)
}

@MainActor
private func makeHandlerStore(
  initialStartupState: AppStartupState = .running,
  enableExternalControl: Bool = true
) async -> AppStore {
  let snapshot = controlHandlerSnapshot()
  let preferences = HandlerPreferencesStore()
  preferences.value.enableExternalControl = enableExternalControl
  preferences.value.hasCompletedPrivacySetup = true
  preferences.value.hasCompletedGuidedSetup = true
  preferences.value.urlSchemeAutomationAcknowledged = true

  let store = AppStore(
    backend: PreviewAudioControlBackend(snapshot: snapshot),
    preferencesStore: preferences,
    profileStore: HandlerProfilesStore(),
    sessionStore: HandlerSessionStore(snapshot: snapshot),
    loginItemService: HandlerLoginItemService(),
    deviceVolumePresetsStore: HandlerDevicePresetsStore(),
    initialStartupState: initialStartupState
  )
  await store.drainPersistenceTasks()
  return store
}

private func controlHandlerSnapshot() -> AudioSessionSnapshot {
  let app = AudioApp(
    id: "runtime.control.app",
    logicalID: "com.example.control",
    displayName: "Control App",
    category: .media,
    desiredVolume: 0.5,
    appliedVolume: 0.5,
    routingState: .managed
  )
  return AudioSessionSnapshot(
    apps: [app],
    currentDevice: AudioDevice(
      id: "device.control",
      name: "Control Device",
      kind: .builtInOutput,
      isCurrent: true,
      isManagedRouteAvailable: true
    ),
    recentDeviceIDs: ["device.control"],
    supportMatrix: SupportMatrix(entries: [
      SupportMatrixEntry(
        appID: app.logicalID,
        displayName: app.displayName,
        category: app.category,
        state: app.compatibility
      )
    ]),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    ),
    updatedAt: .now
  )
}

private final class HandlerPreferencesStore: PreferencesPersisting, @unchecked Sendable {
  var value = UserPreferences()
  func load() -> UserPreferences { value }
  func save(_ preferences: UserPreferences) async throws { value = preferences }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class HandlerProfilesStore: ProfilesPersisting, @unchecked Sendable {
  var value = Profile.defaults
  func load(defaults: [Profile]) -> [Profile] { value }
  func save(_ profiles: [Profile]) async throws { value = profiles }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class HandlerSessionStore: SessionPersisting, @unchecked Sendable {
  var snapshot: AudioSessionSnapshot
  init(snapshot: AudioSessionSnapshot) {
    self.snapshot = snapshot
  }
  func load() -> AudioSessionSnapshot? { snapshot }
  func save(_ snapshot: AudioSessionSnapshot) async throws { self.snapshot = snapshot }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class HandlerDevicePresetsStore: DeviceVolumePresetsPersisting, @unchecked Sendable {
  var value = DeviceVolumePresets()
  func load() -> DeviceVolumePresets { value }
  func save(_ presets: DeviceVolumePresets) async throws { value = presets }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class HandlerLoginItemService: LoginItemServicing {
  var status = LoginItemStatus(
    isEnabled: false,
    isUserIntentEnabled: false,
    statusDescription: "Disabled"
  )
  func setEnabled(_ enabled: Bool) throws {
    status.isEnabled = enabled
    status.isUserIntentEnabled = enabled
  }
  func openSystemSettingsLoginItems() {}
}
