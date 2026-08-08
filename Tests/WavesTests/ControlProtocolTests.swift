import Darwin
import Foundation
import Testing
import WavesAudioCore

@testable import Waves

// The control surface is the foundation the Stream Deck plugin sits on, and the
// hardware lives on another machine. So the protocol is deliberately pure — no
// sockets, no Core Audio — and everything that can go wrong on the wire is
// provable here, without a device.

// MARK: - Framing

@Test func controlServerMakesItsListenerNonblocking() {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(fd >= 0)
  defer { if fd >= 0 { close(fd) } }

  #expect(ControlServer.setNonBlocking(fd))
  let flags = fcntl(fd, F_GETFL, 0)
  #expect(flags & O_NONBLOCK != 0)
}

@Test func codecSplitsOnNewlinesAndToleratesPartialWrites() throws {
  var codec = ControlCodec()

  // A socket hands you arbitrary chunks, not lines. Half a line yields nothing.
  #expect(try codec.append(Data(#"{"cmd":"hel"#.utf8)).isEmpty)

  let lines = try codec.append(Data("lo\"}\n{\"cmd\":\"list-apps\"}\n".utf8))
  #expect(lines.count == 2)
  #expect(ControlCodec.decode(lines[0])?.cmd == .hello)
  #expect(ControlCodec.decode(lines[1])?.cmd == .listApps)
}

@Test func codecToleratesCRLFAndBlankLines() throws {
  var codec = ControlCodec()
  let lines = try codec.append(Data("{\"cmd\":\"hello\"}\r\n\n\n{\"cmd\":\"subscribe\"}\n".utf8))
  // Blank keepalive lines are skipped rather than treated as malformed.
  #expect(lines.count == 2)
  #expect(ControlCodec.decode(lines[0])?.cmd == .hello)
  #expect(ControlCodec.decode(lines[1])?.cmd == .subscribe)
}

@Test func codecRefusesALineThatWouldExhaustMemory() {
  var codec = ControlCodec()
  // No newline, ever: a client that cannot frame correctly must not be allowed
  // to make us buffer without bound.
  let flood = Data(repeating: 0x41, count: ControlProtocol.maximumLineBytes + 1)
  #expect(throws: ControlCodecError.lineTooLong) {
    _ = try codec.append(flood)
  }
}

@Test func codecEnforcesTheLimitPerFrameInsteadOfPerRead() throws {
  var codec = ControlCodec()
  let validPrefix = Data(repeating: 0x41, count: ControlProtocol.maximumLineBytes - 1)
  #expect(try codec.append(validPrefix).isEmpty)

  // A kernel read may complete the current near-limit frame and include the
  // next frame. The aggregate read buffer is larger than one frame, but neither
  // individual frame is oversized.
  let lines = try codec.append(Data("\n{}\n".utf8))
  #expect(lines == [validPrefix, Data("{}".utf8)])
}

@Test func codecRejectsOversizedCompletedFramesAndUnterminatedTails() {
  var completed = ControlCodec()
  let oversizedFrame =
    Data(repeating: 0x41, count: ControlProtocol.maximumLineBytes + 1) + Data("\n{}\n".utf8)
  #expect(throws: ControlCodecError.lineTooLong) {
    _ = try completed.append(oversizedFrame)
  }

  var unterminated = ControlCodec()
  let oversizedTail = Data(repeating: 0x41, count: ControlProtocol.maximumLineBytes + 1)
  #expect(throws: ControlCodecError.lineTooLong) {
    _ = try unterminated.append(oversizedTail)
  }
}

@Test func decodingRejectsUnknownCommands() {
  // The command set is closed, so an unknown verb dies at the decoder and never
  // reaches a handler.
  #expect(ControlCodec.decode(Data(#"{"cmd":"rm-rf"}"#.utf8)) == nil)
  #expect(ControlCodec.decode(Data(#"not json at all"#.utf8)) == nil)
  #expect(ControlCodec.decode(Data(#"{"id":1}"#.utf8)) == nil)
}

@Test func boundedRequestIDScanPreservesCorrelationWithoutDecoding() {
  #expect(ControlCodec.requestIDPrefix(Data(#"{"id":42,"cmd":"hello"}"#.utf8)) == 42)
  #expect(ControlCodec.requestIDPrefix(Data(#"{"cmd":"hello","id":-7}"#.utf8)) == -7)
  #expect(ControlCodec.requestIDPrefix(Data(#"{"id":"42","cmd":"hello"}"#.utf8)) == nil)
  #expect(ControlCodec.requestIDPrefix(Data(#"{"cmd":"hello"}"#.utf8)) == nil)
}

