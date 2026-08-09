import AppKit
import Carbon.HIToolbox
import Foundation

/// What a shortcut does when pressed.
enum HotkeyAction: Codable, Hashable, Sendable {
  /// Act on one specific app, by the same stable logical ID Waves persists
  /// everywhere else — so a binding survives that app quitting and relaunching,
  /// and Waves itself restarting.
  case muteApp(String)
  case volumeUpApp(String)
  case volumeDownApp(String)
  case frontmostMute
  case frontmostVolumeUp
  case frontmostVolumeDown
  /// Brings the mixer forward. The one binding a menu-bar-first app needs most:
  /// in a full-screen game, call, or editor the menu bar is hidden, so without
  /// it the primary surface is simply unreachable without leaving full screen.
  case showMixer

  var appID: String? {
    switch self {
    case .muteApp(let id), .volumeUpApp(let id), .volumeDownApp(let id): id
    default: nil
    }
  }

  /// Stable identifier for persistence and for the Carbon hot-key ID.
  var kind: String {
    switch self {
    case .muteApp: "mute-app"
    case .volumeUpApp: "volume-up-app"
    case .volumeDownApp: "volume-down-app"
    case .frontmostMute: "frontmost-mute"
    case .frontmostVolumeUp: "frontmost-volume-up"
    case .frontmostVolumeDown: "frontmost-volume-down"
    case .showMixer: "show-mixer"
    }
  }

  /// What this action is called on screen — the same words as the row that
  /// holds it, so "already assigned to Toggle mute" points somewhere real.
  ///
  /// `appName` resolves a per-app binding's display name; the caller supplies it
  /// because that lookup needs the running session, which this type has no
  /// business knowing about.
  func displayTitle(appName: (String) -> String = { $0 }) -> String {
    switch self {
    case .frontmostVolumeUp: "Increase volume"
    case .frontmostVolumeDown: "Decrease volume"
    case .frontmostMute: "Toggle mute"
    case .showMixer: "Show Waves"
    case .muteApp(let id): "Mute \(appName(id))"
    case .volumeUpApp(let id): "\(appName(id)) volume up"
    case .volumeDownApp(let id): "\(appName(id)) volume down"
    }
  }
}

/// One key combination bound to one action.
///
/// `keyCode` is a virtual key code, which is layout-independent — the physical
/// key, not the character on it. That is what `RegisterEventHotKey` wants, and it
/// means a shortcut recorded on QWERTY still fires on the same physical key under
/// Dvorak or AZERTY instead of silently moving.
struct HotkeyBinding: Codable, Hashable, Identifiable, Sendable {
  var id: UUID
  var action: HotkeyAction
  var keyCode: UInt16
  /// Carbon modifier mask (`cmdKey`, `optionKey`, `shiftKey`, `controlKey`).
  /// Stored raw so the persisted value never depends on an AppKit type's
  /// representation.
  var carbonModifiers: UInt32

  init(id: UUID = UUID(), action: HotkeyAction, keyCode: UInt16, carbonModifiers: UInt32) {
    self.id = id
    self.action = action
    self.keyCode = keyCode
    self.carbonModifiers = carbonModifiers
  }

  /// Two bindings collide when they would claim the same physical chord.
  /// Identity is deliberately excluded: re-recording the same chord onto the
  /// same row is not a conflict with itself.
  var chord: HotkeyChord { HotkeyChord(keyCode: keyCode, carbonModifiers: carbonModifiers) }
}

/// A key combination, independent of what it does.
struct HotkeyChord: Hashable, Sendable {
  var keyCode: UInt16
  var carbonModifiers: UInt32
}

// MARK: - Modifier translation

enum HotkeyModifiers {
  /// Every modifier Waves will accept in a chord.
  ///
  /// Includes control and shift, so a full hyper (⌃⌥⇧⌘) records correctly — that
  /// is how Raycast and Karabiner users bind things, and refusing it would make
  /// Waves the one app that cannot join their scheme.
  static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    return mask
  }

  static func flags(from carbon: UInt32) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
    if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
    if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
    return flags
  }

  /// A chord with no modifier would swallow a bare keystroke system-wide, which
  /// is never what someone means and is close to impossible to undo from inside
  /// the app that did it.
  static func isAcceptable(carbon: UInt32) -> Bool { carbon != 0 }
}

// MARK: - Display

extension HotkeyBinding {
  /// The chord as macOS writes it — ⌃⌥⇧⌘ in Apple's canonical order, then the
  /// key. Used in Settings and in menus, so it reads the same as every other
  /// shortcut on the system.
  var displayString: String { HotkeyFormatter.string(for: chord) }
}

enum HotkeyFormatter {
  static func string(for chord: HotkeyChord) -> String {
    modifierString(carbon: chord.carbonModifiers) + keyName(for: chord.keyCode)
  }

  /// The modifiers alone, in Apple's canonical order rather than the order they
  /// were pressed. Split out so the recorder can show ⌥⌘… while the user is
  /// still holding keys down and has not committed to a key yet.
  static func modifierString(carbon: UInt32) -> String {
    var text = ""
    if carbon & UInt32(controlKey) != 0 { text += "⌃" }
    if carbon & UInt32(optionKey) != 0 { text += "⌥" }
    if carbon & UInt32(shiftKey) != 0 { text += "⇧" }
    if carbon & UInt32(cmdKey) != 0 { text += "⌘" }
    return text
  }

