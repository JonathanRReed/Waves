import Foundation
import Testing
import WavesAudioCore

@testable import Waves

@Test func importedNamesUseEditorCaseInsensitiveSemanticsForUnicode() {
  let german = [Profile(name: "straße", entries: [])]
  #expect(AppStore.uniqueImportedProfileName("STRASSE", among: german) == "STRASSE (Imported)")

  let composed = [Profile(name: "Café", entries: [])]
  #expect(AppStore.uniqueImportedProfileName("CAFÉ", among: composed) == "CAFÉ (Imported)")
}

@Test func importedNamesHandleDecomposedAndNormalCaseCollisions() {
  let decomposed = "Cafe\u{301}"
  let profiles = [Profile(name: decomposed, entries: []), Profile(name: "Mix", entries: [])]

  #expect(AppStore.uniqueImportedProfileName("Café", among: profiles) == "Café (Imported)")
  #expect(AppStore.uniqueImportedProfileName("mix", among: profiles) == "mix (Imported)")
  #expect(AppStore.uniqueImportedProfileName("Focus", among: profiles) == "Focus")
}

@Test func importedNamesIncrementRepeatedImportedSuffixes() {
  let profiles = [
    Profile(name: "Meeting", entries: []),
    Profile(name: "Meeting (Imported)", entries: []),
    Profile(name: "Meeting (Imported 2)", entries: []),
  ]

  #expect(AppStore.uniqueImportedProfileName("meeting", among: profiles) == "meeting (Imported 3)")
}

@Test func importedNamesStayWithinTheProfileLimit() {
  let longName = String(repeating: "x", count: Profile.maxNameLength)
  let first = AppStore.uniqueImportedProfileName(longName, among: [Profile(name: longName, entries: [])])
  let second = AppStore.uniqueImportedProfileName(
    longName,
    among: [Profile(name: longName, entries: []), Profile(name: first, entries: [])]
  )

  #expect(first.count <= Profile.maxNameLength)
  #expect(second.count <= Profile.maxNameLength)
  #expect(first != second)
}
