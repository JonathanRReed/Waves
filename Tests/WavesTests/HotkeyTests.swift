import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import Waves

// Hotkeys cannot be pressed from a test, so everything that decides *what* a
// shortcut is — conflicts, migration, formatting, the guard against a bare key —
// lives in pure types that can be. Only the Carbon registration itself needs
// hardware, and that is the part with the least logic in it.

private func chord(_ keyCode: Int, _ modifiers: Int) -> HotkeyChord {
  HotkeyChord(keyCode: UInt16(keyCode), carbonModifiers: UInt32(modifiers))
}

// MARK: - Assignment and conflicts

@Test func aChordWithNoModifierIsRefused() {
  var set = HotkeyBindingSet()
  // Registering a bare key would swallow it system-wide, and the user would have
  // to fix it from inside the app that just broke their keyboard.
  let result = set.assign(chord(kVK_ANSI_M, 0), to: .frontmostMute)
  #expect(result == .failure(.needsModifier))
  #expect(set.bindings.isEmpty)
}

@Test func everyModifierCombinationIncludingHyperIsAccepted() {
  // Raycast and Karabiner users bind hyper (⌃⌥⇧⌘). Refusing it would make Waves
  // the one app that cannot join their scheme.
  var set = HotkeyBindingSet()
  let hyper = cmdKey | optionKey | shiftKey | controlKey
  let result = set.assign(chord(kVK_ANSI_M, hyper), to: .muteApp("com.example.app"))
  #expect(result.isSuccess)
  #expect(set.bindings.first?.displayString == "⌃⌥⇧⌘M")
}

@Test func aChordAlreadyUsedByAnotherBindingIsRefusedByName() {
  var set = HotkeyBindingSet()
  _ = set.assign(chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp("com.spotify.client"))

  let result = set.assign(chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp("com.discord"))
  guard case .failure(.alreadyUsed(let existing)) = result else {
    Issue.record("expected a named conflict, got \(result)")
    return
  }
  // Naming the offender is the whole point — "that didn't work" is not actionable.
  #expect(existing.action == .muteApp("com.spotify.client"))
  #expect(existing.displayString == "⌥⌘S")
  #expect(set.bindings.count == 1, "the refused binding must not have been added")

  // And the sentence the user reads must name the shortcut that holds the
  // chord. Echoing back the keys they just pressed tells them nothing they did
  // not already know, and the owner may be a row for an app that isn't running
  // and isn't on screen anywhere.
  let message = HotkeyAssignmentError.alreadyUsed(existing)
    .message { $0 == "com.spotify.client" ? "Spotify" : $0 }
  #expect(message == "⌥⌘S is already assigned to Mute Spotify.")
}

@Test func everyActionCanNameItselfForAConflictMessage() {
  // A conflict against any of these has to read as a sentence, so none may fall
  // back to a raw enum case or a bundle ID.
  #expect(HotkeyAction.frontmostVolumeUp.displayTitle() == "Increase volume")
  #expect(HotkeyAction.frontmostVolumeDown.displayTitle() == "Decrease volume")
  #expect(HotkeyAction.frontmostMute.displayTitle() == "Toggle mute")
  #expect(HotkeyAction.muteApp("com.a").displayTitle { _ in "Slack" } == "Mute Slack")
}

@Test func rerecordingTheSameChordOntoItsOwnRowIsNotAConflict() {
  var set = HotkeyBindingSet()
  guard case .success(let binding) = set.assign(
    chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp("com.spotify.client")
  ) else {
    Issue.record("setup failed")
    return
  }

  // Opening the recorder and pressing the same keys again must not report that
  // the shortcut conflicts with itself.
  let again = set.assign(
    chord(kVK_ANSI_S, cmdKey | optionKey),
    to: .muteApp("com.spotify.client"),
    replacing: binding.id
  )
  #expect(again.isSuccess)
  #expect(set.bindings.count == 1)
}

@Test func reassigningAnActionReplacesItsChordRatherThanAddingASecond() {
  var set = HotkeyBindingSet()
  _ = set.assign(chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp("com.spotify.client"))
  _ = set.assign(chord(kVK_ANSI_J, cmdKey | optionKey), to: .muteApp("com.spotify.client"))

  #expect(set.bindings.count == 1, "one shortcut per action, not two live at once")
  #expect(set.binding(for: .muteApp("com.spotify.client"))?.displayString == "⌥⌘J")
}

