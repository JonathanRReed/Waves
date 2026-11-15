// Records what Elgato Wave Link 3 reports while you change app levels in
// Waves, so a real session can replace guesses in the Waves test fixtures.
//
// Read-only: it sends only `getApplicationInfo` and `getChannels`, the two
// read calls Waves itself makes, and never changes Wave Link. It connects only
// to 127.0.0.1. See docs/WAVE_LINK_CAPTURE.md.
//
// Usage: swift script/wave-link-capture.swift [--seconds 90] [--interval-ms 50]
//          [--port N] [--output PATH]

import Foundation

struct Options {
  var seconds = 90.0
  var intervalMilliseconds = 50
  var port: Int?
  var output: URL?
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("wave-link-capture: \(message)\n".utf8))
  exit(1)
}

func parseOptions() -> Options {
  var options = Options()
  var arguments = CommandLine.arguments.dropFirst().makeIterator()
  while let argument = arguments.next() {
    guard let value = arguments.next() else { fail("\(argument) needs a value") }
    switch argument {
    case "--seconds":
      guard let seconds = Double(value), (1...600).contains(seconds) else { fail("--seconds must be 1 to 600") }
      options.seconds = seconds
    case "--interval-ms":
      guard let interval = Int(value), (20...1_000).contains(interval) else { fail("--interval-ms must be 20 to 1000") }
      options.intervalMilliseconds = interval
    case "--port":
      guard let port = Int(value), (1...65_535).contains(port) else { fail("--port must be 1 to 65535") }
      options.port = port
    case "--output":
      options.output = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    default:
      fail("unknown option \(argument)")
    }
  }
  return options
}

/// The port Wave Link 3 published for this launch, from the same two
/// `ws-info.json` locations Waves reads.
func publishedPort() -> Int? {
  let home = FileManager.default.homeDirectoryForCurrentUser
  let paths = [
    "Library/Application Support/com.elgato.WaveLink3/ws-info.json",
    "Library/Containers/com.elgato.WaveLink3/Data/Library/Application Support/com.elgato.WaveLink3/ws-info.json",
  ]
  for path in paths {
    guard let data = try? Data(contentsOf: home.appendingPathComponent(path)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let port = (object["port"] as? NSNumber)?.intValue, (1...65_535).contains(port)
    else { continue }
    return port
  }
  return nil
}

final class CaptureLog: @unchecked Sendable {
  private let handle: FileHandle
  private let start = Date()
  private let lock = NSLock()
  private(set) var lineCount = 0

  init(url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: url)
  }

  /// One JSON object per line: milliseconds since start, direction, and the
  /// message itself, parsed when it is JSON.
  func record(_ direction: String, _ text: String) {
    let milliseconds = Int(Date().timeIntervalSince(start) * 1_000)
    let message: Any = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? text
    let entry: [String: Any] = ["ms": milliseconds, "direction": direction, "message": message]
    guard let line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    lock.withLock {
      handle.write(line + Data("\n".utf8))
      lineCount += 1
    }
  }

  func close() { try? handle.close() }
}

let options = parseOptions()
guard let port = options.port ?? publishedPort() else {
  fail("Wave Link 3 did not publish a control port. Open Wave Link 3, or pass --port.")
}
let stamp: String = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyyMMdd-HHmmss"
  return formatter.string(from: Date())
}()
let outputURL =
  options.output
  ?? FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Desktop/wave-link-capture-\(stamp).jsonl")
let log: CaptureLog
do {
  log = try CaptureLog(url: outputURL)
} catch {
  fail("cannot write \(outputURL.path): \(error.localizedDescription)")
}

var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
request.setValue("streamdeck://", forHTTPHeaderField: "Origin")
let socket = URLSession(configuration: .ephemeral).webSocketTask(with: request)
socket.maximumMessageSize = 4 * 1_048_576
socket.resume()

// Every message Wave Link sends is recorded, replies and notifications alike.
let receiving = Task {
  while !Task.isCancelled {
    guard let message = try? await socket.receive() else { return }
    switch message {
    case .string(let text): log.record("in", text)
    case .data(let data): log.record("in", String(decoding: data, as: UTF8.self))
    @unknown default: return
    }
  }
}

var nextID = 1
@MainActor func send(_ method: String) async -> Bool {
  // Parameterless, like Waves: Wave Link 3 rejects explicit null params.
  let text = #"{"id":\#(nextID),"jsonrpc":"2.0","method":"\#(method)"}"#
  nextID += 1
  log.record("out", text)
  do {
    try await socket.send(.string(text))
    return true
  } catch {
    FileHandle.standardError.write(Data("wave-link-capture: send failed: \(error.localizedDescription)\n".utf8))
    return false
  }
}

print("Recording Wave Link on 127.0.0.1:\(port) for \(Int(options.seconds)) s to \(outputURL.path)")
print("Make the changes in Waves now. Press Control-C to stop early; the file keeps what was recorded.")
guard await send("getApplicationInfo") else { fail("could not reach Wave Link on port \(port)") }
let deadline = Date().addingTimeInterval(options.seconds)
while Date() < deadline {
  guard await send("getChannels") else { break }
  try? await Task.sleep(for: .milliseconds(options.intervalMilliseconds))
}
try? await Task.sleep(for: .milliseconds(300))
receiving.cancel()
socket.cancel(with: .normalClosure, reason: nil)
log.close()
print("Done: \(log.lineCount) messages in \(outputURL.path)")
