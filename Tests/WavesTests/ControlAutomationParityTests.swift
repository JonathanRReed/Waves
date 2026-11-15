import Foundation
import Testing
import WavesAudioCore
import WavesControlClient

@testable import Waves

// Waves 1.8.0 gave the control socket the URL scheme's profile and refresh
// commands and gave both surfaces boost. These tests pin down that the new
// commands are additive on protocol 1, follow the mixer's own boost rules, and
// only report ok for a change that actually landed.

private let managedID = "com.example.parity"
private let waveLinkID = "com.example.wavelink"
private let unsupportedID = "com.example.unsupported"

// MARK: - Protocol shape

@Test func newCommandsAreAppendedSoProtocolOneOnlyGrows() {
  let names = ControlCommand.allCases.map(\.rawValue)
  #expect(Set(names.prefix(9)) == WavesControlProtocol.baseCommands)
  #expect(Array(names.suffix(3)) == ["apply-profile", "refresh", "set-boost"])
  #expect(ControlProtocol.version == 1)
}

@Test func aWellFormedUnknownCommandIsReportedAndNeverClosesTheConnection() {
  let line = Data(#"{"id":12,"cmd":"teleport","app":"x"}"#.utf8)
  #expect(ControlCodec.decodeRequest(line) == .unknownCommand)
  #expect(ControlCodec.decodeRequest(Data("not json".utf8)) == .malformed)
  #expect(ControlCodec.decodeRequest(Data(#"{"id":1}"#.utf8)) == .malformed)

  var admission = ControlInboundAdmission(now: 0)
  for _ in 0..<(ControlInboundAdmission.maximumAbuseStrikes + 2) {
    let decision = admission.classify(line, now: 0)
    #expect(decision == .failure(id: 12, error: .unknownCommand, shouldClose: false))
  }
  // Malformed frames still count toward closing it.
  var malformed = ControlInboundAdmission(now: 0)
  var closed = false
  for _ in 0..<ControlInboundAdmission.maximumAbuseStrikes {
    if case .failure(_, .malformedRequest, true) = malformed.classify(Data("{".utf8), now: 0) {
      closed = true
    }
  }
  #expect(closed)
}

@Test func newRequestFieldsRoundTripThroughTheWire() throws {
  let requests = [
    ControlRequest(id: 1, cmd: .setBoost, app: managedID, boost: 2),
    ControlRequest(id: 2, cmd: .applyProfile, profile: "Focus"),
    ControlRequest(id: 3, cmd: .refresh),
  ]
  for request in requests {
    #expect(ControlCodec.decode(try JSONEncoder().encode(request)) == request)
  }
  let wire = try #require(
    ControlCodec.decode(Data(#"{"id":4,"cmd":"apply-profile","profile":"Deep Work"}"#.utf8)))
  #expect(wire.profile == "Deep Work")
}

// MARK: - hello

@MainActor
@Test func helloAdvertisesEveryCommandThisBuildAccepts() async {
  let store = await makeParityStore()
  let hello = await ControlCommandHandler(store: store).handle(
    ControlRequest(id: 1, cmd: .hello, protocolVersion: 1), session: .init())
  #expect(hello.response.commands == ControlCommand.allCases.map(\.rawValue))
  let encoded = String(decoding: ControlCodec.encode(hello.response) ?? Data(), as: UTF8.self)
  #expect(encoded.contains(#""commands":["hello","list-apps""#))
}

// MARK: - set-boost

@MainActor
@Test func setBoostAppliesThroughTheStoreAndReportsTheLandedValue() async throws {
  let store = await makeParityStore()
  let response = await handle(store, ControlRequest(id: 5, cmd: .setBoost, app: managedID, boost: 3))
  #expect(response == ControlResponse(id: 5, ok: true, app: managedID, boost: 3))
  #expect(store.session.apps.first { $0.logicalID == managedID }?.volumeBoost == 3)
}

@MainActor
@Test func setBoostRefusesEveryValueTheBoostMenuDoesNotOffer() async {
  let store = await makeParityStore()
  let missing = await handle(store, ControlRequest(id: 1, cmd: .setBoost, app: managedID))
  #expect(missing == .failure(id: 1, .missingParameter))
  for value: Float in [.nan, .infinity, -.infinity, 0, 0.5, 4.01, 5, 100, .greatestFiniteMagnitude] {
    let response = await handle(store, ControlRequest(id: 2, cmd: .setBoost, app: managedID, boost: value))
    #expect(response == .failure(id: 2, .invalidParameter), "boost \(value) must be refused, not clamped")
  }
  #expect(store.session.apps.first { $0.logicalID == managedID }?.volumeBoost == 1)
}

@MainActor
@Test func setBoostFollowsTheMixersExclusionAndRouteRules() async throws {
  let store = await makeParityStore()

  let waveLink = await handle(store, ControlRequest(id: 1, cmd: .setBoost, app: waveLinkID, boost: 4))
  #expect(waveLink == .failure(id: 1, .routeUnavailable))
  #expect(store.session.apps.first { $0.logicalID == waveLinkID }?.volumeBoost == 1)

  let unsupported = await handle(store, ControlRequest(id: 2, cmd: .setBoost, app: unsupportedID, boost: 2))
  #expect(unsupported == .failure(id: 2, .routeUnavailable))

  store.setExcluded(true, for: try #require(store.session.apps.first { $0.logicalID == managedID }))
  let excluded = await handle(store, ControlRequest(id: 3, cmd: .setBoost, app: managedID, boost: 2))
  #expect(excluded == .failure(id: 3, .appExcluded))
}

@MainActor
@Test func setBoostReportsNotAppliedWhenTheRouteRejectsIt() async {
  let backend = PreviewAudioControlBackend(snapshot: paritySnapshot())
  let store = await makeParityStore(backend: backend)
  await backend.stop()
  let response = await handle(store, ControlRequest(id: 9, cmd: .setBoost, app: managedID, boost: 2))
  #expect(response == .failure(id: 9, .notApplied))
}

// MARK: - apply-profile

@MainActor
@Test func applyProfileMatchesNamesLikeTheURLSchemeAndWaitsForTheResult() async throws {
  let store = await makeParityStore()
  let response = await handle(store, ControlRequest(id: 7, cmd: .applyProfile, profile: "fOcUs"))
  #expect(response.ok)
  #expect(
    response.profile == ControlProfileResult(name: "Focus", applied: 1, savedForLater: 1, skipped: 0, failed: 0))
  // The reply came after the levels landed, not before.
  let app = try #require(store.session.apps.first { $0.logicalID == managedID })
  #expect(app.desiredVolume == 0.3)
  #expect(app.volumeBoost == 2)
}

@MainActor
@Test func applyProfileRefusesBadNamesAndUnknownProfiles() async {
  let store = await makeParityStore()
  #expect(await handle(store, ControlRequest(id: 1, cmd: .applyProfile)) == .failure(id: 1, .missingParameter))
  for name in ["", "Focus\nInjected", "Focus\u{202E}", String(repeating: "a", count: Profile.maxNameLength + 1)] {
    let response = await handle(store, ControlRequest(id: 2, cmd: .applyProfile, profile: name))
    #expect(response == .failure(id: 2, .invalidParameter))
  }
  let unknown = await handle(store, ControlRequest(id: 3, cmd: .applyProfile, profile: "Nope"))
  #expect(unknown == .failure(id: 3, .unknownProfile))
}

@MainActor
@Test func applyProfileNeverReportsOkWhenAnAppCouldNotBeSet() async {
  let store = await makeParityStore()
  let response = await handle(store, ControlRequest(id: 8, cmd: .applyProfile, profile: "Broken"))
  #expect(!response.ok)
  #expect(response.error == .notApplied)
  #expect(
    response.profile == ControlProfileResult(name: "Broken", applied: 1, savedForLater: 0, skipped: 0, failed: 1))
}

@MainActor
@Test func newCommandsRespectTheRunningAndPermissionGates() async {
  let idle = await makeParityStore(startupState: .idle)
  for request in [
    ControlRequest(id: 1, cmd: .applyProfile, profile: "Focus"),
    ControlRequest(id: 1, cmd: .refresh),
    ControlRequest(id: 1, cmd: .setBoost, app: managedID, boost: 2),
  ] {
    #expect(await handle(idle, request) == .failure(id: 1, .audioNotRunning))
  }

  let disabled = await makeParityStore(enableExternalControl: false)
  #expect(await handle(disabled, ControlRequest(id: 2, cmd: .refresh)) == .failure(id: 2, .notPermitted))
}

// MARK: - refresh

@MainActor
@Test func refreshRepliesWithTheRescannedRosterOnceItHasFinished() async {
  let store = await makeParityStore()
  let response = await handle(store, ControlRequest(id: 6, cmd: .refresh))
  #expect(response.ok)
  #expect(response.apps?.map(\.id).contains(managedID) == true)
  #expect(!store.isRefreshing)
  #expect(store.refreshTask == nil)
}

@MainActor
@Test func aSecondRefreshJoinsTheOneAlreadyRunning() async throws {
  let store = await makeParityStore()
  let first = try #require(store.startRefresh(announce: false, reevaluateAutomation: false))
  let second = try #require(store.startRefresh(announce: false, reevaluateAutomation: false))
  #expect(await first.value)
  #expect(await second.value)
}

// MARK: - URL scheme

@MainActor
@Test func urlSchemeParsesToggleMuteAndSetBoost() {
  let parser = AutomationCommandParser()
  #expect(
    parser.parse(URL(string: "waves://toggle-mute?app=com.example.app")!)
      == .accepted(.toggleMute(appID: "com.example.app")))
  #expect(
    parser.parse(URL(string: "waves://set-boost?app=com.example.app&boost=2.5")!)
      == .accepted(.setBoost(appID: "com.example.app", boost: 2.5)))
  for bad in [
    "waves://toggle-mute", "waves://toggle-mute?app=", "waves://toggle-mute?app=a%0Ab",
    "waves://set-boost?app=a", "waves://set-boost?app=a&boost=0.5", "waves://set-boost?app=a&boost=5",
    "waves://set-boost?app=a&boost=nan", "waves://set-boost?app=a&boost=inf", "waves://set-boost?boost=2",
  ] {
    guard case .rejected(let rejection) = parser.parse(URL(string: bad)!) else {
      Issue.record("\(bad) should be rejected")
      continue
    }
    #expect(rejection.shouldPresent)
  }
}

