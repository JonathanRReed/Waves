import AppKit
import Carbon.HIToolbox
import OSLog

/// Registers Waves's shortcuts with the system and reports presses.
///
/// Uses Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor.
/// That is a correctness choice, not a stylistic one — through 1.4.0 Waves used a
/// global monitor, which has two defects a monitor cannot fix:
///
/// - **It cannot consume the event.** ⌘⌥M muted the frontmost app *and* the
///   keystroke still reached that app, so the shortcut fired somebody else's
///   command at the same time.
/// - **It needs Accessibility permission** to observe key-downs, so the app had
///   to ask for a broad, alarming privilege to read three chords.
///
/// A Carbon hot key consumes the event and needs no permission at all. It also
/// fails loudly when a chord is already claimed system-wide, which is what lets
/// Settings say "that one is taken" instead of registering something that
/// silently never fires.
@MainActor
final class HotkeyCenter {
  private let logger = Logger(subsystem: "com.jonathanreed.Waves", category: "Hotkeys")

  /// Called on the main actor when a registered chord is pressed.
  var onPress: ((HotkeyAction) -> Void)?

  /// Owns the Carbon registrations and releases them when the centre dies.
  ///
  /// A separate, non-isolated box because `deinit` on a `@MainActor` type cannot
  /// touch isolated stored properties under strict concurrency — and these
  /// registrations are process-global, so leaking them would leave the system
  /// swallowing the user's keystrokes with nothing left to handle them.
  private final class Registrations: @unchecked Sendable {
    var byID: [UInt32: EventHotKeyRef] = [:]
    var handler: EventHandlerRef?

    func removeAll() {
      for (_, ref) in byID { UnregisterEventHotKey(ref) }
      byID.removeAll()
    }

    deinit {
      removeAll()
      if let handler { RemoveEventHandler(handler) }
    }
  }

  private let registrations = Registrations()
  /// Carbon identifies a hot key by a 32-bit id; map it back to the action.
  private var actionsByHotkeyID: [UInt32: HotkeyAction] = [:]
  private var nextHotkeyID: UInt32 = 1

  /// Four-char code identifying our hot keys, so the handler can ignore anyone
  /// else's.
  private static let signature: OSType = 0x5741_5645  // 'WAVE'

  // MARK: Registration

  /// Replaces every registration with the given set.
  ///
  /// Returns the bindings the system refused — almost always because another
  /// app already owns that chord. The caller surfaces them; silently dropping
  /// them is how a shortcut becomes "it just doesn't work sometimes".
  @discardableResult
  func apply(_ bindings: [HotkeyBinding]) -> [HotkeyBinding] {
    unregisterAll()
    appliedBindings = bindings
    guard !bindings.isEmpty else { return [] }
    installHandlerIfNeeded()

    var rejected: [HotkeyBinding] = []
    for binding in bindings {
      guard register(binding) else {
        rejected.append(binding)
        continue
      }
    }
    if !rejected.isEmpty {
      logger.warning("\(rejected.count, privacy: .public) shortcut(s) were refused by the system")
    }
    return rejected
  }

  func unregisterAll() {
    stopRepeating()
    registrations.removeAll()
    actionsByHotkeyID.removeAll()
    appliedBindings.removeAll()
    isPaused = false
  }

  /// The bindings currently applied, so `resume()` can put them back.
  private var appliedBindings: [HotkeyBinding] = []
  private(set) var isPaused = false

  /// Releases every registration without forgetting them.
  ///
  /// Required while a shortcut recorder is open. A Carbon hot key is consumed by
  /// the system ahead of the responder chain — that is the whole point of it,
  /// and it happens even while Waves itself is frontmost. So without this, the
  /// one thing a recorder must be able to see (a chord Waves already owns) is
  /// the one thing it can never see: pressing ⌘⌥M into the field would fire
  /// mute instead of recording, and swapping two shortcuts would be impossible.
  func pause() {
    guard !isPaused else { return }
    isPaused = true
    stopRepeating()
    registrations.removeAll()
    // Clear the id map too, so `resume()`'s fresh ids don't accumulate dead
    // entries behind them. Nothing can fire while paused, so nothing needs it.
    actionsByHotkeyID.removeAll()
  }

  /// Puts the registrations back. Safe to call when not paused.
  ///
  /// Every path out of recording must reach this — committing, cancelling,
  /// clicking away, closing the window. A recorder that forgets to resume
  /// leaves the user with no global shortcuts at all and no clue why.
  func resume() {
    guard isPaused else { return }
    isPaused = false
    guard !appliedBindings.isEmpty else { return }
    installHandlerIfNeeded()
    var rejected: [HotkeyBinding] = []
    for binding in appliedBindings where !register(binding) {
      rejected.append(binding)
    }
    if !rejected.isEmpty {
      // Something claimed the chord while we were paused. Report it the same
      // way a fresh apply would, rather than leaving a silently dead shortcut.
      onRejected?(rejected)
    }
  }