@Test func requestIDScanHasABoundedWorkLimit() {
  let padding = String(repeating: " ", count: ControlCodec.maximumRequestIDScanBytes)
  let line = Data("{\"client\":\"\(padding)\",\"id\":99,\"cmd\":\"hello\"}".utf8)
  #expect(ControlCodec.requestIDPrefix(line) == nil)
}

@Test func everyCommandRoundTripsThroughTheWire() throws {
  for command in ControlCommand.allCases {
    let request = ControlRequest(id: 7, cmd: command, app: "com.example.app")
    let encoded = try JSONEncoder().encode(request)
    #expect(ControlCodec.decode(encoded) == request, "\(command.rawValue) did not round trip")
  }
}

@Test func responsesEncodeTheProtocolVersionUnderTheWireName() throws {
  var response = ControlResponse.success(id: 1)
  response.protocolVersion = ControlProtocol.version
  let data = try #require(ControlCodec.encode(response))

  // The JSON key is "protocol" (a Swift keyword), so this is exactly the kind of
  // mapping that silently breaks a client.
  let text = String(decoding: data, as: UTF8.self)
  #expect(text.contains("\"protocol\":\(ControlProtocol.version)"))
  #expect(text.hasSuffix("\n"), "responses must be newline-framed")
}

@Test func everyErrorCarriesAnActionableMessage() {
  for error in [
    ControlError.unsupportedProtocol, .malformedRequest, .missingParameter,
    .unknownApp, .appExcluded, .audioNotRunning, .rateLimited, .notPermitted,
  ] {
    #expect(!error.message.isEmpty)
    #expect(error.message.hasSuffix("."), "\(error.rawValue) should read as a sentence")
  }
  // The first-run case has to tell the user where to go, or the plugin looks
  // broken rather than switched off.
  #expect(ControlError.notPermitted.message.contains("Settings"))
}

@Test func protocolV1GoldenNamesAndRepresentativeResponsesStayStable() throws {
  #expect(ControlProtocol.version == 1)
  #expect(
    ControlCommand.allCases.map(\.rawValue) == [
      "hello", "list-apps", "get-icon", "set-volume", "adjust-volume", "set-mute", "toggle-mute",
      "subscribe", "unsubscribe",
    ])
  #expect(ControlEvent.allCases.map(\.rawValue) == ["app-changed", "apps-changed"])
  #expect(
    [
      ControlError.unsupportedProtocol, .malformedRequest, .missingParameter, .unknownApp, .appExcluded,
      .audioNotRunning, .rateLimited, .notPermitted,
    ].map(\.rawValue) == [
      "unsupported-protocol", "malformed-request", "missing-parameter", "unknown-app", "app-excluded",
      "audio-not-running", "rate-limited", "not-permitted",
    ])

  let hello = try #require(
    ControlCodec.encode(
      ControlResponse(
        id: 7, ok: true, protocolVersion: 1, appVersion: "1.5.0", build: "13")))
  let failure = try #require(ControlCodec.encode(.failure(id: 8, .notPermitted)))
  #expect(String(decoding: hello, as: UTF8.self).contains(#""protocol":1"#))
  #expect(String(decoding: failure, as: UTF8.self).contains(#""error":"not-permitted"#))
}

@Test func writePumpRetainsEveryByteAcrossPartialWriteAndWouldBlock() {
  var pump = ControlWritePump()
  let acceptedFirst = pump.enqueue(Data("abcdef".utf8))
  let acceptedSecond = pump.enqueue(Data("gh".utf8))
  #expect(acceptedFirst)
  #expect(acceptedSecond)

  var attempts = 0
  var observed = Data()
  let first = pump.drain { frame, offset in
    attempts += 1
    guard attempts == 1 else { return .wouldBlock }
    observed.append(frame.dropFirst(offset).prefix(2))
    return .written(2)
  }
  #expect(first == .blocked)
  #expect(pump.queuedByteCount == 6)

  let second = pump.drain { frame, offset in
    observed.append(frame.dropFirst(offset))
    return .written(frame.count - offset)
  }
  #expect(second == .empty)
  #expect(observed == Data("abcdefgh".utf8))
  #expect(pump.queuedByteCount == 0)
}

