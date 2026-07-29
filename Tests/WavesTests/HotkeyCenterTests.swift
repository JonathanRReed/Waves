import AppKit
import Carbon.HIToolbox
import Testing

@testable import Waves

// These drive the real Carbon registrar rather than a model, because the whole
// point of the 1.4.1 recorder fix is a claim about the *system*: that a chord
// Waves holds is unavailable to anything else — including Waves's own recorder —
// until Waves gives it back. That claim cannot be checked against a fake.
//
// Chords here are deliberately obscure (⌃⌥⇧⌘F13/F14) so a real app on the
// machine running these tests is unlikely to own them already.

@MainActor
private func obscureChord(_ keyCode: Int) -> HotkeyChord {
  HotkeyChord(
    keyCode: UInt16(keyCode),
    carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
  )
}

@MainActor
private func binding(_ chord: HotkeyChord, _ action: HotkeyAction) -> HotkeyBinding {
  HotkeyBinding(action: action, keyCode: chord.keyCode, carbonModifiers: chord.carbonModifiers)
}

@Test @MainActor func pausingReleasesTheChordAndResumingTakesItBack() throws {
  let center = HotkeyCenter()
  defer { center.unregisterAll() }

  let chord = obscureChord(kVK_F13)
  try #require(
    center.isChordAvailable(chord),
    "another app on this machine already owns the test chord"
  )

  let rejected = center.apply([binding(chord, .frontmostMute)])
  #expect(rejected.isEmpty, "the system refused a chord it had just reported free")

  // Held: this is exactly why the recorder could never capture ⌘⌥M. The system
  // hands the keystroke to us as a hot-key event instead of letting it reach any
  // view, and a second registration of the same chord fails.
  #expect(center.isChordAvailable(chord) == false)

  center.pause()
  #expect(center.isPaused)
  #expect(
    center.isChordAvailable(chord),
    "pause did not release the chord, so a recorder still could not capture it"
  )

  center.resume()
  #expect(center.isPaused == false)
  #expect(center.isChordAvailable(chord) == false, "resume did not take the chord back")
}

@Test @MainActor func resumeRestoresEveryBindingNotJustTheFirst() throws {
  let center = HotkeyCenter()
  defer { center.unregisterAll() }

  let first = obscureChord(kVK_F13)
  let second = obscureChord(kVK_F14)
  try #require(center.isChordAvailable(first) && center.isChordAvailable(second))

  center.apply([binding(first, .frontmostMute), binding(second, .frontmostVolumeUp)])
  center.pause()
  center.resume()

  // A resume that dropped bindings would leave shortcuts silently dead after
  // the user closed a recorder — the worst possible outcome of this feature.
  #expect(center.isChordAvailable(first) == false)
  #expect(center.isChordAvailable(second) == false)
}

@Test @MainActor func resumingWithoutPausingChangesNothing() {
  let center = HotkeyCenter()
  defer { center.unregisterAll() }

  let chord = obscureChord(kVK_F13)
  guard center.isChordAvailable(chord) else { return }
  center.apply([binding(chord, .frontmostMute)])

  // Every exit path from the recorder calls resume, including ones that never
  // started recording. A second resume must not double-register or throw.
  center.resume()
  center.resume()
  #expect(center.isChordAvailable(chord) == false)
}

@Test @MainActor func unregisterAllFreesEverythingAndClearsThePausedFlag() throws {
  let center = HotkeyCenter()
  let chord = obscureChord(kVK_F13)
  try #require(center.isChordAvailable(chord))

  center.apply([binding(chord, .frontmostMute)])
  center.pause()
  center.unregisterAll()

  #expect(center.isPaused == false)
  #expect(center.isChordAvailable(chord), "a torn-down centre is still holding chords")

  // And nothing comes back: resume after teardown must not resurrect bindings
  // the user turned off.
  center.resume()
  #expect(center.isChordAvailable(chord))
}

@Test @MainActor func aChordAnotherRegistrarHoldsIsReportedAsRejected() throws {
  // Stands in for "Raycast already owns this combination", which is the case
  // that produces a shortcut that looks fine in Settings and never fires.
  let holder = HotkeyCenter()
  defer { holder.unregisterAll() }
  let center = HotkeyCenter()
  defer { center.unregisterAll() }

  let chord = obscureChord(kVK_F14)
  try #require(holder.isChordAvailable(chord))
  holder.apply([binding(chord, .frontmostMute)])

  let rejected = center.apply([binding(chord, .frontmostVolumeUp)])
  #expect(rejected.count == 1, "a chord owned elsewhere was accepted, so it would never fire")
  #expect(rejected.first?.chord == chord)
}
