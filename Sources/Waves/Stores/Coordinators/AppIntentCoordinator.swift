import Foundation
import WavesAudioCore

struct AppIntentCoordinatorLifecycleSnapshot: Equatable, Sendable {
  let appTransactions: Int
  let profileBatches: Int
  let volumeDebounces: Int
  let equalizerDebounces: Int
  let automaticMuteOwners: Int

  var trackedTaskCount: Int {
    appTransactions + profileBatches + volumeDebounces + equalizerDebounces
  }

  static let idle = AppIntentCoordinatorLifecycleSnapshot(
    appTransactions: 0,
    profileBatches: 0,
    volumeDebounces: 0,
    equalizerDebounces: 0,
    automaticMuteOwners: 0
  )
}

struct AppIntentCoordinatorSettlingTasks {
  let appTransactions: [Task<AppIntentApplyResult, Never>]
  let mutations: [Task<Void, Never>]
}

/// Main-actor owner for app transaction generations, projections, debounces,
/// profile batches, and session-only automatic-mute ownership.
@MainActor
final class AppIntentCoordinator {
  private static let generationStride: UInt64 = 1 << 32
  private static var generationCounter: UInt64 = 0

  var pendingVolumeTargets: [String: Float] = [:]
  var pendingEqualizerSettings: [String: EqualizerSettings] = [:]
  var pendingEqualizerDebounceTasks: [String: Task<Void, Never>] = [:]
  var pendingVolumeDebounceTasks: [String: Task<Void, Never>] = [:]
  var appTasks: [String: Task<AppIntentApplyResult, Never>] = [:]
  var currentGenerations: [String: UInt64] = [:]
  var optimisticProjections: [String: AppIntentProjection] = [:]
  var profileTasks: [UInt64: Task<Void, Never>] = [:]
  var currentProfileGeneration: UInt64?
  var confirmedApps: [String: AudioApp] = [:]
  var confirmedEqualizers: [String: EqualizerSettings] = [:]
  var durableMutationGenerations: [String: UInt64] = [:]
  var devicePresetMutationGenerations: [String: UInt64] = [:]
  private var automaticMuteOwners: Set<String> = []
  private var isShutDown = false

  var lifecycleSnapshot: AppIntentCoordinatorLifecycleSnapshot {
    AppIntentCoordinatorLifecycleSnapshot(
      appTransactions: appTasks.count,
      profileBatches: profileTasks.count,
      volumeDebounces: pendingVolumeDebounceTasks.count,
      equalizerDebounces: pendingEqualizerDebounceTasks.count,
      automaticMuteOwners: automaticMuteOwners.count
    )
  }

  func allocateGeneration() -> UInt64 {
    Self.generationCounter &+= Self.generationStride
    return Self.generationCounter
  }

  func setCurrentGeneration(_ generation: UInt64, for appID: String) {
    currentGenerations[appID] = generation
  }

  func isCurrent(_ generation: UInt64, for appID: String) -> Bool {
    currentGenerations[appID] == generation
  }

  func registerAppTask(_ task: Task<AppIntentApplyResult, Never>, for appID: String) {
    guard !isShutDown else {
      task.cancel()
      return
    }
    appTasks[appID]?.cancel()
    appTasks[appID] = task
  }

  func removeAppTask(for appID: String, generation: UInt64) {
    guard isCurrent(generation, for: appID) else { return }
    appTasks.removeValue(forKey: appID)
  }

  func claimAutomaticMute(for appID: String, generation: UInt64) -> Bool {
    guard isCurrent(generation, for: appID), !isShutDown else { return false }
    automaticMuteOwners.insert(appID)
    return true
  }

  func releaseAutomaticMute(for appID: String) {
    automaticMuteOwners.remove(appID)
  }

  func ownsAutomaticMute(for appID: String) -> Bool {
    automaticMuteOwners.contains(appID)
  }

  func retainAutomaticMuteOwners(in appIDs: Set<String>) {
    automaticMuteOwners = automaticMuteOwners.intersection(appIDs)
  }

  func clearAutomaticMuteOwners() {
    automaticMuteOwners.removeAll()
  }

  func removeState(for appID: String) {
    appTasks[appID]?.cancel()
    appTasks.removeValue(forKey: appID)
    currentGenerations.removeValue(forKey: appID)
    optimisticProjections.removeValue(forKey: appID)
    confirmedApps.removeValue(forKey: appID)
    confirmedEqualizers.removeValue(forKey: appID)
    durableMutationGenerations.removeValue(forKey: appID)
    pendingVolumeTargets.removeValue(forKey: appID)
    pendingEqualizerSettings.removeValue(forKey: appID)
    pendingVolumeDebounceTasks.removeValue(forKey: appID)?.cancel()
    pendingEqualizerDebounceTasks.removeValue(forKey: appID)?.cancel()
    automaticMuteOwners.remove(appID)
  }

  func drain() async {
    while true {
      let debounces =
        Array(pendingEqualizerDebounceTasks.values)
        + Array(pendingVolumeDebounceTasks.values)
      let transactions = appTasks.map { ($0.key, currentGenerations[$0.key], $0.value) }
      let profiles = profileTasks.map { ($0.key, $0.value) }
      guard !debounces.isEmpty || !transactions.isEmpty || !profiles.isEmpty else {
        return
      }
      for task in debounces { await task.value }
      for (_, _, task) in transactions { _ = await task.value }
      for (appID, generation, _) in transactions
      where currentGenerations[appID] == generation {
        appTasks.removeValue(forKey: appID)
      }
      for (_, task) in profiles { await task.value }
      for (generation, _) in profiles {
        profileTasks.removeValue(forKey: generation)
      }
    }
  }

  @discardableResult
  func shutdown() -> AppIntentCoordinatorSettlingTasks {
    isShutDown = true
    let appTransactions = Array(appTasks.values)
    let mutations =
      Array(pendingEqualizerDebounceTasks.values)
      + Array(pendingVolumeDebounceTasks.values)
      + Array(profileTasks.values)
    for task in appTransactions { task.cancel() }
    for task in mutations { task.cancel() }
    for appID in Array(currentGenerations.keys) {
      currentGenerations[appID] = allocateGeneration()
    }
    appTasks.removeAll()
    profileTasks.removeAll()
    pendingEqualizerDebounceTasks.removeAll()
    pendingVolumeDebounceTasks.removeAll()
    pendingEqualizerSettings.removeAll()
    pendingVolumeTargets.removeAll()
    optimisticProjections.removeAll()
    currentProfileGeneration = nil
    automaticMuteOwners.removeAll()
    return AppIntentCoordinatorSettlingTasks(
      appTransactions: appTransactions,
      mutations: mutations
    )
  }
}
