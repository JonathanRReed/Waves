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

@Test func wavesCTLExecutableRejectsInvalidVolumeBeforeConnecting() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let executable = packageRoot.appendingPathComponent(".build/debug/wavesctl")
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
  process.waitUntilExit()

  let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
