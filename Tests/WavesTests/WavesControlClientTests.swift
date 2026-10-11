import Darwin
import Foundation
import Testing

@testable import WavesControlClient

@Test(arguments: [
  [], ["bogus"], ["apps", "extra"], ["icon"], ["volume", "app"],
  ["volume", "app", "nan"], ["volume", "app", "1.1"],
  ["nudge", "app", "infinity"], ["mute"], ["toggle", "app", "extra"],
  ["raw", "not json"], ["raw", "[]"], ["raw", "{}", "extra"],
])
func wavesCTLRejectsInvalidArgumentsBeforeTransport(_ arguments: [String]) {
  #expect(throws: WavesCTLValidationError.self) {
    _ = try WavesCTLCommand.parse(arguments)
  }
}

@Test func wavesCTLTerminalTextNeutralizesControlSequences() {
  let hostile =
    "Zoom\u{1B}[2J\u{1B}]0;pwned\u{07}\r\nfake: line\u{2028}x\u{202E}y\u{9B}z\tw\u{7F}"
  let safe = WavesCTLTerminalText.sanitized(hostile)
  #expect(
    safe
      == "Zoom\u{FFFD}[2J\u{FFFD}]0;pwned\u{FFFD}\u{FFFD}\u{FFFD}fake: line\u{FFFD}x\u{FFFD}y\u{FFFD}z\tw\u{FFFD}"
  )
  #expect(!safe.unicodeScalars.contains { $0.value < 0x20 && $0.value != 0x09 })
  #expect(!safe.unicodeScalars.contains { (0x7F...0x9F).contains($0.value) })
}

@Test func wavesCTLTerminalTextPreservesOrdinaryNames() {
  let names = ["Google Chrome", "Über — Musik", "日本語", "emoji 🎧", "tab\tkept"]
  for name in names {
    #expect(WavesCTLTerminalText.sanitized(name) == name)
  }
}

@Test func wavesControlJSONValueDescriptionEscapesSpecialCharacters() {
  let stringValue = WavesControlJSONValue.string("quote: \" backslash: \\ newline: \n tab: \t")
  #expect(stringValue.description == "\"quote: \\\" backslash: \\\\ newline: \\n tab: \\t\"")

  let objectValue = WavesControlJSONValue.object([
    "key\"with\\quote": .string("val\"ue")
  ])
  #expect(objectValue.description == "{\"key\\\"with\\\\quote\": \"val\\\"ue\"}")
}

@Test func wavesControlJSONValueHandlesLargeNumbersWithoutCrashing() throws {
  let largeNumber = WavesControlJSONValue.number(1e20)
  #expect(!largeNumber.description.isEmpty)

  let command = WavesCTLCommand.raw(["volume": largeNumber])
  let object = command.requestObject(id: 1)
  #expect(object["volume"] == largeNumber)
}

@Test(arguments: [
  (value: 1e20, literal: "1e+20"),
  (value: -1e20, literal: "-1e+20"),
  (value: Double(Int64.max), literal: "9.223372036854776e+18"),
  (value: Double(Int64.min), literal: "-9223372036854775808"),
])
func wavesCTLSerializesLargeNumbersThroughSocket(testCase: (value: Double, literal: String)) throws {
  let system = ScriptedControlClientSystem()
  let client = try WavesControlSocketClient(path: "/tmp/waves.sock", system: system)
  let command = WavesCTLCommand.raw(["volume": .number(testCase.value)])
  try client.send(command.requestObject(id: 1))

  #expect(system.writtenBytes == Data("{\"volume\":\(testCase.literal)}\n".utf8))
  let decoded = try JSONSerialization.jsonObject(with: system.writtenBytes)
  let object = try #require(decoded as? [String: NSNumber])
  #expect(object["volume"]?.doubleValue == testCase.value)
}

private final class WavesCTLBuildDirectoryLocator {}

@Test func wavesCTLExecutableRejectsInvalidVolumeBeforeConnecting() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  // The products directory follows the active scratch path, so resolve it from
  // the loaded test bundle before assuming the default `.build` location.
  let candidates = [
    Bundle(for: WavesCTLBuildDirectoryLocator.self).bundleURL
      .deletingLastPathComponent()
      .appendingPathComponent("wavesctl"),
    packageRoot.appendingPathComponent(".build/debug/wavesctl"),
  ]
  let executable =
    candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
  #expect(FileManager.default.isExecutableFile(atPath: executable.path))

  let process = Process()
  process.executableURL = executable
  process.arguments = ["volume", "com.example.invalid", "1.1"]
  var environment = ProcessInfo.processInfo.environment
  environment["WAVES_CONTROL_SOCKET"] =
    "/tmp/wavesctl-invalid-\(UUID().uuidString.lowercased()).sock"
  process.environment = environment

  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  let text = String(decoding: data, as: UTF8.self)
  #expect(process.terminationReason == .exit)
  #expect(process.terminationStatus == 2)
  #expect(text.contains("usage: wavesctl volume <app-id> <0..1>"))
  #expect(text.contains("Could not connect") == false)
  #expect(text.contains("Control socket") == false)
}