@MainActor
@Test func urlBoostAndToggleMuteReachTheStoreAndRespectRouteRules() async throws {
  let store = await makeParityStore()
  store.preferences.enableURLScheme = true

  store.handleURLScheme(URL(string: "waves://set-boost?app=\(waveLinkID)&boost=4")!)
  await store.drainOwnedAndIntentWork()
  #expect(store.session.apps.first { $0.logicalID == waveLinkID }?.volumeBoost == 1)
  #expect(store.toasts.contains { $0.title == "URL command blocked" })

  store.handleURLScheme(URL(string: "waves://set-boost?app=\(managedID)&boost=2")!)
  await store.drainOwnedAndIntentWork()
  #expect(store.session.apps.first { $0.logicalID == managedID }?.volumeBoost == 2)

  let wasMuted = try #require(store.session.apps.first { $0.logicalID == managedID }).isMuted
  store.handleURLScheme(URL(string: "waves://toggle-mute?app=\(managedID)")!)
  await store.drainOwnedAndIntentWork()
  #expect(store.session.apps.first { $0.logicalID == managedID }?.isMuted == !wasMuted)
}

// MARK: - Client library

@Test func clientTreatsAHelloWithoutCommandsAsAnOlderWaves() {
  let old = WavesControlCapabilities(hello: ["ok": .bool(true), "protocol": .number(1)])
  #expect(old.supports("set-volume"))
  #expect(!old.supports("apply-profile"))
  #expect(old.unsupportedMessage(for: "apply-profile")?.contains("Update Waves") == true)
  #expect(old.unsupportedMessage(for: "toggle-mute") == nil)

  let new = WavesControlCapabilities(hello: [
    "ok": .bool(true), "commands": .array(ControlCommand.allCases.map { .string($0.rawValue) }),
  ])
  #expect(new.unsupportedMessage(for: "apply-profile") == nil)
  #expect(new.unsupportedMessage(for: "set-boost") == nil)
}

