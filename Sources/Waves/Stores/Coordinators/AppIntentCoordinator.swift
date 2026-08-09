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

struct AppIntentTransactionStart: Sendable {
  let token: UUID
  let intent: AppRouteIntent
  let projection: AppIntentProjection?
  let projectedMuteSource: MuteSource?
}

enum AppIntentCompletionDisposition: Equatable, Sendable {
  case stale
  case backendGenerationMismatch
  case current
}

struct AppIntentRuntimeReconciliation: Sendable {
  let backendStatus: BackendStatus
  let resultingApp: AudioApp?
  let removedAppID: String?
  let shouldPresentAsExcluded: Bool
}

/// Main-actor owner for complete intent construction, transaction generations,
/// projections, debounces, profile batches, and session-only automatic mutes.
/// AppStore supplies value snapshots and applies returned typed mutations.
@MainActor
final class AppIntentCoordinator {
  private struct AppTaskRecord {
    let appID: String
    let generation: UInt64
    let task: Task<AppIntentApplyResult, Never>
  }

  private struct MutationTaskRecord {
    let appID: String
    let task: Task<Void, Never>
  }

  private static let generationStride: UInt64 = 1 << 32
  private static var generationCounter: UInt64 = 0

  private var pendingVolumeTargets: [String: Float] = [:]
  private var pendingEqualizerSettings: [String: EqualizerSettings] = [:]
  private var volumeDebounceTasks: [UUID: MutationTaskRecord] = [:]
  private var currentVolumeDebounceTokens: [String: UUID] = [:]
  private var equalizerDebounceTasks: [UUID: MutationTaskRecord] = [:]
  private var currentEqualizerDebounceTokens: [String: UUID] = [:]
  private var appTasks: [UUID: AppTaskRecord] = [:]
  private var currentAppTaskTokens: [String: UUID] = [:]
  private var currentGenerations: [String: UInt64] = [:]
  private var optimisticProjections: [String: AppIntentProjection] = [:]
  private var profileTasks: [UInt64: Task<Void, Never>] = [:]
  private var currentProfileGeneration: UInt64?
  private var confirmedApps: [String: AudioApp] = [:]
  private var confirmedEqualizers: [String: EqualizerSettings] = [:]
  private var durableMutationGenerations: [String: UInt64] = [:]
  private var devicePresetMutationGenerations: [String: UInt64] = [:]
  private var automaticMuteOwners: Set<String> = []
  private var isShutDown = false

  var lifecycleSnapshot: AppIntentCoordinatorLifecycleSnapshot {
    AppIntentCoordinatorLifecycleSnapshot(
      appTransactions: appTasks.count,
      profileBatches: profileTasks.count,
      volumeDebounces: volumeDebounceTasks.count,
      equalizerDebounces: equalizerDebounceTasks.count,
      automaticMuteOwners: automaticMuteOwners.count
    )
  }