@Test func wavesCTLParsesEverySupportedCommandWithoutTransport() throws {
  #expect(try WavesCTLCommand.parse(["apps"]) == .apps)
  #expect(try WavesCTLCommand.parse(["icon", "app.id"]) == .icon(app: "app.id"))
  #expect(try WavesCTLCommand.parse(["volume", "app.id", "0.5"]) == .volume(app: "app.id", value: 0.5))
  #expect(try WavesCTLCommand.parse(["nudge", "app.id", "-0.02"]) == .nudge(app: "app.id", delta: -0.02))
  #expect(try WavesCTLCommand.parse(["mute", "app.id"]) == .mute(app: "app.id", muted: true))
  #expect(try WavesCTLCommand.parse(["unmute", "app.id"]) == .mute(app: "app.id", muted: false))
  #expect(try WavesCTLCommand.parse(["toggle", "app.id"]) == .toggle(app: "app.id"))
  #expect(try WavesCTLCommand.parse(["watch"]) == .watch)
  #expect(try WavesCTLCommand.parse(["raw", #"{"id":7,"cmd":"list-apps"}"#]) == .raw(["id": .number(7), "cmd": .string("list-apps")]))
}

@Test func wavesCTLCompleteWriteRetriesPartialAndInterruptedSyscalls() throws {
  let system = ScriptedControlClientSystem(
    writeResults: [.written(2), .failed(EINTR), .written(4)])
  let client = try WavesControlSocketClient(path: "/tmp/waves.sock", system: system)
  try client.send(["id": .number(1), "cmd": .string("hello")])
  #expect(system.writtenBytes == Data("{\"cmd\":\"hello\",\"id\":1}\n".utf8))
  #expect(system.socketOptions.map(\.name).contains(SO_NOSIGPIPE))
  #expect(system.socketOptions.map(\.name).contains(SO_RCVTIMEO))
  #expect(system.socketOptions.map(\.name).contains(SO_SNDTIMEO))
  #expect(system.didConnectAfterOptions)
}

@Test(arguments: [
  Double.nan, Double.infinity, -Double.infinity, -1.0, -Double.leastNonzeroMagnitude,
  Double(Int.max), Double.greatestFiniteMagnitude,
])
func darwinWavesControlSocketTimeoutConversionRejectsInvalidValues(invalidSeconds: TimeInterval) {
  #expect(throws: WavesCTLTransportError.socketConfigurationFailed("SO_RCVTIMEO")) {
    _ = try DarwinWavesControlSocketSystem.timeoutValue(option: SO_RCVTIMEO, seconds: invalidSeconds)
  }
}

@Test(arguments: [SO_RCVTIMEO, SO_SNDTIMEO])
func darwinWavesControlSocketTimeoutConversionRejectsInt32UpperBound(option: Int32) {
  let name = option == SO_RCVTIMEO ? "SO_RCVTIMEO" : "SO_SNDTIMEO"
  // Check conversion directly: a failing setsockopt on a non-socket must not
  // make this pass when the upper-bound guard is removed.
  #expect(throws: WavesCTLTransportError.socketConfigurationFailed(name)) {
    _ = try DarwinWavesControlSocketSystem.timeoutValue(option: option, seconds: Double(Int32.max))
  }
}

@Test(arguments: [
  (seconds: 0.0, wholeSeconds: 0, microseconds: Int32(0)),
  (seconds: 0.125, wholeSeconds: 0, microseconds: Int32(125_000)),
  (seconds: 5.25, wholeSeconds: 5, microseconds: Int32(250_000)),
  (seconds: Double(Int32.max).nextDown, wholeSeconds: Int(Int32.max) - 1, microseconds: Int32(999_999)),
])
func darwinWavesControlSocketTimeoutConversionPreservesSupportedValues(
  testCase: (seconds: TimeInterval, wholeSeconds: Int, microseconds: Int32)
) throws {
  let timeout = try DarwinWavesControlSocketSystem.timeoutValue(option: SO_RCVTIMEO, seconds: testCase.seconds)
  #expect(timeout.tv_sec == testCase.wholeSeconds)
  #expect(timeout.tv_usec == testCase.microseconds)
}

@Test(arguments: [SO_RCVTIMEO, SO_SNDTIMEO])
func darwinWavesControlSocketSystemSetsValidTimeoutOnRealSocket(option: Int32) throws {
  let system = DarwinWavesControlSocketSystem()
  let fd = try system.openSocket()
  defer { system.close(fd) }
  try system.setTimeout(fd, option: option, seconds: 0.125)
  let name = option == SO_RCVTIMEO ? "SO_RCVTIMEO" : "SO_SNDTIMEO"
  #expect(throws: WavesCTLTransportError.socketConfigurationFailed(name)) {
    try system.setTimeout(fd, option: option, seconds: Double(Int32.max))
  }
}

