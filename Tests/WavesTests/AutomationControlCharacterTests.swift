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

@MainActor
private final class LimiterRecoveryClock {
  var date = Date(timeIntervalSince1970: 0)
}

@MainActor
@Test func invocationLimiterRecoversAfterNonFiniteWindowFallback() {
  for window in [TimeInterval.nan, .infinity, -.infinity] {
    let clock = LimiterRecoveryClock()
    let limiter = URLInvocationLimiter(
      maximumInvocations: 2,
      window: window,
      now: { clock.date }
    )
    #expect(limiter.allow())
    #expect(limiter.allow())
    #expect(!limiter.allow())

    clock.date = Date(timeIntervalSince1970: 60)
    #expect(!limiter.allow())
    clock.date = Date(timeIntervalSince1970: 60.001)
    #expect(limiter.allow())
    #expect(limiter.allow())
    #expect(!limiter.allow())
  }
}

@MainActor
@Test func parserRequestsRecoverAfterNonFiniteWindowFallback() {
  let refreshURL = URL(string: "waves://refresh")!
  for window in [TimeInterval.nan, .infinity, -.infinity, -10] {
    let clock = LimiterRecoveryClock()
    let parser = AutomationCommandParser(
      maximumRequests: 2,
      requestWindow: window,
      now: { clock.date }
    )
    #expect(parser.parse(refreshURL) == .accepted(.refresh))
    #expect(parser.parse(refreshURL) == .accepted(.refresh))
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: true))

    clock.date = Date(timeIntervalSince1970: 60)
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: true))
    clock.date = Date(timeIntervalSince1970: 60.001)
    #expect(parser.parse(refreshURL) == .accepted(.refresh))
    #expect(parser.parse(refreshURL) == .accepted(.refresh))
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: false))
  }
}

@MainActor
@Test func parserNotificationsResumeAfterNonFiniteIntervalFallback() {
  let refreshURL = URL(string: "waves://refresh")!
  for interval in [TimeInterval.nan, .infinity, -.infinity, -5] {
    let clock = LimiterRecoveryClock()
    let parser = AutomationCommandParser(
      maximumRequests: 0,
      throttleNotificationInterval: interval,
      now: { clock.date }
    )
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: true))
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: false))

    clock.date = Date(timeIntervalSince1970: 4.999)
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: false))
    clock.date = Date(timeIntervalSince1970: 5)
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: true))
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: false))
    clock.date = Date(timeIntervalSince1970: 10)
    #expect(parser.parse(refreshURL) == .throttled(shouldNotify: true))
  }
}