  /// Names for keys whose glyph is not their character, plus the letters and
  /// digits. Falls back to the raw code rather than showing nothing, so an
  /// unusual key still round-trips visibly.
  static func keyName(for keyCode: UInt16) -> String {
    if let special = specialKeyNames[keyCode] { return special }
    if let character = characterKeyNames[keyCode] { return character }
    return "Key \(keyCode)"
  }

  private static let specialKeyNames: [UInt16: String] = [
    UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
    UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
    UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
    UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
    UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
    UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
    UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
    UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
    UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
    UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
  ]

  private static let characterKeyNames: [UInt16: String] = [
    UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
    UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
    UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
    UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
    UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
    UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
    UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
    UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
    UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
    UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
    UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
    UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
    UInt16(kVK_ANSI_9): "9",
    UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
    UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
    UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
    UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
    UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
    UInt16(kVK_ANSI_Grave): "`",
  ]
}

// MARK: - The set of bindings

/// The bindings Waves holds, and the rules about what may be added.
///
/// Pure: no Carbon, no registration. Conflict detection and migration are the
/// parts most likely to be wrong, and they are exactly the parts that can be
/// tested without pressing a key.
struct HotkeyBindingSet: Codable, Equatable, Sendable {
  var bindings: [HotkeyBinding] = []

  /// The shortcuts Waves shipped hard-coded through 1.4.0.
  ///
  /// Migrated rather than dropped: they are documented in Help and people use
  /// them. They are ordinary editable bindings now, so they can also be changed
  /// or cleared, which they never could be before.
  static var legacyDefaults: [HotkeyBinding] {
    [
      HotkeyBinding(
        action: .frontmostVolumeUp,
        keyCode: UInt16(kVK_UpArrow),
        carbonModifiers: UInt32(cmdKey | optionKey)
      ),
      HotkeyBinding(
        action: .frontmostVolumeDown,
        keyCode: UInt16(kVK_DownArrow),
        carbonModifiers: UInt32(cmdKey | optionKey)
      ),
      HotkeyBinding(
        action: .frontmostMute,
        keyCode: UInt16(kVK_ANSI_M),
        carbonModifiers: UInt32(cmdKey | optionKey)
      ),
    ]
  }

  /// The binding already using this chord, if any. Ignores `excluding` so
  /// re-recording a row onto its own chord is not a conflict with itself.
  func conflict(for chord: HotkeyChord, excluding id: UUID? = nil) -> HotkeyBinding? {
    bindings.first { $0.chord == chord && $0.id != id }
  }

  func binding(for action: HotkeyAction) -> HotkeyBinding? {
    bindings.first { $0.action == action }
  }

  /// Every app that has at least one shortcut, so Settings can group its rows.
  var boundAppIDs: [String] {
    var seen: Set<String> = []
    return bindings.compactMap(\.action.appID).filter { seen.insert($0).inserted }
  }

  /// Adds or replaces a binding, refusing a chord another binding already owns.
  ///
  /// Returns the conflicting binding on refusal so the caller can name it —
  /// "already used by Spotify" is actionable where "that didn't work" is not.
  @discardableResult
  mutating func assign(
    _ chord: HotkeyChord,
    to action: HotkeyAction,
    replacing id: UUID? = nil
  ) -> Result<HotkeyBinding, HotkeyAssignmentError> {
    guard HotkeyModifiers.isAcceptable(carbon: chord.carbonModifiers) else {
      return .failure(.needsModifier)
    }
    if let existing = conflict(for: chord, excluding: id) {
      return .failure(.alreadyUsed(existing))
    }

    // One binding per action: assigning a second chord to the same action
    // replaces the first rather than quietly leaving two live.
    let replacementID = id ?? bindings.first { $0.action == action }?.id
    let binding = HotkeyBinding(
      id: replacementID ?? UUID(),
      action: action,
      keyCode: chord.keyCode,
      carbonModifiers: chord.carbonModifiers
    )
    if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
      bindings[index] = binding
    } else {
      bindings.append(binding)
    }
    return .success(binding)
  }

  mutating func remove(id: UUID) {
    bindings.removeAll { $0.id == id }
  }

  // Deliberately no automatic pruning of bindings whose app isn't running.
  // The roster Waves can see is the *running* one, so pruning against it would
  // delete a Spotify shortcut every time Spotify was closed. A binding for an
  // app that is not running is correct and expected; pressing it says so.
}

enum HotkeyAssignmentError: Error, Equatable {
  case needsModifier
  case alreadyUsed(HotkeyBinding)
  /// The system refused the chord — another app registered it first. Caught
  /// while the recorder is still open, so the answer arrives where the question
  /// was asked instead of as a shortcut that mysteriously never fires.
  case claimedByAnotherApp(HotkeyChord)

  /// What the user is told, on the row they just tried to record into.
  ///
  /// `appName` resolves a per-app binding's display name. The conflict case must
  /// name the shortcut that *holds* the chord — echoing back the keys the user
  /// just pressed carries no information they didn't already have, and the owner
  /// may be a per-app row for an app that isn't running and isn't on screen.
  func message(appName: (String) -> String = { $0 }) -> String {
    switch self {
    case .needsModifier:
      "Add ⌘, ⌥, ⌃, or ⇧ — a shortcut without one would capture that key everywhere."
    case .alreadyUsed(let binding):
      "\(binding.displayString) is already assigned to \(binding.action.displayTitle(appName: appName))."
    case .claimedByAnotherApp(let chord):
      "Registration was refused for \(HotkeyFormatter.string(for: chord)). The combination may be reserved by macOS or another app."
    }
  }
}
