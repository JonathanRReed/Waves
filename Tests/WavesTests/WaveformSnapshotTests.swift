import Dispatch
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@MainActor
@Test func waveformSnapshotMatchesSeparateReferenceCalculations() async throws {
  let fixture = try makeWaveformStore()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let store = fixture.store

  #expect(store.waveformSnapshot == referenceWaveformSnapshot(store))

  store.session.apps = [waveformApp(id: "nominal", routingState: .live)]
  let nominal = store.waveformSnapshot
  #expect(nominal.components.map(\.level) == [pow(0.18, 0.5)])
  #expect(abs(nominal.mixedAudioLevel - Float(tanh(1.6 * pow(0.12, 0.6)))) < 0.000_001)

  store.session.apps = [
    waveformApp(id: "power.3", routingState: .live),
    waveformApp(id: "power.4", routingState: .live),
  ]
  store.liveLevels = [
    "power.3": AudioLevels(peak: 0, rms: 0.3),
    "power.4": AudioLevels(peak: 0, rms: 0.4),
  ]
  #expect(abs(store.waveformSnapshot.mixedAudioLevel - Float(tanh(1.6 * pow(0.5, 0.6)))) < 0.000_001)
  store.session.apps[1].isMuted = true
  #expect(abs(store.waveformSnapshot.mixedAudioLevel - Float(tanh(1.6 * pow(0.3, 0.6)))) < 0.000_001)

  var apps = (0..<9).map { index in
    AudioApp(
      id: "runtime.\(index)",
      logicalID: "app.\(index)",
      displayName: "App \(index)",
      category: .media,
      peakLevel: index == 1 ? 0.24 : 0,
      rmsLevel: index == 1 ? 0.12 : 0,
      isMuted: index == 2,
      routingState: index == 1 ? .managed : .live,
      compatibility: .supported
    )
  }
  apps.append(
    AudioApp(
      id: "system.runtime", logicalID: "system.app", displayName: "System",
      category: .system, routingState: .live, compatibility: .supported
    ))
  apps.append(
    AudioApp(
      id: "linger.runtime", logicalID: "linger.app", displayName: "Lingering",
      category: .media, routingState: .recent, compatibility: .supported
    ))
  store.session.apps = apps
  store.liveLevels = [
    "app.0": AudioLevels(peak: 0.64, rms: 0.31),
    "app.1": AudioLevels(peak: 0.52, rms: 0.37),
    "app.3": AudioLevels(peak: 0.19, rms: 0.11),
    "app.4": AudioLevels(peak: 0.92, rms: 0.74),
    "app.5": AudioLevels(peak: 0.44, rms: 0.28),
    "app.6": AudioLevels(peak: 0.33, rms: 0.21),
    "app.7": AudioLevels(peak: 0.71, rms: 0.58),
    "app.8": AudioLevels(peak: 0.27, rms: 0.16),
  ]
  store.preferences.excludedAppIDs = ["app.4"]
  store.recentlyLiveIDs = ["linger.app"]
  store.preferences.appEqualizerSettings["app.1"] = EqualizerSettings(isEnabled: true)
  store.adaptiveGainsDBByAppID["app.1"] = -4.5

  let hiddenSystemSnapshot = store.waveformSnapshot
  #expect(hiddenSystemSnapshot == referenceWaveformSnapshot(store))
  #expect(hiddenSystemSnapshot.components.count == 6)
  let allEligibleContributions = [0.512, 0.416, 0.152, 0.74, 0.352, 0.264, 0.58, 0.216]
  let fullEnergy = allEligibleContributions.reduce(0) { $0 + $1 * $1 }
  #expect(
    abs(
      hiddenSystemSnapshot.mixedAudioLevel
        - Float(tanh(1.6 * pow(fullEnergy.squareRoot(), 0.6))))
      < 0.000_001)
  #expect(hiddenSystemSnapshot.components.contains { $0.id == "app.4" })
  #expect(!hiddenSystemSnapshot.components.contains { $0.id == "app.2" })
  #expect(!hiddenSystemSnapshot.components.contains { $0.id == "linger.app" })
  #expect(!hiddenSystemSnapshot.components.contains { $0.id == "system.app" })
  let managed = try #require(hiddenSystemSnapshot.components.first { $0.id == "app.1" })
  #expect(managed.isEqualized)
  #expect(managed.adaptiveGainDB == -4.5)

  store.preferences.showSystemProcesses = true
  #expect(store.waveformSnapshot == referenceWaveformSnapshot(store))

  store.preferences.managedAudioEqualizer.isEnabled = true
  let globalEQSnapshot = store.waveformSnapshot
  #expect(globalEQSnapshot == referenceWaveformSnapshot(store))
  #expect(globalEQSnapshot.components.filter { $0.id == "app.1" }.allSatisfy { $0.isEqualized })

  _ = await store.shutdown()
}