@Test func oneAppCanHoldMuteAndBothVolumeShortcutsAtOnce() {
  // These share an app ID but are three separate actions. If lookup or
  // replacement keyed on the app instead of the action, recording the second
  // would silently overwrite the first.
  var set = HotkeyBindingSet()
  let id = "com.spotify.client"
  _ = set.assign(chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp(id))
  _ = set.assign(chord(kVK_ANSI_Equal, cmdKey | optionKey), to: .volumeUpApp(id))
  _ = set.assign(chord(kVK_ANSI_Minus, cmdKey | optionKey), to: .volumeDownApp(id))

  #expect(set.bindings.count == 3)
  #expect(set.binding(for: .muteApp(id))?.displayString == "⌥⌘S")
  #expect(set.binding(for: .volumeUpApp(id))?.displayString == "⌥⌘=")
  #expect(set.binding(for: .volumeDownApp(id))?.displayString == "⌥⌘-")
  // And the app appears once in the grouped Settings list, not three times.
  #expect(set.boundAppIDs == [id])
}

@Test func showMixerIsNotTiedToAnyApp() {
  // It opens Waves itself, so it must never be grouped under an app row or
  // pruned along with one.
  #expect(HotkeyAction.showMixer.appID == nil)
  #expect(HotkeyAction.showMixer.displayTitle() == "Show Waves")
}

// MARK: - Migration

@Test func theLegacyShortcutsSurviveAsEditableBindings() {
  // ⌘⌥↑ / ⌘⌥↓ / ⌘⌥M were hard-coded through 1.4.0 and are documented in Help.
  // Dropping them would silently break something people use every day.
  let defaults = HotkeyBindingSet.legacyDefaults
  #expect(defaults.count == 3)

  let byAction = Dictionary(uniqueKeysWithValues: defaults.map { ($0.action, $0.displayString) })
  #expect(byAction[.frontmostVolumeUp] == "⌥⌘↑")
  #expect(byAction[.frontmostVolumeDown] == "⌥⌘↓")
  #expect(byAction[.frontmostMute] == "⌥⌘M")
}

@Test func legacyDefaultsDoNotConflictWithEachOther() {
  var set = HotkeyBindingSet()
  for binding in HotkeyBindingSet.legacyDefaults {
    #expect(
      set.conflict(for: binding.chord) == nil,
      "\(binding.displayString) collides with an earlier default"
    )
    set.bindings.append(binding)
  }
}

// MARK: - Removal

@Test func removingABindingLeavesTheRestAlone() {
  var set = HotkeyBindingSet()
  guard case .success(let spotify) = set.assign(
    chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp("com.spotify.client")
  ) else {
    Issue.record("setup failed")
    return
  }
  _ = set.assign(chord(kVK_ANSI_M, cmdKey | optionKey), to: .frontmostMute)

  set.remove(id: spotify.id)

  #expect(set.binding(for: .muteApp("com.spotify.client")) == nil)
  #expect(set.bindings.contains { $0.action == .frontmostMute })
  // The freed chord must be assignable again, not held by a ghost.
  #expect(set.conflict(for: chord(kVK_ANSI_S, cmdKey | optionKey)) == nil)
}

// MARK: - Formatting and round trip

@Test func modifiersRoundTripThroughAppKitAndCarbon() {
  let combinations: [NSEvent.ModifierFlags] = [
    [.command], [.option], [.control], [.shift],
    [.command, .option], [.command, .shift],
    [.control, .option, .shift, .command],
  ]
  for flags in combinations {
    let carbon = HotkeyModifiers.carbon(from: flags)
    #expect(HotkeyModifiers.flags(from: carbon) == flags)
    #expect(HotkeyModifiers.isAcceptable(carbon: carbon))
  }
  #expect(HotkeyModifiers.isAcceptable(carbon: 0) == false)
}

@Test func chordsAreWrittenInApplesModifierOrder() {
  // macOS always writes ⌃⌥⇧⌘, regardless of the order keys were pressed. Getting
  // this wrong makes Waves look foreign next to every other shortcut on screen.
  let hyper = chord(kVK_ANSI_K, controlKey | optionKey | shiftKey | cmdKey)
  #expect(HotkeyFormatter.string(for: hyper) == "⌃⌥⇧⌘K")
  #expect(HotkeyFormatter.string(for: chord(kVK_Space, cmdKey)) == "⌘Space")
  #expect(HotkeyFormatter.string(for: chord(kVK_UpArrow, optionKey)) == "⌥↑")
  #expect(HotkeyFormatter.string(for: chord(kVK_Escape, cmdKey)) == "⌘⎋")
}

@Test func bindingsSurviveAPersistenceRoundTrip() throws {
  var set = HotkeyBindingSet()
  _ = set.assign(chord(kVK_ANSI_S, cmdKey | optionKey), to: .muteApp("com.spotify.client"))
  _ = set.assign(chord(kVK_ANSI_M, cmdKey | optionKey), to: .frontmostMute)

  let data = try JSONEncoder().encode(set)
  let decoded = try JSONDecoder().decode(HotkeyBindingSet.self, from: data)

  #expect(decoded == set)
  #expect(decoded.binding(for: .muteApp("com.spotify.client"))?.displayString == "⌥⌘S")
}

private extension Result where Success == HotkeyBinding, Failure == HotkeyAssignmentError {
  var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