@Test func wavesctlParsesTheNewCommands() throws {
  #expect(try WavesCTLCommand.parse(["boost", "com.example.app", "2"]) == .boost(app: "com.example.app", value: 2))
  #expect(try WavesCTLCommand.parse(["profile", "Deep", "Work"]) == .profile(name: "Deep Work"))
  #expect(try WavesCTLCommand.parse(["refresh"]) == .refresh)
  #expect(try WavesCTLCommand.parse(["--help"]) == .help)
  #expect(try WavesCTLCommand.parse(["help"]) == .help)
  for bad in [["boost", "a", "0.5"], ["boost", "a", "5"], ["boost", "a", "nan"], ["boost", "a"], ["profile"], ["refresh", "x"]] {
    #expect(throws: WavesCTLValidationError.self) { try WavesCTLCommand.parse(bad) }
  }

  #expect(
    WavesCTLCommand.boost(app: "a", value: 2).requestObject(id: 3)
      == ["id": .number(3), "cmd": .string("set-boost"), "app": .string("a"), "boost": .number(2)])
  #expect(
    WavesCTLCommand.profile(name: "Focus").requestObject(id: 4)
      == ["id": .number(4), "cmd": .string("apply-profile"), "profile": .string("Focus")])
  #expect(WavesCTLCommand.refresh.requestObject(id: 5) == ["id": .number(5), "cmd": .string("refresh")])
  #expect(WavesCTLCommand.profile(name: "Focus").ioTimeoutSeconds > WavesControlProtocol.ioTimeoutSeconds)
  #expect(WavesCTLCommand.raw(["cmd": .string("anything")]).serverCommand == nil)
  #expect(WavesCTLCommand.boost(app: "a", value: 2).serverCommand == "set-boost")

  // What the help text promises is exactly what the parser accepts.
  for line in ["boost  <app-id> <1..4>", "profile <name>", "refresh", "help"] {
    #expect(WavesCTLUsage.text.contains(line))
  }
  #expect(WavesCTLUsage.text.contains("Contents/Helpers/wavesctl"))
}

