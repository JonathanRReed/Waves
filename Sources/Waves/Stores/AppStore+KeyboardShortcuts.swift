import AppKit
import Foundation
import WavesAudioCore

// MARK: - Keyboard shortcuts

extension AppStore {
  /// Seeds the legacy shortcuts once, the first time this build runs.
  ///
  /// Version-gated rather than "seed if empty": someone who deliberately clears
  /// every shortcut must not have ⌘⌥↑/↓/M reappear at the next launch.
  func migrateHotkeysIfNeeded() {
    guard preferences.hotkeyMigrationVersion < 1 else { return }
    preferences.hotkeyMigrationVersion = 1
    if preferences.hotkeys.bindings.isEmpty {
      preferences.hotkeys.bindings = HotkeyBindingSet.legacyDefaults
    }
    persistPreferences()
  }

  /// Runs the action behind a pressed shortcut.
  ///
  /// Goes through the same public entry points the UI uses, so a shortcut and a
  /// click are indistinguishable downstream.
  func performHotkey(_ action: HotkeyAction) {
    // Before the audio guard: wanting the window is *most* likely precisely when
    // audio is not running, and this is the one action that can still do
    // something useful in that state.
    if case .showMixer = action {
      onShowMixerRequested?()
      return
    }

    guard isAudioRunning else {
      promptToFinishSetup()
      // A toast alone renders nowhere for a menu-bar-only user with no window
      // open, and the keystroke was consumed, so the frontmost app never saw it
      // either — the press would produce literally nothing. Put the setup
      // surface on screen, the same way the URL-scheme path does.
      onShowMixerRequested?()
      return
    }
    switch action {
    case .showMixer:
      break  // handled above
    case .frontmostVolumeUp:
      increaseVolumeForFrontmostApp()
    case .frontmostVolumeDown:
      decreaseVolumeForFrontmostApp()
    case .frontmostMute:
      toggleMuteForFrontmostApp()
    case .muteApp(let appID):
      guard let app = resolveHotkeyApp(appID, verb: "mute") else { return }
      setMuted(!app.isMuted, for: app)
    case .volumeUpApp(let appID):
      guard let app = resolveHotkeyApp(appID, verb: "adjust") else { return }
      adjustVolume(for: app, by: Self.hotkeyVolumeStep)
    case .volumeDownApp(let appID):
      guard let app = resolveHotkeyApp(appID, verb: "adjust") else { return }
      adjustVolume(for: app, by: -Self.hotkeyVolumeStep)
    }
  }

  /// The app a per-app shortcut points at, or nil after explaining why not.
  ///
  /// A shortcut that silently does nothing is indistinguishable from a broken
  /// one, and the keystroke was consumed, so saying nothing leaves the user with
  /// no signal at all.
  private func resolveHotkeyApp(_ appID: String, verb: String) -> AudioApp? {
    guard let app = controlApp(forID: appID) else {
      showToast(
        title: "App not available",
        detail: "\(FriendlyAppName.resolve(appID, in: session.apps)) isn't running, so Waves can't \(verb) it.",
        kind: .warning
      )
      return nil
    }
    guard !isExcluded(app) else {
      showToast(
        title: "App excluded",
        detail: "\(app.displayName) is excluded from Waves.",
        kind: .warning
      )
      return nil
    }
    return app
  }

  /// Matches the frontmost volume shortcuts' step, so a per-app key and a
  /// frontmost key move the slider by the same amount.
  private static let hotkeyVolumeStep: Float = 0.1

  private func adjustVolume(for app: AudioApp, by delta: Float) {
    let target = min(max(app.desiredVolume + delta, 0), 1)
    guard target != app.desiredVolume else { return }
    setDesiredVolume(target, for: app)
    // The complete-intent transaction owns the confirmation and error toasts,
    // so this path stays silent and a keypress produces exactly one.
    commitDesiredVolume(for: app)
  }

  /// Assigns a chord, or explains why it could not be assigned.
  func assignHotkey(
    _ chord: HotkeyChord,
    to action: HotkeyAction,
    replacing id: UUID? = nil
  ) -> Result<HotkeyBinding, HotkeyAssignmentError> {
    var set = preferences.hotkeys

    // Waves's own rules first. A chord one of our other bindings holds must be
    // reported by name, and the system check below would refuse it anyway —
    // because *we* are the app already using it — under a message that blames
    // some unnamed other app.
    guard HotkeyModifiers.isAcceptable(carbon: chord.carbonModifiers) else {
      return .failure(.needsModifier)
    }
    if let existing = set.conflict(for: chord, excluding: id) {
      return .failure(.alreadyUsed(existing))
    }

    // Past that point the only binding that can still hold this chord is the row
    // being re-recorded onto itself, which we already own and must not ask the
    // system about for the same reason.
    //
    // Unless the system refused that binding — then we do *not* hold the chord,
    // and skipping the probe would let the user "successfully" re-record the
    // same dead shortcut over and over.
    let alreadyOurs = set.bindings.contains { $0.chord == chord && !isHotkeyRejected($0) }
    if !alreadyOurs, let isAvailable = isChordAvailable, !isAvailable(chord) {
      return .failure(.claimedByAnotherApp(chord))
    }

    let result = set.assign(chord, to: action, replacing: id)
    if case .success = result {
      preferences.hotkeys = set
      persistPreferences()
      onHotkeysChanged?()
    }
    return result
  }

  func setHotkeysSuspended(_ suspended: Bool) {
    onHotkeySuspensionChange?(suspended)
  }

  func removeHotkey(id: UUID) {
    preferences.hotkeys.remove(id: id)
    persistPreferences()
    onHotkeysChanged?()
  }

  /// Names the shortcuts macOS refused, so a chord another app already owns is
  /// visible rather than mysteriously inert.
  func reportRejectedHotkeys(_ rejected: [HotkeyBinding]) {
    rejectedHotkeyIDs = Set(rejected.map(\.id))
    guard !rejected.isEmpty else { return }
    let chords = rejected.map(\.displayString).joined(separator: ", ")
    showToast(
      title: rejected.count == 1 ? "Shortcut unavailable" : "Shortcuts unavailable",
      detail: "\(chords) \(rejected.count == 1 ? "is" : "are") already used by another app. Pick another in Settings.",
      kind: .warning,
      duration: .seconds(5)
    )
  }

  func isHotkeyRejected(_ binding: HotkeyBinding) -> Bool {
    rejectedHotkeyIDs.contains(binding.id)
  }

  /// Resolves a hot-key failure into words, naming the app behind a per-app
  /// binding rather than its bundle ID.
  func hotkeyMessage(for error: HotkeyAssignmentError) -> String {
    error.message { [session] id in FriendlyAppName.resolve(id, in: session.apps) }
  }
}
