import Foundation
import Testing

@testable import Waves

@MainActor
@Test func automationParserRejectsControlCharactersAndFormattingSeparators() {
  let parser = AutomationCommandParser()
  let hostileCommands = [
    "waves://set-volume?app=music%0Ainjected&volume=0.5",
    "waves://set-volume?app=music%1B%5B2J&volume=0.5",
    "waves://mute?app=music%0D&muted=true",
    "waves://apply-preset?name=Focus%0AHeader",
    "waves://apply-preset?name=Focus%E2%80%A8Separator",
    "waves://apply-profile?name=Focus%E2%80%AEHidden",
    "waves://apply-profile?name=Focus%E2%81%A6Hidden",
    "waves://set-volume%0Ainjected?app=music&volume=0.5",
  ]

  for command in hostileCommands {
    guard let url = URL(string: command) else { continue }
    guard case .rejected = parser.parse(url) else {
      Issue.record("expected rejection for hostile command \(command)")
      continue
    }
  }
  for _ in 0..<10 {
    #expect(parser.parse(URL(string: "waves://refresh")!) == .accepted(.refresh))
  }
  #expect(parser.parse(URL(string: "waves://refresh")!) == .throttled(shouldNotify: true))
}