@Test(arguments: [
  (value: Double.nan, expected: 0), (value: Double.infinity, expected: 0),
  (value: -Double.infinity, expected: 0), (value: -Double.greatestFiniteMagnitude, expected: 0),
  (value: Double.greatestFiniteMagnitude, expected: 100), (value: -1e20, expected: 0),
  (value: 1e20, expected: 100), (value: -0.1, expected: 0), (value: 0.0, expected: 0),
  (value: 0.0049, expected: 0), (value: 0.005, expected: 1), (value: 0.9949, expected: 99),
  (value: 0.995, expected: 100), (value: 0.35, expected: 35), (value: 1.0, expected: 100),
  (value: 1.1, expected: 100),
])
func wavesCTLPercentageFormattingStaysBounded(testCase: (value: Double, expected: Int)) {
  #expect(WavesCTLDisplay.percentage(.number(testCase.value)) == testCase.expected)
}

@Test(arguments: [
  nil, JSONValue.null, JSONValue.string("NaN"), JSONValue.string("0.5"), JSONValue.bool(true),
  JSONValue.array([]), JSONValue.object([:]),
])
func wavesCTLAbsentOrNonnumericPercentageDisplaysZero(_ value: JSONValue?) {
  #expect(WavesCTLDisplay.percentage(value) == 0)
}

@Test func wavesCTLReportsWriteAndReadTimeoutsDistinctly() throws {
  let writeSystem = ScriptedControlClientSystem(writeResults: [.failed(EAGAIN)])
  let writer = try WavesControlSocketClient(path: "/tmp/waves.sock", system: writeSystem)
  #expect(throws: WavesCTLTransportError.timeout(.write)) {
    try writer.send(["cmd": .string("hello")])
  }

  let readSystem = ScriptedControlClientSystem(readResults: [.failed(EWOULDBLOCK)])
  let reader = try WavesControlSocketClient(path: "/tmp/waves.sock", system: readSystem)
  #expect(throws: WavesCTLTransportError.timeout(.read)) {
    _ = try reader.receive()
  }

  let timedOutSystem = ScriptedControlClientSystem(readResults: [.failed(ETIMEDOUT)])
  let timedOutReader = try WavesControlSocketClient(path: "/tmp/waves.sock", system: timedOutSystem)
  #expect(throws: WavesCTLTransportError.timeout(.read)) {
    _ = try timedOutReader.receive()
  }
}

@Test func wavesCTLDistinguishesEOFFramingJSONAndShapeFailures() throws {
  let eof = try WavesControlSocketClient(
    path: "/tmp/waves.sock", system: ScriptedControlClientSystem(readResults: [.eof]))
  #expect(throws: WavesCTLTransportError.unexpectedEOF) { _ = try eof.receive() }

  let oversized = Data(repeating: 0x41, count: WavesControlProtocol.maximumLineBytes + 1)
  let framing = try WavesControlSocketClient(
    path: "/tmp/waves.sock", system: ScriptedControlClientSystem(readResults: [.data(oversized)]))
  #expect(throws: WavesCTLTransportError.oversizedFrame) { _ = try framing.receive() }

  let malformed = try WavesControlSocketClient(
    path: "/tmp/waves.sock", system: ScriptedControlClientSystem(readResults: [.data(Data("nope\n".utf8))]))
  #expect(throws: WavesCTLTransportError.malformedJSON) { _ = try malformed.receive() }

  let unexpected = try WavesControlSocketClient(
    path: "/tmp/waves.sock", system: ScriptedControlClientSystem(readResults: [.data(Data("{}\n".utf8))]))
  #expect(throws: WavesCTLTransportError.unexpectedResponse) { _ = try unexpected.receive() }
}

private final class ScriptedControlClientSystem: WavesControlSocketSystem, @unchecked Sendable {
  var writeResults: [WavesControlWriteResult]
  var readResults: [WavesControlReadResult]
  var socketOptions: [(name: Int32, timeout: TimeInterval?)] = []
  var writtenBytes = Data()
  var didConnectAfterOptions = false

  init(
    writeResults: [WavesControlWriteResult] = [],
    readResults: [WavesControlReadResult] = []
  ) {
    self.writeResults = writeResults
    self.readResults = readResults
  }

  func openSocket() throws -> Int32 { 91 }
  func setNoSIGPIPE(_ fd: Int32) throws { socketOptions.append((SO_NOSIGPIPE, nil)) }
  func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) throws {
    socketOptions.append((option, seconds))
  }
  func connect(_ fd: Int32, path: String) throws { didConnectAfterOptions = socketOptions.count == 3 }
  func write(_ fd: Int32, data: Data, offset: Int) -> WavesControlWriteResult {
    let result = writeResults.isEmpty ? .written(data.count - offset) : writeResults.removeFirst()
    if case .written(let count) = result { writtenBytes.append(data.dropFirst(offset).prefix(count)) }
    return result
  }
  func read(_ fd: Int32, maximumBytes: Int) -> WavesControlReadResult {
    readResults.isEmpty ? .eof : readResults.removeFirst()
  }
  func close(_ fd: Int32) {}
}