@Test func writePumpClosesInsteadOfExceedingTheTwoMiBQueueLimit() {
  var pump = ControlWritePump()
  let acceptedAtLimit = pump.enqueue(Data(repeating: 1, count: ControlProtocol.maximumQueuedOutputBytes))
  let acceptedPastLimit = pump.enqueue(Data([2]))
  #expect(acceptedAtLimit)
  #expect(!acceptedPastLimit)
}

// MARK: - Rate limiting

@Test func rateLimiterAllowsADialBurstThenThrottles() {
  var limiter = ControlRateLimiter(now: 0)

  // A fast dial sweep lands as a burst; all of it must get through.
  var throttledDuringBurst: Int?
  for index in 0..<ControlRateLimiter.burst where !limiter.allow(now: 0) {
    throttledDuringBurst = index
    break
  }
  #expect(throttledDuringBurst == nil, "burst command \(throttledDuringBurst ?? -1) was throttled")

  let beyondBurst = limiter.allow(now: 0)
  #expect(beyondBurst == false, "the burst has to have a ceiling")
}

@Test func rateLimiterRefillsOverTime() {
  var limiter = ControlRateLimiter(now: 0)
  for _ in 0..<ControlRateLimiter.burst { _ = limiter.allow(now: 0) }
  let exhausted = limiter.allow(now: 0)
  #expect(exhausted == false)

  // One second later a full second's worth of tokens is available again.
  let refilled = limiter.allow(now: 1.0)
  #expect(refilled)
  var granted = 1
  while limiter.allow(now: 1.0) { granted += 1 }
  #expect(granted >= Int(ControlRateLimiter.refillPerSecond) - 1)
}

@Test func rateLimiterCannotBankUnlimitedTokensWhileIdle() {
  var limiter = ControlRateLimiter(now: 0)
  // An hour of silence must not buy an hour's worth of burst.
  var granted = 0
  while limiter.allow(now: 3_600) { granted += 1 }
  #expect(granted == ControlRateLimiter.burst)
}

// MARK: - State pushes

@MainActor
@Test func nothingIsPushedWhenNobodyIsSubscribed() async {
  let store = await makeControlStoreFixture()
  // No broadcast closure installed: the roster must not even be built.
  store.controlBroadcast = nil
  store.broadcastControlStateIfChanged()
  // Nothing to assert but the absence of a crash and of work — the real
  // guarantee is that a later subscriber starts from a fresh baseline, below.
  #expect(store.controlApps().isEmpty == false)
}

@MainActor
@Test func aMuteMadeInsideWavesReachesSubscribers() async {
  // The whole point: a Stream Deck key must show the truth even when the change
  // was made with the mouse, by a profile, or by a shortcut.
  let store = await makeControlStoreFixture()
  var pushes: [ControlResponse] = []
  store.controlBroadcast = { pushes.append($0) }

  // First call establishes the baseline (as a roster change).
  store.broadcastControlStateIfChanged()
  pushes.removeAll()

  let app = try! #require(store.controlApp(forID: "com.example.render"))
  store.setMuted(true, for: app)
  store.broadcastControlStateIfChanged()

  let changed = pushes.compactMap(\.changed)
  #expect(changed.count == 1, "expected exactly one app-changed push, got \(pushes.count)")
  #expect(changed.first?.id == "com.example.render")
  #expect(changed.first?.muted == true)
}

@MainActor
@Test func anUnchangedRosterPushesNothing() async {
  let store = await makeControlStoreFixture()
  var pushes: [ControlResponse] = []
  store.controlBroadcast = { pushes.append($0) }

  store.broadcastControlStateIfChanged()
  pushes.removeAll()

  // Nothing moved, so a client must not be woken. This runs on every poll tick.
  store.broadcastControlStateIfChanged()
  store.broadcastControlStateIfChanged()
  #expect(pushes.isEmpty, "a steady scene must be silent, got \(pushes.count) pushes")
}

@MainActor
@Test func aNewSubscriberStartsFromAFreshBaseline() async {
  let store = await makeControlStoreFixture()
  var pushes: [ControlResponse] = []
  store.controlBroadcast = { pushes.append($0) }
  store.broadcastControlStateIfChanged()

  // The client disconnects...
  store.controlBroadcast = nil
  store.broadcastControlStateIfChanged()

  // ...and a new one attaches. It must be told the roster, not diffed against
  // state it never saw.
  pushes.removeAll()
  store.controlBroadcast = { pushes.append($0) }
  store.broadcastControlStateIfChanged()
  #expect(pushes.contains { $0.event == .appsChanged })
}