  /// Reports bindings the system refused after a resume. Set by the app delegate.
  var onRejected: (([HotkeyBinding]) -> Void)?

  private func register(_ binding: HotkeyBinding) -> Bool {
    let id = nextHotkeyID
    nextHotkeyID &+= 1

    let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(binding.keyCode),
      binding.carbonModifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &reference
    )

    guard status == noErr, let reference else { return false }
    registrations.byID[id] = reference
    actionsByHotkeyID[id] = binding.action
    return true
  }

  /// True when the system would accept this chord right now.
  ///
  /// Registers and immediately unregisters, which is the only way to ask macOS
  /// whether a chord is free — there is no query API. Used by the recorder so a
  /// conflict with *another app* is reported while the user is still looking at
  /// the field, rather than discovered later when nothing happens.
  func isChordAvailable(_ chord: HotkeyChord) -> Bool {
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32.max)
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(chord.keyCode),
      chord.carbonModifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &reference
    )
    guard status == noErr, let reference else { return false }
    UnregisterEventHotKey(reference)
    return true
  }

  // MARK: Dispatch

  private func installHandlerIfNeeded() {
    guard registrations.handler == nil else { return }

    // Both edges. Pressed alone would be enough to fire an action, but holding
    // a volume key has to ramp — a Carbon hot key does not auto-repeat, so
    // without the released event to stop against, ⌘⌥↓ would move one 10% step
    // per press and 100% → 20% would be eight separate presses.
    var specs = [
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      ),
      EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyReleased)
      ),
    ]
    let context = Unmanaged.passUnretained(self).toOpaque()

    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == HotkeyCenter.signature else { return noErr }
        let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)

        // Carbon delivers on the main thread, so this is a valid assumption
        // rather than a hop that would delay the keystroke.
        let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated {
          if isPress {
            center.handle(hotkeyID: hotKeyID.id)
          } else {
            center.handleRelease(hotkeyID: hotKeyID.id)
          }
        }
        return noErr
      },
      specs.count,
      &specs,
      context,
      &registrations.handler
    )
  }

  private func handle(hotkeyID: UInt32) {
    guard let action = actionsByHotkeyID[hotkeyID] else { return }
    onPress?(action)
    guard action.repeatsWhenHeld else { return }
    startRepeating(hotkeyID: hotkeyID, action: action)
  }

  private func handleRelease(hotkeyID: UInt32) {
    guard repeatingHotkeyID == hotkeyID else { return }
    stopRepeating()
  }

  // MARK: Key repeat

  /// Only one key can be held at a time for our purposes, so one timer.
  private var repeatTimer: Timer?
  private var repeatingHotkeyID: UInt32?

  /// Matches the system's own key-repeat feel closely enough to read as native
  /// rather than as a Waves invention. Deliberately not read from
  /// `NSEvent.keyRepeatDelay`: those defaults describe text insertion, and a
  /// volume ramp wants to be a touch calmer than a cursor.
  private static let repeatDelay: TimeInterval = 0.45
  private static let repeatInterval: TimeInterval = 0.08

  private func startRepeating(hotkeyID: UInt32, action: HotkeyAction) {
    stopRepeating()
    repeatingHotkeyID = hotkeyID
    repeatTimer = Timer.scheduledTimer(
      withTimeInterval: Self.repeatDelay,
      repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.repeatingHotkeyID == hotkeyID else { return }
        self.repeatTimer = Timer.scheduledTimer(
          withTimeInterval: Self.repeatInterval,
          repeats: true
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, self.repeatingHotkeyID == hotkeyID else { return }
            self.onPress?(action)
          }
        }
      }
    }
  }

  /// Stops any ramp in progress.
  ///
  /// Called on release, and on every teardown path. A timer that outlived its
  /// key would keep changing the volume after the user let go, which is the
  /// worst failure this feature could have.
  func stopRepeating() {
    repeatTimer?.invalidate()
    repeatTimer = nil
    repeatingHotkeyID = nil
  }
}

private extension HotkeyAction {
  /// Whether holding the key should keep firing.
  ///
  /// Volume ramps; mute does not — a repeating mute would flap the app on and
  /// off several times a second, and toggling twice is the same as not pressing
  /// it at all.
  var repeatsWhenHeld: Bool {
    switch self {
    case .frontmostVolumeUp, .frontmostVolumeDown, .volumeUpApp, .volumeDownApp: true
    case .frontmostMute, .muteApp, .showMixer: false
    }
  }
}