// MARK: - Fixture

@MainActor
private func handle(_ store: AppStore, _ request: ControlRequest) async -> ControlResponse {
  await ControlCommandHandler(store: store)
    .handle(request, session: .init(didHandshake: true)).response
}

extension AppStore {
  @MainActor
  fileprivate func drainOwnedAndIntentWork() async {
    await drainAppIntentTransactions()
  }
}

@MainActor
private func makeParityStore(
  startupState: AppStartupState = .running,
  enableExternalControl: Bool = true,
  backend: PreviewAudioControlBackend? = nil
) async -> AppStore {
  let snapshot = paritySnapshot()
  let preferences = ParityPreferencesStore()
  preferences.value.enableExternalControl = enableExternalControl
  preferences.value.hasCompletedPrivacySetup = true
  preferences.value.hasCompletedGuidedSetup = true
  preferences.value.urlSchemeAutomationAcknowledged = true
  let profiles = ParityProfilesStore()
  profiles.value = [
    Profile(
      name: "Focus",
      entries: [
        ProfileEntry(appID: managedID, desiredVolume: 0.3, volumeBoost: 2),
        ProfileEntry(appID: "com.example.not-running", desiredVolume: 0.2),
        ProfileEntry(appID: waveLinkID),
      ]),
    Profile(
      name: "Broken",
      entries: [
        ProfileEntry(appID: managedID, desiredVolume: 0.4),
        ProfileEntry(appID: unsupportedID, desiredVolume: 0.4),
      ]),
  ]

  let store = AppStore(
    backend: backend ?? PreviewAudioControlBackend(snapshot: snapshot),
    preferencesStore: preferences,
    profileStore: profiles,
    sessionStore: ParitySessionStore(snapshot: snapshot),
    loginItemService: ParityLoginItemService(),
    deviceVolumePresetsStore: ParityDevicePresetsStore(),
    initialStartupState: startupState
  )
  await store.drainPersistenceTasks()
  return store
}

