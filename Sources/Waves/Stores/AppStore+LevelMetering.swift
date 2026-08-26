import AppKit
import Foundation
import WavesAudioCore

// MARK: - Live level metering (visibility-gated)

extension AppStore {
  /// Cadence for smooth meters, used while a mixer surface is actually on screen.
  private static let fastLevelPollInterval = Duration.milliseconds(300)
  /// Heartbeat used when no mixer surface is visible.
  ///
  /// Polling cannot stop outright, however hidden the windows are: the menu-bar
  /// glyph is a surface too, and it is on screen whenever Waves is running. It
  /// reads the same levels (`isLive` treats the poll as authoritative for a
  /// `.managed` app, because the snapshot's own levels are always zero), so with
  /// no poll the icon and its VoiceOver label would claim "idle" for the entire
  /// time a managed app was playing behind a hidden window.
  private static let idleLevelPollInterval = Duration.seconds(1)

  /// Fast only when a surface that draws meters is genuinely visible.
  private var levelPollInterval: Duration {
    liveLevelsRefcount > 0 && isUISurfaceVisible
      ? Self.fastLevelPollInterval
      : Self.idleLevelPollInterval
  }

  /// Call when a mixer surface becomes visible. Reference-counted so multiple
  /// open surfaces (main window + menu bar) share one poller and the fast
  /// cadence is used only while one of them is on screen.
  func beginLiveLevels() {
    guard startupState != .shuttingDown else { return }
    liveLevelsRefcount += 1
    restartLevelPollingForCadenceChange()
  }

  /// Restarts the poller when the interval it should be using has changed.
  /// Cheap and idempotent: a no-op when the cadence is already correct.
  private func restartLevelPollingForCadenceChange() {
    guard startupState == .running else { return }
    let desired = levelPollInterval
    guard desired != activeLevelPollInterval || levelPollTask == nil else { return }
    levelPollTask?.cancel()
    levelPollTask = nil
    startLiveLevelPollingIfNeeded()
  }

  func startLiveLevelPollingIfNeeded() {
    guard startupState == .running else { return }
    guard levelPollTask == nil else { return }
    let interval = levelPollInterval
    activeLevelPollInterval = interval
    levelPollTask = Task { [weak self] in
      // Read first, then sleep. Sleeping first meant every surface that started
      // the poll — the menu-bar panel most visibly — showed stale or empty
      // meters for a full interval before its first real reading, so opening the
      // panel looked like nothing was playing for 300 ms.
      while !Task.isCancelled {
        guard let self, !Task.isCancelled, self.startupState == .running else { return }
        let levels = await self.backend.audioLevels()
        // Re-check after the await (the poll may have been cancelled while
        // suspended). Skip the no-op level assignment to avoid needless redraws,
        // but always reconcile the lingering-live set so a just-silenced app is
        // scheduled to drop out — and a returning one is kept — every tick.
        guard !Task.isCancelled, self.startupState == .running else { return }
        if levels != self.liveLevels {
          self.liveLevels = levels
        }
        self.refreshLiveLinger()
        // Piggy-backs on the poll rather than adding a timer: this is already
        // the cadence at which anything a control client cares about can move.
        self.broadcastControlStateIfChanged()
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// Reconciles `recentlyLiveIDs` against who is audible right now. Apps that just
  /// started playing are added immediately (any pending removal cancelled); apps
  /// that just went quiet get a one-shot task that drops them after
  /// `liveLingerWindow`. Mutates the observed set only when membership actually
  /// changes, so a steady scene triggers no redraws.
  func refreshLiveLinger() {
    let liveNow = Set(visibleApps.lazy.filter(isLive).map(\.logicalID))
    var next = recentlyLiveIDs

    // Audible now: keep it, and cancel any pending "drop it" task.
    for id in liveNow {
      if let task = lingerRemovalTasks.removeValue(forKey: id) { task.cancel() }
      next.insert(id)
    }

    // Lingering but no longer audible: schedule a single delayed removal.
    for id in next where !liveNow.contains(id) && lingerRemovalTasks[id] == nil {
      let window = liveLingerWindow
      lingerRemovalTasks[id] = Task { [weak self] in
        try? await Task.sleep(for: window)
        guard let self, !Task.isCancelled else { return }
        self.lingerRemovalTasks.removeValue(forKey: id)
        if self.recentlyLiveIDs.contains(id) {
          self.recentlyLiveIDs.remove(id)
        }
      }
    }

    if next != recentlyLiveIDs { recentlyLiveIDs = next }
  }

  func endLiveLevels() {
    liveLevelsRefcount = max(0, liveLevelsRefcount - 1)
    guard liveLevelsRefcount == 0 else { return }
    // Drop to the heartbeat rather than stopping: see `idleLevelPollInterval`.
    restartLevelPollingForCadenceChange()
  }

  /// Called when the app's windows go on or off screen. Drops the level poll to
  /// its heartbeat while nothing is visible and restores the fast cadence the
  /// moment something is, without disturbing the view-side refcount — the
  /// surfaces are still mounted and will not call `beginLiveLevels` again on
  /// their own.
  ///
  /// Levels are deliberately *not* cleared here. Doing so made the menu-bar
  /// glyph report "idle" for the whole time a managed app played behind a
  /// hidden window.
  func setUISurfaceVisible(_ visible: Bool) {
    guard isUISurfaceVisible != visible else { return }
    isUISurfaceVisible = visible
    restartLevelPollingForCadenceChange()
  }
}
