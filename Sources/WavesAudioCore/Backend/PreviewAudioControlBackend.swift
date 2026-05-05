import Foundation

public actor PreviewAudioControlBackend: AudioControlBackend {
  private var snapshot: AudioSessionSnapshot
  private var presets: [Preset]

  public init(
    snapshot: AudioSessionSnapshot = .preview,
    presets: [Preset] = Preset.defaults
  ) {
    self.snapshot = snapshot
    self.presets = presets
  }

  public func start() async throws {}

  public func stop() async {}

  public func currentSnapshot() async -> AudioSessionSnapshot {
    snapshot
  }

  public func refresh() async throws -> AudioSessionSnapshot {
    for index in snapshot.apps.indices {
      let boost = Float((index % 4) + 1) * 0.02
      let nextPeak = min(1, max(0, snapshot.apps[index].desiredVolume * 0.65 + boost))
      snapshot.apps[index].peakLevel = snapshot.apps[index].isMuted ? 0 : nextPeak
      snapshot.apps[index].rmsLevel = snapshot.apps[index].isMuted ? 0 : max(0, nextPeak - 0.08)
      snapshot.apps[index].routingState =
        snapshot.apps[index].compatibility == .supported ? .managed : .monitorOnly
      snapshot.apps[index].appliedVolume =
        snapshot.apps[index].compatibility == .supported ? snapshot.apps[index].desiredVolume : nil
    }

    snapshot.updatedAt = .now
    return snapshot
  }

  public func setDesiredVolume(_ volume: Float, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].desiredVolume = max(0, min(1, volume))
    snapshot.apps[index].appliedVolume =
      snapshot.apps[index].compatibility == .supported ? snapshot.apps[index].desiredVolume : nil
    snapshot.apps[index].routingState =
      snapshot.apps[index].compatibility == .supported ? .managed : .monitorOnly
  }

  public func setMuted(_ isMuted: Bool, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isMuted = isMuted
    if isMuted {
      snapshot.apps[index].peakLevel = 0
      snapshot.apps[index].rmsLevel = 0
    }
  }

  public func setVolumeBoost(_ boost: Float, forAppID appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }

    let clampedBoost = max(1.0, min(4.0, boost))
    snapshot.apps[index].volumeBoost = clampedBoost
  }

  public func setVolumeControlMode(_ mode: VolumeControlMode, forDeviceID deviceID: String) async throws {
    if snapshot.currentDevice?.id == deviceID {
      snapshot.currentDevice?.volumeControlMode = mode
    }
  }

  public func pinApp(_ isPinned: Bool, appID: String) async throws {
    guard let index = snapshot.apps.firstIndex(matchingAppKey: appID) else {
      throw BackendError.appNotFound(appID)
    }

    snapshot.apps[index].isPinned = isPinned
  }

  public func applyPreset(_ preset: Preset) async throws -> AudioSessionSnapshot {
    for entry in preset.entries {
      guard let index = snapshot.apps.firstIndex(where: { $0.logicalID == entry.appID }) else {
        continue
      }

      snapshot.apps[index].desiredVolume = entry.desiredVolume
      snapshot.apps[index].isMuted = entry.isMuted
      snapshot.apps[index].appliedVolume =
        snapshot.apps[index].compatibility == .supported ? entry.desiredVolume : nil
    }

    snapshot.updatedAt = .now
    return snapshot
  }

  public func saveCurrentPreset(named name: String) async throws -> Preset {
    let preset = Preset(
      name: name,
      entries: snapshot.apps.map {
        PresetEntry(appID: $0.logicalID, desiredVolume: $0.desiredVolume, isMuted: $0.isMuted)
      }
    )
    presets.append(preset)
    return preset
  }

  public func recoverRoutes() async throws -> AudioSessionSnapshot {
    snapshot.backendStatus.isRouteRecoveryHealthy = true
    snapshot.backendStatus.lastError = nil
    snapshot.updatedAt = .now
    return snapshot
  }

  public func autoRestoreDevice() async throws -> AudioSessionSnapshot {
    if !snapshot.recentDeviceIDs.isEmpty {
      snapshot.updatedAt = .now
    }
    return snapshot
  }

  public func diagnosticsReport() async -> DiagnosticsReport {
    DiagnosticsReport(
      summary:
        "Preview backend simulates managed control for supported daily-use apps and monitor-only behavior for the remaining matrix.",
      checks: [
        DiagnosticsCheck(
          title: "Managed audio component",
          status: snapshot.backendStatus.isAudioComponentInstalled ? .passed : .warning,
          detail: snapshot.backendStatus.isAudioComponentInstalled
            ? "Preview backend marked component as installed."
            : "Install the managed audio component for real route ownership."
        ),
        DiagnosticsCheck(
          title: "Permission status",
          status: snapshot.backendStatus.hasRequiredPermissions ? .passed : .warning,
          detail: snapshot.backendStatus.hasRequiredPermissions
            ? "Required permissions are satisfied."
            : "Grant required permissions during onboarding."
        ),
        DiagnosticsCheck(
          title: "Support matrix",
          status: .informational,
          detail: snapshot.supportMatrix.coverageSummary
        ),
      ]
    )
  }
}

private extension Array where Element == AudioApp {
  func firstIndex(matchingAppKey appKey: String) -> Index? {
    firstIndex { $0.id == appKey || $0.logicalID == appKey }
  }
}
