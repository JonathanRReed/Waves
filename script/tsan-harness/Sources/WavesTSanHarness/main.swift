import Darwin
import Foundation
import WavesAudioCore

@testable import Waves

@main
struct WavesTSanHarness {
  static func main() async throws {
    try await runAppStoreAndPersistenceCoordination()
    try await runControlServerCoordination()
    try await runRouteActorCoordination()
    print("Thread Sanitizer harness passed 3 focused coordination scenarios.")
  }

  @MainActor
  private static func runAppStoreAndPersistenceCoordination() async throws {
    let directory = try makeTemporaryDirectory(prefix: "waves-tsan-state")
    defer { try? FileManager.default.removeItem(at: directory) }

    let preferencesStore = PreferencesStore(directory: directory)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<48 {
        group.addTask {
          var preferences = UserPreferences()
          preferences.showRecentApps = index.isMultiple(of: 2)
          preferences.enableExternalControl = true
          try await preferencesStore.save(preferences)
        }
      }
      try await group.waitForAll()
    }

    var finalPreferences = UserPreferences()
    finalPreferences.hasCompletedPrivacySetup = true
    finalPreferences.hasCompletedGuidedSetup = true
    finalPreferences.urlSchemeAutomationAcknowledged = true
    finalPreferences.enableExternalControl = true
    finalPreferences.showRecentApps = false
    try await preferencesStore.save(finalPreferences)
    try await preferencesStore.flush()
    try require(!preferencesStore.load().showRecentApps, "the final persistence sentinel was not durable")