/// Opt-in timing for the actual AppStore input. The reference functions retain
/// the former two independent roster scans; `waveformSnapshot` is the shared path.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["WAVES_WAVEFORM_BENCHMARK_OUTPUT"] != nil))
func waveformSnapshotBenchmark() async throws {
  let fixture = try makeWaveformStore()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let store = fixture.store
  let iterations = 1000
  var measurements: [[String: Any]] = []

  for appCount in [40, 150] {
    store.session.apps = (0..<appCount).map { index in
      AudioApp(
        id: "runtime.\(index)", logicalID: "app.\(index)", displayName: "App \(index)",
        category: .media, routingState: index.isMultiple(of: 11) ? .managed : .live,
        compatibility: .supported
      )
    }
    store.liveLevels = Dictionary(
      uniqueKeysWithValues: store.session.apps.enumerated().map {
        index, app in
        let level = Float((index % 20) + 1) / 25
        return (app.logicalID, AudioLevels(peak: level, rms: level * 0.7))
      })

    let shared = store.waveformSnapshot
    #expect(referenceWaveComponents(store) == shared.components)
    #expect(referenceMixedAudioLevel(store) == shared.mixedAudioLevel)
    #expect(shared == referenceWaveformSnapshot(store))

    var checksum = 0.0
    let separateStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
      checksum += Double(referenceMixedAudioLevel(store))
      checksum += referenceWaveComponents(store).reduce(0) { $0 + $1.level }
    }
    let separate = DispatchTime.now().uptimeNanoseconds - separateStart

    let sharedStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations {
      let snapshot = store.waveformSnapshot
      checksum += Double(snapshot.mixedAudioLevel)
      checksum += snapshot.components.reduce(0) { $0 + $1.level }
    }
    let sharedDuration = DispatchTime.now().uptimeNanoseconds - sharedStart
    measurements.append([
      "appCount": appCount,
      "iterations": iterations,
      "originalTwoPassNanoseconds": separate,
      "sharedSnapshotNanoseconds": sharedDuration,
      "checksum": checksum,
    ])
  }

  _ = await store.shutdown()
  let output = try #require(ProcessInfo.processInfo.environment["WAVES_WAVEFORM_BENCHMARK_OUTPUT"])
  try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: output), options: .atomic)
}

@MainActor
private func referenceWaveformSnapshot(_ store: AppStore) -> WaveformSnapshot {
  WaveformSnapshot(
    components: referenceWaveComponents(store),
    mixedAudioLevel: referenceMixedAudioLevel(store)
  )
}

@MainActor
private func referenceMixedAudioLevel(_ store: AppStore) -> Float {
  var energy = 0.0
  for app in store.visibleApps where !app.isMuted && store.isLive(app) {
    let measured =
      store.liveLevels[app.logicalID]
      .map { Double(max($0.rms, $0.peak * 0.8)) } ?? 0
    let contribution = measured > 0.001 ? measured : 0.12
    energy += contribution * contribution
  }
  guard energy > 0 else { return 0 }
  return Float(tanh(1.6 * pow(energy.squareRoot(), 0.6)))
}

@MainActor
private func referenceWaveComponents(_ store: AppStore) -> [WaveComponent] {
  let managedEQActive = store.preferences.managedAudioEqualizer.isEnabled
  var components: [WaveComponent] = []
  for app in store.visibleApps where !app.isMuted && store.isLive(app) {
    let measured =
      store.liveLevels[app.logicalID]
      .map { Double(max($0.rms, $0.peak * 0.8)) } ?? 0
    let componentLevel = measured > 0.001 ? measured : 0.18
    let isManaged = app.routingState == .managed
    components.append(
      WaveComponent(
        id: app.logicalID,
        level: min(1, pow(componentLevel, 0.5)),
        isEqualized: isManaged
          && (managedEQActive || store.equalizerSettings(for: app).isEnabled),
        adaptiveGainDB: isManaged
          ? Double(store.adaptiveGainsDBByAppID[app.logicalID] ?? 0)
          : 0
      ))
  }
  if components.count > 6 {
    components = Array(components.sorted { $0.level > $1.level }.prefix(6))
  }
  return components
}

private func waveformApp(id: String, routingState: RoutingState) -> AudioApp {
  AudioApp(
    id: "\(id).runtime", logicalID: id, displayName: id, category: .media,
    routingState: routingState, compatibility: .supported
  )
}

@MainActor
private func makeWaveformStore() throws -> (store: AppStore, directory: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("waves-waveform-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let store = WavesComposition.makeStore(
    environment: ["CFFIXED_USER_HOME": directory.path],
    liveBackendFactory: { PreviewAudioControlBackend(snapshot: .empty) }
  )
  store.preferences.sortMode = .name
  store.preferences.showSystemProcesses = false
  return (store, directory)
}