private func paritySnapshot() -> AudioSessionSnapshot {
  let apps = [
    AudioApp(
      id: "runtime.parity", logicalID: managedID, displayName: "Parity App", category: .media,
      desiredVolume: 0.5, appliedVolume: 0.5, routingState: .managed, compatibility: .supported),
    AudioApp(
      id: "runtime.wavelink", logicalID: waveLinkID, displayName: "Wave Link App", category: .media,
      desiredVolume: 0.5, appliedVolume: 0.5, routingState: .managed, compatibility: .supported,
      routeHealthContext: .waveLinkBridge),
    AudioApp(
      id: "runtime.unsupported", logicalID: unsupportedID, displayName: "Unsupported App",
      category: .media, desiredVolume: 0.5, routingState: .monitorOnly, compatibility: .unsupported),
  ]
  return AudioSessionSnapshot(
    apps: apps,
    currentDevice: AudioDevice(
      id: "device.parity", name: "Parity Device", kind: .builtInOutput, isCurrent: true,
      isManagedRouteAvailable: true),
    recentDeviceIDs: ["device.parity"],
    supportMatrix: SupportMatrix(
      entries: apps.map {
        SupportMatrixEntry(appID: $0.logicalID, displayName: $0.displayName, category: $0.category, state: $0.compatibility)
      }),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true, hasRequiredPermissions: true, isRouteRecoveryHealthy: true),
    updatedAt: .now
  )
}

private final class ParityPreferencesStore: PreferencesPersisting, @unchecked Sendable {
  var value = UserPreferences()
  func load() -> UserPreferences { value }
  func save(_ preferences: UserPreferences) async throws { value = preferences }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class ParityProfilesStore: ProfilesPersisting, @unchecked Sendable {
  var value: [Profile] = []
  func load(defaults: [Profile]) -> [Profile] { value }
  func save(_ profiles: [Profile]) async throws { value = profiles }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class ParitySessionStore: SessionPersisting, @unchecked Sendable {
  var snapshot: AudioSessionSnapshot
  init(snapshot: AudioSessionSnapshot) { self.snapshot = snapshot }
  func load() -> AudioSessionSnapshot? { snapshot }
  func save(_ snapshot: AudioSessionSnapshot) async throws { self.snapshot = snapshot }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

private final class ParityDevicePresetsStore: DeviceVolumePresetsPersisting, @unchecked Sendable {
  var value = DeviceVolumePresets()
  func load() -> DeviceVolumePresets { value }
  func save(_ presets: DeviceVolumePresets) async throws { value = presets }
  func flush() async throws {}
  func consumeDidRecoverFromCorruptFile() -> Bool { false }
}

@MainActor
private final class ParityLoginItemService: LoginItemServicing {
  var status = LoginItemStatus(isEnabled: false, isUserIntentEnabled: false, statusDescription: "Disabled")
  func setEnabled(_ enabled: Bool) throws {
    status.isEnabled = enabled
    status.isUserIntentEnabled = enabled
  }
  func openSystemSettingsLoginItems() {}
}