  func seedConfirmedState(
    apps: [AudioApp],
    equalizers: [String: EqualizerSettings]
  ) {
    confirmedApps = Dictionary(
      apps.map { ($0.logicalID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    confirmedEqualizers = equalizers
  }

  func replaceConfirmedApps(_ apps: [AudioApp]) {
    confirmedApps = Dictionary(
      apps.map { ($0.logicalID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  func confirmedEqualizer(for appID: String) -> EqualizerSettings? {
    confirmedEqualizers[appID]
  }

  func recordConfirmedEqualizer(_ settings: EqualizerSettings, for appID: String) {
    confirmedEqualizers[appID] = settings
  }

  func removeConfirmedApp(for appID: String) {
    confirmedApps.removeValue(forKey: appID)
  }

  func recordConfirmedApp(_ app: AudioApp) {
    confirmedApps[app.logicalID] = app
  }

  func allocateGeneration() -> UInt64 {
    Self.generationCounter &+= Self.generationStride
    return Self.generationCounter
  }

  func beginTransaction(
    appID: String,
    sessionApp: AudioApp?,
    persistedEqualizer: EqualizerSettings?,
    legacyEqualizer: EqualizerSettings?,
    isExcluded: Bool,
    overrides: AppIntentOverrides,
    reason: AppRouteIntentReason,
    optimistic: Bool
  ) -> AppIntentTransactionStart {
    let generation = allocateGeneration()
    let intent = completeIntent(
      appID: appID,
      sessionApp: sessionApp,
      persistedEqualizer: persistedEqualizer,
      legacyEqualizer: legacyEqualizer,
      isExcluded: isExcluded,
      overrides: overrides,
      generation: generation,
      reason: reason
    )
    let projectedMuteSource =
      overrides.muteSource
      ?? (overrides.isMuted == nil ? sessionApp?.muteSource : nil)
    let projection =
      optimistic
      ? AppIntentProjection(
        generation: generation,
        intent: intent,
        muteSource: projectedMuteSource
      )
      : nil

    cancelCurrentAppTask(for: appID)
    currentGenerations[appID] = generation
    optimisticProjections[appID] = projection
    let token = UUID()
    currentAppTaskTokens[appID] = token
    return AppIntentTransactionStart(
      token: token,
      intent: intent,
      projection: projection,
      projectedMuteSource: projectedMuteSource
    )
  }

  func completeIntent(
    appID: String,
    sessionApp: AudioApp?,
    persistedEqualizer: EqualizerSettings?,
    legacyEqualizer: EqualizerSettings?,
    isExcluded: Bool,
    overrides: AppIntentOverrides,
    generation: UInt64,
    reason: AppRouteIntentReason
  ) -> AppRouteIntent {
    let confirmed = confirmedApps[appID] ?? sessionApp
    var desiredVolume = confirmed?.desiredVolume ?? 1
    var isMuted = confirmed?.isMuted ?? false
    var volumeBoost = confirmed?.volumeBoost ?? 1
    var equalizer =
      confirmedEqualizers[appID]
      ?? persistedEqualizer
      ?? legacyEqualizer
      ?? EqualizerSettings()
    var targetDeviceUID = confirmed?.targetDeviceUID

    if let projection = currentProjection(for: appID), !projection.intent.isExcluded {
      desiredVolume = projection.intent.desiredVolume
      isMuted = projection.intent.isMuted
      volumeBoost = projection.intent.volumeBoost
      equalizer = projection.intent.equalizerSettings
      targetDeviceUID = projection.intent.targetDeviceUID
    }
    if let value = overrides.desiredVolume { desiredVolume = value }
    if let value = overrides.isMuted { isMuted = value }
    if let value = overrides.volumeBoost { volumeBoost = value }
    if let value = overrides.equalizerSettings { equalizer = value }
    if overrides.replacesTargetDevice { targetDeviceUID = overrides.targetDeviceUID }

    return AppRouteIntent(
      appID: appID,
      desiredVolume: desiredVolume,
      isMuted: isMuted,
      volumeBoost: volumeBoost,
      equalizerSettings: equalizer,
      targetDeviceUID: targetDeviceUID,
      generation: generation,
      reason: reason,
      isExcluded: overrides.isExcluded ?? isExcluded
    )
  }

  func registerAppTask(
    _ task: Task<AppIntentApplyResult, Never>,
    for start: AppIntentTransactionStart
  ) {
    guard !isShutDown else {
      task.cancel()
      return
    }
    appTasks[start.token] = AppTaskRecord(
      appID: start.intent.appID,
      generation: start.intent.generation,
      task: task
    )
  }

  /// Compatibility seam for direct coordinator tests. Production AppStore uses
  /// the typed transaction registration above.
  func registerAppTask(_ task: Task<AppIntentApplyResult, Never>, for appID: String) {
    guard !isShutDown else {
      task.cancel()
      return
    }
    cancelCurrentAppTask(for: appID)
    let token = UUID()
    currentAppTaskTokens[appID] = token
    appTasks[token] = AppTaskRecord(
      appID: appID,
      generation: currentGenerations[appID] ?? 0,
      task: task
    )
  }

  func settleAppTask(token: UUID) {
    guard let record = appTasks.removeValue(forKey: token) else { return }
    if currentAppTaskTokens[record.appID] == token {
      currentAppTaskTokens.removeValue(forKey: record.appID)
    }
  }

  func completionDisposition(
    for start: AppIntentTransactionStart,
    backendGeneration: UInt64
  ) -> AppIntentCompletionDisposition {
    guard isCurrent(start.intent.generation, for: start.intent.appID) else {
      return .stale
    }
    guard backendGeneration == start.intent.generation else {
      removeProjection(for: start.intent.appID, generation: start.intent.generation)
      return .backendGenerationMismatch
    }
    removeProjection(for: start.intent.appID, generation: start.intent.generation)
    return .current
  }

  func reconcileRuntime(
    _ result: AppIntentApplyResult,
    intent: AppRouteIntent,
    projectedMuteSource: MuteSource?,
    cachedApp: AudioApp?,
    pinnedAppIDs: Set<String>,
    excludedAppIDs: Set<String>
  ) -> AppIntentRuntimeReconciliation {
    if var resultingApp = result.resultingApp {
      confirmedApps[resultingApp.logicalID] = resultingApp
      resultingApp.isPinned = pinnedAppIDs.contains(resultingApp.logicalID)
      if resultingApp.isMuted {
        let accepted = result.outcome == .applied || result.outcome == .noChange
        resultingApp.muteSource =
          intent.reason == .automation && !accepted
          ? (cachedApp?.muteSource ?? resultingApp.muteSource)
          : (projectedMuteSource ?? resultingApp.muteSource)
      } else {
        resultingApp.muteSource = .user
      }
      return AppIntentRuntimeReconciliation(
        backendStatus: result.backendStatus,
        resultingApp: resultingApp,
        removedAppID: nil,
        shouldPresentAsExcluded: excludedAppIDs.contains(resultingApp.logicalID)
          || result.outcome == .excluded
      )
    }
    let removedAppID = result.outcome == .unavailable ? intent.appID : nil
    if let removedAppID { confirmedApps.removeValue(forKey: removedAppID) }
    return AppIntentRuntimeReconciliation(
      backendStatus: result.backendStatus,
      resultingApp: nil,
      removedAppID: removedAppID,
      shouldPresentAsExcluded: false
    )
  }

  func setCurrentGeneration(_ generation: UInt64, for appID: String) {
    currentGenerations[appID] = generation
  }

  func isCurrent(_ generation: UInt64, for appID: String) -> Bool {
    currentGenerations[appID] == generation
  }

  func isCurrentOrUnowned(_ generation: UInt64, for appID: String) -> Bool {
    currentGenerations[appID].map { $0 == generation } ?? true
  }

  func hasNewerGeneration(than generation: UInt64, for appID: String) -> Bool {
    currentGenerations[appID].map { $0 != generation } ?? false
  }

  func supersedeApp(_ appID: String) {
    cancelCurrentAppTask(for: appID)
    currentGenerations[appID] = allocateGeneration()
    optimisticProjections.removeValue(forKey: appID)
  }

  func currentProjection(for appID: String) -> AppIntentProjection? {
    guard let projection = optimisticProjections[appID],
      isCurrent(projection.generation, for: appID)
    else { return nil }
    return projection
  }

  func removeProjection(for appID: String, generation: UInt64? = nil) {
    guard generation == nil || optimisticProjections[appID]?.generation == generation else { return }
    optimisticProjections.removeValue(forKey: appID)
  }

  func hasPendingVolumeTargets() -> Bool {
    !pendingVolumeTargets.isEmpty
  }

  func setPendingVolume(_ value: Float, for appID: String) {
    pendingVolumeTargets[appID] = value
  }

  func pendingVolume(for appID: String) -> Float? {
    pendingVolumeTargets[appID]
  }

  func takePendingVolume(for appID: String) -> Float? {
    pendingVolumeTargets.removeValue(forKey: appID)
  }

  func clearPendingVolume(for appID: String) {
    pendingVolumeTargets.removeValue(forKey: appID)
  }

  func setPendingEqualizer(_ settings: EqualizerSettings, for appID: String) {
    pendingEqualizerSettings[appID] = settings
  }

  func pendingEqualizer(for appID: String) -> EqualizerSettings? {
    pendingEqualizerSettings[appID]
  }

  func takePendingEqualizer(for appID: String) -> EqualizerSettings? {
    pendingEqualizerSettings.removeValue(forKey: appID)
  }

  func clearPendingEqualizer(for appID: String) {
    pendingEqualizerSettings.removeValue(forKey: appID)
  }

  func beginVolumeDebounce(for appID: String) -> UUID {
    cancelVolumeDebounce(for: appID)
    let token = UUID()
    currentVolumeDebounceTokens[appID] = token
    return token
  }

  func registerVolumeDebounce(_ task: Task<Void, Never>, token: UUID, appID: String) {
    volumeDebounceTasks[token] = MutationTaskRecord(appID: appID, task: task)
  }

  func isCurrentVolumeDebounce(_ token: UUID, for appID: String) -> Bool {
    currentVolumeDebounceTokens[appID] == token
  }

  func settleVolumeDebounce(_ token: UUID) {
    guard let record = volumeDebounceTasks.removeValue(forKey: token) else { return }
    if currentVolumeDebounceTokens[record.appID] == token {
      currentVolumeDebounceTokens.removeValue(forKey: record.appID)
    }
  }

  func cancelVolumeDebounce(for appID: String) {
    guard let token = currentVolumeDebounceTokens.removeValue(forKey: appID) else { return }
    volumeDebounceTasks[token]?.task.cancel()
  }

  func beginEqualizerDebounce(for appID: String) -> UUID {
    cancelEqualizerDebounce(for: appID)
    let token = UUID()
    currentEqualizerDebounceTokens[appID] = token
    return token
  }

  func registerEqualizerDebounce(_ task: Task<Void, Never>, token: UUID, appID: String) {
    equalizerDebounceTasks[token] = MutationTaskRecord(appID: appID, task: task)
  }

  func isCurrentEqualizerDebounce(_ token: UUID, for appID: String) -> Bool {
    currentEqualizerDebounceTokens[appID] == token
  }

  func settleEqualizerDebounce(_ token: UUID) {
    guard let record = equalizerDebounceTasks.removeValue(forKey: token) else { return }
    if currentEqualizerDebounceTokens[record.appID] == token {
      currentEqualizerDebounceTokens.removeValue(forKey: record.appID)
    }
  }

  func cancelEqualizerDebounce(for appID: String) {
    guard let token = currentEqualizerDebounceTokens.removeValue(forKey: appID) else { return }
    equalizerDebounceTasks[token]?.task.cancel()
  }

  func beginProfile(affectedAppIDs: Set<String>) -> UInt64 {
    let generation = allocateGeneration()
    currentProfileGeneration = generation
    for appID in affectedAppIDs {
      cancelCurrentAppTask(for: appID)
      clearPendingVolume(for: appID)
      cancelVolumeDebounce(for: appID)
      clearPendingEqualizer(for: appID)
      cancelEqualizerDebounce(for: appID)
      optimisticProjections.removeValue(forKey: appID)
      currentGenerations[appID] = generation
    }
    return generation
  }

  func registerProfileTask(_ task: Task<Void, Never>, generation: UInt64) {
    guard !isShutDown else {
      task.cancel()
      return
    }
    profileTasks[generation] = task
  }

  func settleProfileTask(generation: UInt64) {
    profileTasks.removeValue(forKey: generation)
  }

  func isCurrentProfile(_ generation: UInt64) -> Bool {
    currentProfileGeneration == generation
  }

  func claimDurableMutation(for appID: String, generation: UInt64) {
    durableMutationGenerations[appID] = generation
  }

  func ownsDurableMutation(for appID: String, generation: UInt64) -> Bool {
    durableMutationGenerations[appID] == generation
  }

  func releaseDurableMutation(for appID: String, generation: UInt64) {
    guard ownsDurableMutation(for: appID, generation: generation) else { return }
    durableMutationGenerations.removeValue(forKey: appID)
  }

  func claimDevicePresetMutation(key: String, generation: UInt64) {
    devicePresetMutationGenerations[key] = generation
  }

  func ownsDevicePresetMutation(key: String, generation: UInt64) -> Bool {
    devicePresetMutationGenerations[key] == generation
  }

  func releaseDevicePresetMutation(key: String, generation: UInt64) {
    guard ownsDevicePresetMutation(key: key, generation: generation) else { return }
    devicePresetMutationGenerations.removeValue(forKey: key)
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

  func retainAppState(in appIDs: Set<String>) {
    let staleIDs = Set(currentGenerations.keys).subtracting(appIDs)
    for appID in staleIDs {
      supersedeApp(appID)
      currentGenerations.removeValue(forKey: appID)
      confirmedApps.removeValue(forKey: appID)
    }
    pendingVolumeTargets = pendingVolumeTargets.filter { appIDs.contains($0.key) }
    pendingEqualizerSettings = pendingEqualizerSettings.filter { appIDs.contains($0.key) }
    for appID in currentVolumeDebounceTokens.keys where !appIDs.contains(appID) {
      cancelVolumeDebounce(for: appID)
    }
    for appID in currentEqualizerDebounceTokens.keys where !appIDs.contains(appID) {
      cancelEqualizerDebounce(for: appID)
    }
    retainAutomaticMuteOwners(in: appIDs)
  }

  func removeState(for appID: String) {
    supersedeApp(appID)
    currentGenerations.removeValue(forKey: appID)
    confirmedApps.removeValue(forKey: appID)
    confirmedEqualizers.removeValue(forKey: appID)
    durableMutationGenerations.removeValue(forKey: appID)
    clearPendingVolume(for: appID)
    clearPendingEqualizer(for: appID)
    cancelVolumeDebounce(for: appID)
    cancelEqualizerDebounce(for: appID)
    automaticMuteOwners.remove(appID)
  }

  func drain() async {
    while true {
      let appSnapshot = appTasks
      let profileSnapshot = profileTasks
      let volumeSnapshot = volumeDebounceTasks
      let equalizerSnapshot = equalizerDebounceTasks
      guard
        !appSnapshot.isEmpty || !profileSnapshot.isEmpty
          || !volumeSnapshot.isEmpty || !equalizerSnapshot.isEmpty
      else { return }

      for (_, record) in appSnapshot { _ = await record.task.value }
      for (token, _) in appSnapshot { settleAppTask(token: token) }
      for (_, task) in profileSnapshot { await task.value }
      for (generation, _) in profileSnapshot { settleProfileTask(generation: generation) }
      for (_, record) in volumeSnapshot { await record.task.value }
      for (token, _) in volumeSnapshot { settleVolumeDebounce(token) }
      for (_, record) in equalizerSnapshot { await record.task.value }
      for (token, _) in equalizerSnapshot { settleEqualizerDebounce(token) }
    }
  }

  @discardableResult
  func shutdown() -> AppIntentCoordinatorSettlingTasks {
    isShutDown = true
    let appTransactions = appTasks.values.map(\.task)
    let mutations =
      volumeDebounceTasks.values.map(\.task)
      + equalizerDebounceTasks.values.map(\.task)
      + Array(profileTasks.values)
    for task in appTransactions { task.cancel() }
    for task in mutations { task.cancel() }
    for appID in Array(currentGenerations.keys) {
      currentGenerations[appID] = allocateGeneration()
    }
    currentAppTaskTokens.removeAll()
    currentVolumeDebounceTokens.removeAll()
    currentEqualizerDebounceTokens.removeAll()
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

  private func cancelCurrentAppTask(for appID: String) {
    guard let token = currentAppTaskTokens.removeValue(forKey: appID) else { return }
    appTasks[token]?.task.cancel()
  }
}