    let fixture = try await makeStoreFixture(
      directory: directory,
      preferencesStore: preferencesStore
    )
    let app = try unwrap(fixture.store.session.apps.first, "the AppStore fixture has no app")

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask { @MainActor in
          let volume = Float(index + 1) / 50
          fixture.store.setDesiredVolume(volume, for: app)
          fixture.store.commitDesiredVolume(for: app)
        }
      }
    }
    fixture.store.setDesiredVolume(0.73, for: app)
    fixture.store.commitDesiredVolume(for: app)
    await fixture.store.drainAppIntentTransactions()
    await fixture.store.drainPersistenceTasks()
    try await fixture.store.savePreferencesDurably()

    try require(
      fixture.store.session.apps.first?.desiredVolume == 0.73,
      "AppStore lost the final coordinated volume intent"
    )
    try require(
      fixture.store.trackedAppIntentTaskCount == 0,
      "AppStore retained an intent task after draining"
    )
    try require(
      fixture.store.trackedPersistenceTaskCount == 0,
      "AppStore retained a persistence task after draining"
    )

    let shutdown = await fixture.store.shutdown()
    try require(shutdown.completion == .clean, "AppStore shutdown was degraded")
    try require(fixture.store.lifecycleSnapshot.isIdle, "AppStore lifecycle did not become idle")
  }

  @MainActor
  private static func runControlServerCoordination() async throws {
    let directory = try makeTemporaryDirectory(prefix: "waves-tsan-control")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try await makeStoreFixture(directory: directory)
    let socketURL = directory.appendingPathComponent("control.sock")
    let server = ControlServer(
      url: socketURL,
      handler: ControlCommandHandler(store: fixture.store),
      timeouts: ControlConnectionTimeouts(handshake: .seconds(5), idle: .seconds(5))
    )
    try server.start()

    let client = try TSanControlSocketClient(path: socketURL.path)
    try client.write(#"{"id":1,"cmd":"hello","protocol":1}"# + "\n")
    let handshake = try await client.readLine()
    try require(
      handshake.contains(#""ok":true"#),
      "the control handshake failed"
    )

    for index in 0..<24 {
      let volume = Float(index + 1) / 25
      try client.write(
        #"{"id":\#(index + 2),"cmd":"set-volume","app":"com.example.tsan","volume":\#(volume)}"#
          + "\n"
      )
    }
    for index in 0..<24 {
      let response = try await client.readLine()
      try require(response.contains("\"id\":\(index + 2)"), "the control reply order changed")
      try require(response.contains(#""ok":true"#), "a control mutation failed")
    }

    await fixture.store.drainAppIntentTransactions()
    await fixture.store.drainPersistenceTasks()
    try require(
      fixture.store.session.apps.first?.desiredVolume == 0.96,
      "the control queue lost its final mutation"
    )

    client.close()
    server.stop()
    _ = await fixture.store.shutdown()
    try require(
      !FileManager.default.fileExists(atPath: socketURL.path),
      "the control socket survived shutdown"
    )
  }

  private static func runRouteActorCoordination() async throws {
    let snapshot = tsanSnapshot()
    let backend = WorkspaceAudioControlBackend(
      testingSnapshot: snapshot,
      captureAuthorization: .authorized,
      intentRouteApplyOverride: { _, _ in
        try await Task.sleep(for: .microseconds(250))
      }
    )

    try await withThrowingTaskGroup(of: AppIntentApplyResult.self) { group in
      for generation in 1...80 {
        group.addTask {
          await backend.applyAppIntent(
            tsanIntent(
              volume: Float(generation % 20) / 20,
              generation: UInt64(generation)
            )
          )
        }
      }
      for try await result in group {
        try require(
          [.applied, .noChange, .superseded].contains(result.outcome),
          "an overlapping route intent failed"
        )
      }
    }

    let finalResult = await backend.applyAppIntent(
      tsanIntent(volume: 0.61, generation: 1_000)
    )
    try require(finalResult.outcome == .applied, "the final route intent was not applied")
    let finalSnapshot = await backend.currentSnapshot()
    try require(
      finalSnapshot.apps.first?.desiredVolume == 0.61,
      "the route actor did not retain the highest generation"
    )

    let shutdown = await backend.shutdownWithResult()
    try require(shutdown.completion == .clean, "the route backend shutdown was degraded")
    let lifecycle = await backend.lifecycleDebugSnapshot()
    try require(lifecycle.liveControllers == 0, "the route backend retained a controller")
    try require(
      lifecycle.pendingGeometryRecoveries == 0,
      "the route backend retained geometry recovery work"
    )
  }
}

private enum TSanHarnessFailure: Error, CustomStringConvertible {
  case failed(String)

  var description: String {
    switch self {
    case .failed(let detail): detail
    }
  }
}

private func require(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
  guard condition() else { throw TSanHarnessFailure.failed(detail) }
}

private func unwrap<Value>(_ value: Value?, _ detail: String) throws -> Value {
  guard let value else { throw TSanHarnessFailure.failed(detail) }
  return value
}

private struct TSanStoreFixture {
  let store: AppStore
}

@MainActor
private func makeStoreFixture(
  directory: URL,
  preferencesStore suppliedPreferencesStore: PreferencesStore? = nil
) async throws -> TSanStoreFixture {
  let snapshot = tsanSnapshot()
  let preferencesStore = suppliedPreferencesStore ?? PreferencesStore(directory: directory)
  if suppliedPreferencesStore == nil {
    var preferences = UserPreferences()
    preferences.hasCompletedPrivacySetup = true
    preferences.hasCompletedGuidedSetup = true
    preferences.urlSchemeAutomationAcknowledged = true
    preferences.enableExternalControl = true
    try await preferencesStore.save(preferences)
    try await preferencesStore.flush()
  }

  let sessionStore = SessionStore(directory: directory)
  try await sessionStore.save(snapshot)
  try await sessionStore.flush()
  let backend = WorkspaceAudioControlBackend(
    testingSnapshot: snapshot,
    captureAuthorization: .authorized,
    intentRouteApplyOverride: { _, _ in
      try await Task.sleep(for: .microseconds(100))
    }
  )
  let store = AppStore(
    backend: backend,
    preferencesStore: preferencesStore,
    profileStore: ProfileStore(directory: directory),
    sessionStore: sessionStore,
    loginItemService: TSanLoginItemService(),
    deviceVolumePresetsStore: DeviceVolumePresetsStore(directory: directory),
    initialStartupState: .running
  )
  await store.drainPersistenceTasks()
  return TSanStoreFixture(store: store)
}

private func tsanSnapshot() -> AudioSessionSnapshot {
  let app = AudioApp(
    id: "runtime.tsan",
    logicalID: "com.example.tsan",
    pid: 42,
    bundleID: "com.example.tsan",
    displayName: "TSan App",
    category: .media,
    isActive: true,
    desiredVolume: 0.5,
    appliedVolume: 0.5,
    routingState: .managed,
    compatibility: .supported
  )
  return AudioSessionSnapshot(
    apps: [app],
    currentDevice: nil,
    recentDeviceIDs: [],
    supportMatrix: SupportMatrix(entries: []),
    backendStatus: BackendStatus(
      isAudioComponentInstalled: true,
      hasRequiredPermissions: true,
      isRouteRecoveryHealthy: true
    )
  )
}

private func tsanIntent(volume: Float, generation: UInt64) -> AppRouteIntent {
  AppRouteIntent(
    appID: "com.example.tsan",
    desiredVolume: volume,
    isMuted: false,
    volumeBoost: 1,
    equalizerSettings: EqualizerSettings(),
    targetDeviceUID: nil,
    generation: generation,
    reason: .automation
  )
}

@MainActor
private final class TSanLoginItemService: LoginItemServicing {
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

private final class TSanControlSocketClient {
  private let fd: Int32
  private var pending = Data()
  private var isClosed = false

  init(path: String) throws {
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
    var noSigPipe: Int32 = 1
    guard
      setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { source in
      strncpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path) - 1)
    }
    let result = withUnsafeBytes(of: &address) { raw in
      connect(fd, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(raw.count))
    }
    guard result == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    _ = Darwin.close(fd)
  }

  func write(_ string: String) throws {
    let data = Data(string.utf8)
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }

  func readLine(timeout: Duration = .seconds(10)) async throws -> String {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let newline = pending.firstIndex(of: 0x0A) {
        let line = pending[..<newline]
        pending = Data(pending[pending.index(after: newline)...])
        return String(decoding: line, as: UTF8.self)
      }
      var bytes = [UInt8](repeating: 0, count: 4_096)
      let count = read(fd, &bytes, bytes.count)
      if count > 0 {
        pending.append(contentsOf: bytes[0..<count])
      } else if count == 0 {
        throw POSIXError(.ECONNRESET)
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        try await Task.sleep(for: .milliseconds(5))
      } else if errno != EINTR {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    throw POSIXError(.ETIMEDOUT)
  }
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
